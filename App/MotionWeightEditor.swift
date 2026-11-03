import AppKit
import SwiftUI

enum MotionWeightEditorResult {
    case save([String: Double])
    case reset
    case cancel
}

final class MotionWeightEditorModel: ObservableObject {
    struct Row: Identifiable {
        let motion: ModelMotion
        var text: String
        var id: String { motion.key }
        var value: Double? {
            guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  number.isFinite, number >= 0 else { return nil }
            return number
        }
    }

    let title: String
    private let overrides: [String: Double]
    @Published var rows: [Row]
    var finish: (MotionWeightEditorResult) -> Void = { _ in }

    init(title: String, motions: [ModelMotion], overrides: [String: Double]) {
        self.title = title
        self.overrides = overrides
        rows = motions.map { Row(motion: $0, text: Self.display($0.weight(overrides: overrides))) }
    }

    var groups: [(name: String, indices: [Int])] {
        var result: [(name: String, indices: [Int])] = []
        for (index, row) in rows.enumerated() {
            if result.last?.name == row.motion.group { result[result.count - 1].indices.append(index) }
            else { result.append((row.motion.group, [index])) }
        }
        return result
    }

    var isValid: Bool { rows.allSatisfy { $0.value != nil } }
    var allZero: Bool { isValid && rows.allSatisfy { $0.value == 0 } }

    /// Overrides for every outfit survive; only the displayed motions are rewritten.
    func savedOverrides() -> [String: Double] {
        var next = overrides
        for row in rows {
            guard let value = row.value else { continue }
            if value == row.motion.defaultWeight { next.removeValue(forKey: row.motion.key) }
            else { next[row.motion.key] = value }
        }
        return next
    }

    func step(_ index: Int, by delta: Double) {
        let current = rows[index].value ?? 0
        rows[index].text = Self.display(max(0, current + delta))
    }

    static func display(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

private struct MotionWeightEditorView: View {
    @ObservedObject var model: MotionWeightEditorModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("组内按权重随机播放，允许连续重复。0 表示不自动播放；全部为 0 时停止自动选播。修改在下次选动作时生效。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.indices, id: \.self) { index in
                            weightRow(index)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("恢复默认") { model.finish(.reset) }
                if model.allZero {
                    Label("全部为 0，将停止自动播放", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("取消") { model.finish(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.finish(.save(model.savedOverrides())) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .frame(minHeight: 260, idealHeight: 520, maxHeight: 640)
    }

    private func weightRow(_ index: Int) -> some View {
        let row = model.rows[index]
        let invalid = row.value == nil
        return LabeledContent {
            HStack(spacing: 6) {
                TextField("", text: $model.rows[index].text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .foregroundStyle(invalid ? Color.red : Color.primary)
                    .accessibilityLabel("\(row.motion.group) · \(row.motion.name) 权重")
                Stepper("", onIncrement: { model.step(index, by: 1) },
                        onDecrement: { model.step(index, by: -1) })
                    .labelsHidden()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.motion.name).lineLimit(1).truncationMode(.middle)
                Text("默认 \(MotionWeightEditorModel.display(row.motion.defaultWeight))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum MotionWeightEditor {
    // Exposed so the self-test can drive the visible editor without synthetic input.
    static weak var current: MotionWeightEditorModel?
    static weak var window: NSWindow?

    /// Presents the editor as an app-modal window and returns the user's choice.
    static func run(title: String, motions: [ModelMotion], overrides: [String: Double]) -> MotionWeightEditorResult {
        MainActor.assumeIsolated { present(title: title, motions: motions, overrides: overrides) }
    }

    @MainActor
    private static func present(title: String, motions: [ModelMotion], overrides: [String: Double]) -> MotionWeightEditorResult {
        let model = MotionWeightEditorModel(title: title, motions: motions, overrides: overrides)
        let host = NSHostingController(rootView: MotionWeightEditorView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // Roughly fit the content (intro card, section headers, rows, button bar), capped for long lists.
        let fitted = 150 + CGFloat(model.rows.count) * 54 + CGFloat(model.groups.count) * 36
        window.setContentSize(NSSize(width: 460, height: min(640, max(320, fitted))))
        window.center()
        var result = MotionWeightEditorResult.cancel
        model.finish = { choice in
            result = choice
            NSApp.stopModal()
        }
        // The title-bar close button must also end the modal session.
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in NSApp.stopModal() }
        defer { NotificationCenter.default.removeObserver(closeObserver) }
        current = model; Self.window = window
        defer { current = nil; Self.window = nil; window.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return result
    }
}
