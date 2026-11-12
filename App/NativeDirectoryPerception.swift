import Foundation

struct CompanionWatchedDirectory: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var path: String
    var bookmark: Data?
    func resolve() throws -> URL {
        if let bookmark {
            var stale = false
            let value = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw CompanionNotificationError.permissionDenied }
            return value.standardizedFileURL
        }
        guard path.hasPrefix("/") else { throw CompanionNotificationError.permissionDenied }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    static func permitted(_ url: URL, ownDataRoot: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let own = ownDataRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        return !["/", "/Users", "/System", "/Library", "/Applications", "/Volumes", home, home + "/Library"].contains(path)
            && own != path && !own.hasPrefix(path + "/") && !path.hasPrefix(own + "/")
    }
}

actor NativeDirectoryPerception {
    private struct Active { let url: URL; let scoped: Bool; let watcher: CompanionPathWatch }
    private let ownDataRoot: URL
    private let sink: (CompanionMacSignal) -> Void
    private var active: [String: Active] = [:]
    private var epoch: Int?
    private var records: [CompanionWatchedDirectory] = []
    private var generation = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var health: Task<Void, Never>?
    private var pendingGaps: [String: Bool] = [:]
    private var lastEmission: [String: UInt64] = [:]
    init(ownDataRoot: URL, sink: @escaping (CompanionMacSignal) -> Void) { self.ownDataRoot = ownDataRoot; self.sink = sink }
    func configure(epoch: Int?, directories: [CompanionWatchedDirectory], sleeping: Bool) {
        let desired = sleeping ? nil : epoch
        guard self.epoch != desired || records != directories else { return }
        stop(); self.epoch = desired; records = directories
        guard let desired else { return }
        guard !directories.isEmpty else { sink(.init(source: "macos.files", type: "filesystem.status", subject: "no_authorized_directory", health: "needs_directory", epoch: desired)); return }
        guard directories.count <= 8 else { sink(.init(source: "macos.files", type: "filesystem.status", subject: "directory_limit", health: "error", epoch: desired)); return }
        let expected = generation
        for item in directories { attach(item, epoch: desired, generation: expected) }
        reportStatus(epoch: desired)
        health = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await self?.reconcile(generation: expected)
            }
        }
    }
    private func attach(_ item: CompanionWatchedDirectory, epoch: Int, generation expected: Int) {
        guard UUID(uuidString: item.id) != nil else { return }
        do {
            let url = try item.resolve(), scoped = url.startAccessingSecurityScopedResource()
            do {
                guard CompanionWatchedDirectory.permitted(url, ownDataRoot: ownDataRoot), try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CompanionNotificationError.permissionDenied }
                let watch = try CompanionPathWatch(root: url) { [weak self] gap in Task { await self?.changed(id: item.id, gap: gap, generation: expected) } }
                active[item.id] = .init(url: url, scoped: scoped, watcher: watch)
                sink(.init(source: "macos.files", type: "filesystem.baseline", subject: "directory_" + item.id, initial: true, epoch: epoch))
            } catch { if scoped { url.stopAccessingSecurityScopedResource() }; throw error }
        } catch { sink(.init(source: "macos.files", type: "filesystem.status", subject: "directory_unavailable", health: "permission_denied", epoch: epoch)) }
    }
    private func reportStatus(epoch: Int) {
        let state = active.isEmpty ? "permission_denied" : active.count < records.count ? "partially_available" : "available"
        sink(.init(source: "macos.files", type: "filesystem.status", subject: "authorized_directories", initial: true, health: state, epoch: epoch))
    }
    private func reconcile(generation expected: Int) {
        guard expected == generation, let epoch else { return }
        for item in records {
            if let current = active[item.id] {
                if (try? current.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                    current.watcher.stop(); if current.scoped { current.url.stopAccessingSecurityScopedResource() }; active.removeValue(forKey: item.id)
                    sink(.init(source: "macos.files", type: "filesystem.status", subject: "directory_unavailable", health: "permission_denied", epoch: epoch))
                }
            } else { attach(item, epoch: epoch, generation: expected) }
        }
        reportStatus(epoch: epoch)
    }
    private func changed(id: String, gap: Bool, generation expected: Int) {
        guard expected == generation, epoch != nil, active[id] != nil else { return }
        pendingGaps[id] = (pendingGaps[id] ?? false) || gap
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastEmission[id], now >= last, now - last < 1_000_000_000, !gap { return }
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            await self?.emitChange(id: id, gap: gap, generation: expected)
        }
    }
    private func emitChange(id: String, gap: Bool, generation expected: Int) {
        tasks.removeValue(forKey: id)
        let gap = (pendingGaps.removeValue(forKey: id) ?? false) || gap
        guard expected == generation, let epoch, let item = active[id] else { return }
        guard (try? item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            item.watcher.stop(); if item.scoped { item.url.stopAccessingSecurityScopedResource() }; active.removeValue(forKey: id)
            sink(.init(source: "macos.files", type: "filesystem.status", subject: "directory_unavailable", health: "permission_denied", epoch: epoch)); return
        }
        lastEmission[id] = DispatchTime.now().uptimeNanoseconds
        sink(.init(source: "macos.files", type: gap ? "filesystem.reconcile_needed" : "filesystem.changed", confidence: gap ? 0.5 : 1,
            subject: "directory_" + id, health: active.count < records.count ? "partially_available" : "available", epoch: epoch))
    }
    func stop() {
        generation += 1; epoch = nil
        health?.cancel(); health = nil
        tasks.values.forEach { $0.cancel() }; tasks = [:]; pendingGaps = [:]
        for item in active.values { item.watcher.stop(); if item.scoped { item.url.stopAccessingSecurityScopedResource() } }
        active = [:]; lastEmission = [:]
    }
}
