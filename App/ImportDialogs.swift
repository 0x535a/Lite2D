import AppKit
import SwiftUI

// MARK: - Character picker

final class CharacterPickerModel: ObservableObject {
    struct Item: Identifiable {
        let id: Int
        let name: String
        let generatedName: GeneratedName?
        var localizedName: String { generatedName?.text ?? name }
        let outfitCount: Int
    }

    let sourceName: String
    let warnings: [LocalizedMessage]
    let items: [Item]
    let single: Bool
    @Published var selection: Set<Int>
    var finish: ([Int]?) -> Void = { _ in }

    init(sourceName: String, characters: [ImportedCharacter], warnings: [LocalizedMessage], single: Bool) {
        self.sourceName = sourceName
        self.warnings = warnings
        self.single = single
        items = characters.enumerated().map { Item(id: $0.offset, name: $0.element.name, generatedName: $0.element.generatedName, outfitCount: $0.element.outfitCount) }
        selection = single ? [0] : Set(characters.indices)
    }

    var title: String { single ? L10n.text("import.select_replace") : L10n.text("import.select_add") }
    var confirmTitle: String { single ? L10n.text("action.replace") : L10n.text("import.add_selected") }
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
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var model: CharacterPickerModel
    private static let warningLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title).font(.title3.weight(.semibold))
                Label(model.sourceName, systemImage: "shippingbox")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(model.single ? L10n.text("import.single_help")
                                  : L10n.text("import.multiple_help"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)
            Form {
                if !model.warnings.isEmpty {
                    Section(L10n.text("import.warnings")) {
                        ForEach(Array(model.warnings.prefix(Self.warningLimit).enumerated()), id: \.offset) { _, warning in
                            Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.callout)
                        }
                        if model.warnings.count > Self.warningLimit {
                            Text(L10n.count("import.more_warnings", model.warnings.count - Self.warningLimit))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if model.single {
                        Picker(L10n.text("role.section"), selection: Binding(get: { model.selection.first ?? 0 }, set: { model.set($0, selected: true) })) {
                            ForEach(model.items) { Text(label(for: $0)).tag($0.id) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                    } else {
                        ForEach(model.items) { item in
                            Toggle(isOn: Binding(get: { model.selection.contains(item.id) },
                                                 set: { model.set(item.id, selected: $0) })) {
                                HStack {
                                    Text(item.localizedName).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(L10n.count("outfit.count", item.outfitCount)).foregroundStyle(.secondary)
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
                    Button(model.allSelected ? L10n.text("action.deselect_all") : L10n.text("action.select_all")) { model.toggleAll() }
                    Text(L10n.text("import.selection_count", String(model.selection.count), String(model.items.count)))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button(L10n.text("action.cancel")) { model.cancel() }.keyboardShortcut(.cancelAction)
                Button(model.confirmTitle) { model.confirm() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
    }

    private func label(for item: CharacterPickerModel.Item) -> String { L10n.text("import.character_label", item.localizedName, L10n.count("outfit.count", item.outfitCount)) }
}

enum CharacterPicker {
    // Exposed so the self-test can drive the visible window without synthetic input.
    static weak var current: CharacterPickerModel?
    static weak var window: NSWindow?

    /// Shows the picker as an app-modal window; returns the chosen indices, or nil when cancelled.
    static func run(sourceName: String, characters: [ImportedCharacter], warnings: [LocalizedMessage], single: Bool) -> [Int]? {
        MainActor.assumeIsolated {
            let model = CharacterPickerModel(sourceName: sourceName, characters: characters, warnings: warnings, single: single)
            let rows = CGFloat(characters.count) * 37
            let notes = CGFloat(min(model.warnings.count, 8)) * 28 + (model.warnings.isEmpty ? 0 : 50)
            let height = min(620, max(300, 205 + rows + notes))
            let host = ModalHost(titleKey: "import.title", content: CharacterPickerView(model: model),
                                 size: NSSize(width: 560, height: height))
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
    @Published var detail: String?
}

private struct ImportProgressView: View {
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var model: ImportProgressModel
    var body: some View {
        HStack(spacing: 16) {
            ProgressView().controlSize(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("import.progress")).font(.headline)
                Text(model.detail ?? L10n.text("import.preparing")).font(.callout).foregroundStyle(.secondary)
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
        panel.title = L10n.text("import.title")
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
    private var languageObserver: NSObjectProtocol?

    init<Content: View>(titleKey: String, content: Content, size: NSSize) {
        window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = L10n.text(titleKey)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak window] _ in
            window?.title = L10n.text(titleKey)
        }
    }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
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

private struct LocalizedErrorView: View {
    @ObservedObject private var language = LanguageStore.shared
    let titleKey: String
    let message: LocalizedMessage
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(titleKey)).font(.headline)
            ScrollView { Text(message.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack { Spacer(); Button(L10n.text("action.close"), action: dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480, height: 280)
    }
}

enum LocalizedErrorDialog {
    static func run(titleKey: String, message: LocalizedMessage) {
        MainActor.assumeIsolated { build(titleKey: titleKey, message: message) }
    }
    @MainActor private static func build(titleKey: String, message: LocalizedMessage) {
        var host: ModalHost?
        let view = LocalizedErrorView(titleKey: titleKey, message: message) { host?.end() }
        host = ModalHost(titleKey: titleKey, content: view, size: NSSize(width: 480, height: 280))
        host?.run()
        host = nil
    }
}
