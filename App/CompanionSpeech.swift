import Foundation

/// Presentation-only splitting; the original utterance remains intact in history.
enum CompanionSpeech {
    static let maximumLength = 20
    private static let boundaries: Set<Character> = ["。", "；", "！", "？", "…", "\n", "\r"]
    // Latin words stay intact; hyphens are deliberately separate tokens. Numbers are
    // grouped like words, while CJK characters and emoji each form one unit.
    private static let tokens = try! NSRegularExpression(pattern: #"\p{Latin}+(?:['’]\p{Latin}+)*|[0-9]+(?:\.[0-9]+)*"#)

    static func count(_ text: String) -> Int { units(text).filter(isCounted).count }
    static func retention(for text: String) -> TimeInterval {
        1 + Double(max(0, min(count(text), maximumLength) - 10)) * 0.1
    }
    static let typingInterval: TimeInterval = 0.05
    /// Each frame adds one counted unit, plus adjacent punctuation/whitespace.
    static func typingFrames(_ text: String) -> [String] {
        var frames: [String] = [], current = ""
        for token in units(text) {
            current += token
            if isCounted(token) { frames.append(current) }
            else if !frames.isEmpty { frames[frames.count - 1] = current }
        }
        return frames.isEmpty && !current.isEmpty ? [current] : frames
    }
    static func sentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        var length = 0
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""; length = 0
        }
        var ended = false
        for token in units(text) {
            if token.contains(where: { $0.isNewline }) { flush(); ended = false; continue }
            let counted = isCounted(token)
            if counted && (length == maximumLength || ended) { flush(); ended = false }
            // Keep closing punctuation/quotes attached even after reaching the limit.
            current += token
            if counted { length += 1 }
            if token.contains(where: { boundaries.contains($0) }) { ended = true }
        }
        flush()
        return result
    }
    private static func units(_ text: String) -> [String] {
        var result: [String] = []
        var cursor = text.startIndex
        for match in tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound].map(String.init)
            result.append(String(text[range])); cursor = range.upperBound
        }
        result += text[cursor...].map(String.init)
        return result
    }

    private static func isCounted(_ token: String) -> Bool {
        token.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
    }
}

/// Absolute deadlines keep typing and retention independent, even if a UI tick is late.
struct CompanionSpeechPlayback {
    let frames: [String]
    let startedAt: Date
    let completedAt: Date
    let expiresAt: Date
    init(text: String, startedAt: Date = Date()) {
        frames = CompanionSpeech.typingFrames(text)
        self.startedAt = startedAt
        completedAt = startedAt.addingTimeInterval(Double(frames.count) * CompanionSpeech.typingInterval)
        expiresAt = completedAt.addingTimeInterval(CompanionSpeech.retention(for: text))
    }
    func isTyping(at time: Date) -> Bool { time < completedAt }
    func isExpired(at time: Date) -> Bool { time >= expiresAt }
    func visibleText(at time: Date) -> String {
        guard !frames.isEmpty else { return "" }
        let index = min(frames.count - 1, max(0, Int(time.timeIntervalSince(startedAt) / CompanionSpeech.typingInterval)))
        return frames[index]
    }
}
