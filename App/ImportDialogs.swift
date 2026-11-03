import AppKit
import SwiftUI

// MARK: - Character picker

final class CharacterPickerModel: ObservableObject {
    struct Item: Identifiable {
        let id: Int
        let name: String
        let outfitCount: Int
    }

    let sourceName: String
    let warnings: [String]
    let items: [Item]
    let single: Bool
    @Published var selection: Set<Int>
    var finish: ([Int]?) -> Void = { _ in }

    init(sourceName: String, characters: [ImportedCharacter], warnings: [String], single: Bool) {
        self.sourceName = sourceName
        self.warnings = warnings
        self.single = single
        items = characters.enumerated().map { Item(id: $0.offset, name: $0.element.name, outfitCount: $0.element.outfitCount) }
        selection = single ? [0] : Set(characters.indices)
    }

    var title: String { single ? "选择要替换的角色" : "选择要添加的角色" }
    var confirmTitle: String { single ? "替换" : "添加所选角色" }
    var canConfirm: Bool { single ? selection.count == 1 : !selection.isEmpty }
    var allSelected: Bool { selection.count == items.count }

    func set(_ index: Int, selected: Bool) {
        if single { selection = [index] }
        else if selected { selection.insert(index) }
        else { selection.remove(index) }
    }
    func toggleAll() { selection = allSelected ? [] : Set(items.map(\.id)) }
    func confirm() { if canConfirm { finish(selection.sorted()) } }
    func cancel() { finish(nil) }
}

private struct CharacterPickerView: View {
    @ObservedObject var model: CharacterPickerModel
    private static let warningLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title).font(.title3.weight(.semibold))
                Label(model.sourceName, systemImage: "shippingbox")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(model.single ? "这个模型包含多个角色，请选择其中一个。"
                                  : "每个角色会作为独立角色添加，服装保留在各自的换装选项中。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)
            Form {
                if !model.warnings.isEmpty {
                    Section("注意") {
                        ForEach(Array(model.warnings.prefix(Self.warningLimit).enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.callout)
                        }
                        if model.warnings.count > Self.warningLimit {
                            Text("另有 \(model.warnings.count - Self.warningLimit) 条提示")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if model.single {
                        Picker("角色", selection: Binding(get: { model.selection.first ?? 0 }, set: { model.set($0, selected: true) })) {
                            ForEach(model.items) { Text(label(for: $0)).tag($0.id) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                    } else {
                        ForEach(model.items) { item in
                            Toggle(isOn: Binding(get: { model.selection.contains(item.id) },
                                                 set: { model.set(item.id, selected: $0) })) {
                                HStack {
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("\(item.outfitCount) 套服装").foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !model.single {
                    Button(model.allSelected ? "取消全选" : "全选") { model.toggleAll() }
                    Text("已选 \(model.selection.count) / \(model.items.count)")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("取消") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button(model.confirmTitle) { model.confirm() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460)
    }

    private func label(for item: CharacterPickerModel.Item) -> String { "\(item.name)（\(item.outfitCount) 套服装）" }
}

enum CharacterPicker {
    // Exposed so the self-test can drive the visible window without synthetic input.
    static weak var current: CharacterPickerModel?
    static weak var window: NSWindow?

    /// Shows the picker as an app-modal window; returns the chosen indices, or nil when cancelled.
    static func run(sourceName: String, characters: [ImportedCharacter], warnings: [String], single: Bool) -> [Int]? {
        MainActor.assumeIsolated {
            let model = CharacterPickerModel(sourceName: sourceName, characters: characters, warnings: warnings, single: single)
            let rows = CGFloat(characters.count) * 37
            let notes = CGFloat(min(model.warnings.count, 8)) * 28 + (model.warnings.isEmpty ? 0 : 50)
            let height = min(620, max(300, 205 + rows + notes))
            let host = ModalHost(title: "导入角色", content: CharacterPickerView(model: model),
                                 size: NSSize(width: 460, height: height))
            var result: [Int]?
            model.finish = { choice in result = choice; host.end() }
            current = model; window = host.window
            defer { current = nil; window = nil }
            host.run()
            return result
        }
    }
}

// MARK: - Import progress

final class ImportProgressModel: ObservableObject {
    @Published var detail = "正在整理模型资源…"
}

private struct ImportProgressView: View {
    @ObservedObject var model: ImportProgressModel
    var body: some View {
        HStack(spacing: 16) {
            ProgressView().controlSize(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在导入角色").font(.headline)
                Text(model.detail).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(width: 380)
    }
}

enum ImportProgressPanel {
    static func make(model: ImportProgressModel) -> NSPanel {
        MainActor.assumeIsolated { build(model: model) }
    }
    @MainActor private static func build(model: ImportProgressModel) -> NSPanel {
        let panel = NSPanel(contentViewController: NSHostingController(rootView: ImportProgressView(model: model)))
        panel.styleMask = [.titled]
        panel.title = "导入角色"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.center()
        return panel
    }
}

// MARK: - Shared modal window

/// A titled window hosting SwiftUI content, run app-modally. Closing the title-bar button also ends the session.
@MainActor final class ModalHost {
    let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init<Content: View>(title: String, content: Content, size: NSSize) {
        window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
    }

    func run() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in NSApp.stopModal() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        window.orderOut(nil)
    }

    func end() { NSApp.stopModal() }
}
