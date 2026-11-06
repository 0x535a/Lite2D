import Foundation

@main
struct CompanionSpeechTests {
    static func main() {
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); print("PASS: \(name)")
        }
        check(CompanionSpeech.sentences("第一句。第二句；第三句\n第四句") == ["第一句。", "第二句；", "第三句", "第四句"], "Explicit boundaries")
        check(CompanionSpeech.sentences("嗯！真的吗？先看看，结果如何") == ["嗯！真的吗？先看看，结果如何"], "Only specified punctuation splits")
        let twenty = String(repeating: "甲", count: 20)
        check(CompanionSpeech.sentences(twenty + "。”下一句") == [twenty + "。”", "下一句"], "Hard limit keeps trailing punctuation and quote")
        check(CompanionSpeech.sentences(twenty + "乙") == [twenty, "乙"], "Hard splitting loses no content")
        check(CompanionSpeech.count("这是 a-b test。") == 5, "English words and hyphenated words")
        let english = Array(repeating: "hello", count: 21).joined(separator: " ")
        let pieces = CompanionSpeech.sentences(english)
        check(pieces.count == 2 && CompanionSpeech.count(pieces[0]) == 20 && pieces[1] == "hello", "English words stay intact")
        check(CompanionSpeech.count("👨‍👩‍👧‍👦🇨🇳你好 café don't 3.14") == 7, "Graphemes, accented Latin, apostrophes and numbers")
        check(CompanionSpeech.sentences("\r\n  \n").isEmpty, "Blank input")
        check(CompanionSpeech.sentences("甲。\r\n乙") == ["甲。", "乙"], "Windows line breaks")
        check(CompanionSpeech.delay(for: "短句") == 1 && CompanionSpeech.delay(for: String(repeating: "甲", count: 10)) == 1, "Minimum delay")
        check(abs(CompanionSpeech.delay(for: String(repeating: "甲", count: 15)) - 1.5) < 0.001 && CompanionSpeech.delay(for: twenty) == 2, "Length-based delay")
        let sample = "记下啦：竞态修复要，旧 `cover_preview` 分支不碰——快速划卡片那种残留播放器，最好真机连着划几十张试试。"
        check(CompanionSpeech.sentences(sample).allSatisfy { CompanionSpeech.count($0) <= 20 }, "Mixed-language source sample")
    }
}
