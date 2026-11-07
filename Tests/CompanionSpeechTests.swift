import Foundation

@main
struct CompanionSpeechTests {
    static func main() {
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); print("PASS: \(name)")
        }
        check(CompanionSpeech.sentences("第一句。第二句；第三句\n第四句") == ["第一句。", "第二句；", "第三句", "第四句"], "Explicit boundaries")
        check(CompanionSpeech.sentences("嗯！真的吗？先看看，结果如何") == ["嗯！", "真的吗？", "先看看，结果如何"], "Chinese exclamation and question boundaries")
        check(CompanionSpeech.sentences("嗯……再想想…………好了。") == ["嗯……", "再想想…………", "好了。"], "Repeated ellipsis stays with the preceding sentence")
        let twenty = String(repeating: "甲", count: 20)
        check(CompanionSpeech.sentences(twenty + "。”下一句") == [twenty + "。”", "下一句"], "Explicit boundary keeps trailing punctuation and quote")
        check(CompanionSpeech.sentences(twenty + "乙") == [twenty + "乙"], "Long unpunctuated sentences stay intact")
        check(CompanionSpeech.count("这是 a-b test。") == 5, "English words and hyphenated words")
        let english = Array(repeating: "hello", count: 21).joined(separator: " ")
        let pieces = CompanionSpeech.sentences(english)
        check(pieces == [english], "English sentences have no hard word limit")
        check(CompanionSpeech.sentences(twenty + "，乙，丙") == [twenty + "，乙，", "丙"], "Punctuation at exactly twenty waits for a later punctuation after exceeding twenty")
        check(CompanionSpeech.sentences(twenty + "乙丙，丁") == [twenty + "乙丙，", "丁"], "Long sentences split at the next comma")
        for punctuation in ["、", "：", ":", ",", "!", "?", ";", "—"] {
            check(CompanionSpeech.sentences(twenty + "乙" + punctuation + "后文") == [twenty + "乙" + punctuation, "后文"], "Soft boundary supports \(punctuation)")
        }
        check(CompanionSpeech.sentences(twenty + "乙，！”后文") == [twenty + "乙，！”", "后文"], "Repeated punctuation and closing quotes remain attached")
        check(CompanionSpeech.sentences(english + ", next words") == [english + ",", "next words"], "Soft length counts English words")
        check(CompanionSpeech.sentences(english + " don't stop, next") == [english + " don't stop,", "next"], "Apostrophes inside words do not become punctuation boundaries")
        check(CompanionSpeech.count("👨‍👩‍👧‍👦🇨🇳你好 café don't 3.14") == 7, "Graphemes, accented Latin, apostrophes and numbers")
        check(CompanionSpeech.sentences("\r\n  \n").isEmpty, "Blank input")
        check(CompanionSpeech.sentences("甲。\r\n乙") == ["甲。", "乙"], "Windows line breaks")
        check(CompanionSpeech.typingFrames("你好，世界！") == ["你", "你好，", "你好，世", "你好，世界！"], "Punctuation adds no typing delay")
        check(CompanionSpeech.typingFrames("“a-b test!”") == ["“a-", "“a-b ", "“a-b test!”"], "English words type intact with adjacent punctuation")
        let start = Date(timeIntervalSince1970: 100)
        let playback = CompanionSpeechPlayback(text: String(repeating: "甲", count: 15), startedAt: start, retention: 5)
        check(playback.visibleText(at: start).count == 1 && playback.visibleText(at: start.addingTimeInterval(0.16)).count == 4, "Typing progresses at 50ms per unit")
        check(abs(playback.completedAt.timeIntervalSince(start) - 0.75) < 0.001 && abs(playback.expiresAt.timeIntervalSince(start) - 5.75) < 0.001, "Retention starts only after typing finishes")
        check(!playback.isExpired(at: start.addingTimeInterval(5.74)) && playback.isExpired(at: start.addingTimeInterval(5.75)), "Independent expiry deadline")
        let second = CompanionSpeechPlayback(text: twenty, startedAt: playback.completedAt)
        check(second.isTyping(at: start.addingTimeInterval(1)) && !playback.isTyping(at: start.addingTimeInterval(1)) && !playback.isExpired(at: start.addingTimeInterval(1)), "Next typing overlaps previous retention")
        let short = CompanionSpeechPlayback(text: "短句", startedAt: start, retention: 5)
        check(short.expiresAt.timeIntervalSince(short.completedAt) == playback.expiresAt.timeIntervalSince(playback.completedAt), "All lengths share the configured retention")
        var updated = playback; updated.setRetention(12)
        check(updated.completedAt == playback.completedAt && updated.expiresAt == playback.completedAt.addingTimeInterval(12), "Duration updates keep the original typing deadline")
        check(CompanionSpeechPlayback.normalizedRetention(0) == 1 && CompanionSpeechPlayback.normalizedRetention(999) == 300 && CompanionSpeechPlayback.normalizedRetention(.nan) == 8, "Duration bounds and defaults")
        let sample = "记下啦：竞态修复要，旧 `cover_preview` 分支不碰——快速划卡片那种残留播放器，最好真机连着划几十张试试。"
        check(CompanionSpeech.sentences(sample).joined() == sample && CompanionSpeech.sentences(sample).contains { CompanionSpeech.count($0) > 20 }, "Mixed-language source has no hard limit and loses no content")
        let longPlayback = CompanionSpeechPlayback(text: String(repeating: "甲", count: 60), startedAt: start, retention: 8)
        check(longPlayback.frames.count == 60 && longPlayback.completedAt == start.addingTimeInterval(3) && longPlayback.expiresAt == start.addingTimeInterval(11), "Long sentences type fully and retain the same configured countdown")
    }
}
