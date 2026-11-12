import Foundation
import CoreServices
import Darwin

// Paths never leave the watcher. Each consumer owns its allowed root and its own epoch.
final class CompanionPathWatch {
    private final class State {
        let lock = NSLock()
        var callback: ((Bool) -> Void)?
        let root: String
        let allowedNames: Set<String>?
        init(root: String, names: Set<String>?, callback: @escaping (Bool) -> Void) { self.root = root; allowedNames = names; self.callback = callback }
        func accepts(_ path: String) -> Bool { allowedNames == nil || path == root || allowedNames!.contains(URL(fileURLWithPath: path).lastPathComponent) }
        func changed(_ gap: Bool) { let callback = lock.withLock { self.callback }; callback?(gap) }
        func stop() { lock.withLock { callback = nil } }
    }
    private let state: State
    private let queue = DispatchQueue(label: "Lite2D.PerceptionFileChanges", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var vnodes: [DispatchSourceFileSystemObject] = []
    private let rootURL: URL
    private let names: Set<String>?
    private var stopped = false
    init(root: URL, allowedNames: Set<String>? = nil, changed: @escaping (Bool) -> Void) throws {
        rootURL = root.standardizedFileURL; names = allowedNames
        state = State(root: root.standardizedFileURL.path, names: allowedNames, callback: changed); queue.setSpecific(key: queueKey, value: true)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, raw, count, paths, flags, _ in
            guard let raw else { return }
            let state = Unmanaged<State>.fromOpaque(raw).takeUnretainedValue()
            let mask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            var gap = count > 128
            for i in 0..<min(count, 128) where flags[i] & mask != 0 { gap = true }
            if gap || state.allowedNames == nil { state.changed(gap); return }
            let values = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if values.prefix(128).contains(where: state.accepts) { state.changed(false) }
        }
        guard let value = FSEventStreamCreate(nil, callback, &context, [root.standardizedFileURL.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else { throw CompanionNotificationError.temporarilyUnavailable }
        stream = value; FSEventStreamSetDispatchQueue(value, queue)
        guard FSEventStreamStart(value) else { stop(); throw CompanionNotificationError.temporarilyUnavailable }
        queue.sync { rebuildVnodes() }
    }
    private func rebuildVnodes() {
        vnodes.forEach { $0.cancel() }; vnodes = []
        guard !stopped, let names else { return }
        // FSEvents can wait for an open WAL writer to close; vnode NOTE_WRITE observes committed appends promptly.
        for file in [rootURL] + names.sorted().map({ rootURL.appendingPathComponent($0) }) {
            let descriptor = Darwin.open(file.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
            let directory = file == rootURL
            source.setEventHandler { [weak self, weak source] in
                guard let self, !self.stopped, let source else { return }
                let flags = source.data
                let replaced = !flags.intersection([.delete, .rename, .revoke]).isEmpty
                self.state.changed(directory && replaced)
                if replaced || directory { self.rebuildVnodes() }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            vnodes.append(source); source.resume()
        }
    }
    func stop() {
        state.stop()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
        let finish = { self.stopped = true; self.vnodes.forEach { $0.cancel() }; self.vnodes = [] }
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() }
        else { queue.sync(execute: finish); queue.sync {} }
    }
    deinit { stop() }
}
