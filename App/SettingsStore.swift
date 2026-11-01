import Foundation

final class SettingsStore {
    let url: URL
    private var pending: DispatchWorkItem?
    private(set) var lastError: String?

    init(url: URL? = nil) {
        if let url { self.url = url }
        else if let path = ProcessInfo.processInfo.environment["LITE2D_SETTINGS_PATH"] {
            self.url = URL(fileURLWithPath: path)
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lite2D/settings.json")
        }
    }
    func load() -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        do { return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url)) }
        catch {
            lastError = "读取设置失败，已保留原文件：\(error.localizedDescription)"
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return AppSettings()
        }
    }
    func schedule(_ settings: AppSettings) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(settings) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func save(_ settings: AppSettings) {
        pending?.cancel(); pending = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
            lastError = nil
        } catch { lastError = "保存设置失败：\(error.localizedDescription)"; NSLog("%@", lastError!) }
    }
}
