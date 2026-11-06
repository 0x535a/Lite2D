import AppKit
import SwiftUI

extension CompanionSelfTest {
    @MainActor func verifyGroups(_ c: CompanionCoordinator, a: ModelRecord, b: ModelRecord) async throws {
        guard let near = a.controller?.window else { throw CocoaError(.validationMissingMandatoryProperty) }
        c.settings.groups = []
        let legacy = try JSONDecoder().decode(CompanionCharacterSettings.self, from: Data("{}".utf8))
        try check(legacy.bubbleSide == .left && legacy.groupID == nil, "Old character settings default to left-side individual bubbles")
        let left = DisplayDescriptor(id: "left", name: "Left", frame: NSRect(x: -1200, y: 0, width: 1200, height: 900), visibleFrame: NSRect(x: -1200, y: 0, width: 1200, height: 880))
        let primary = DisplayDescriptor(id: "main", name: "Main", frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1040))
        var oldGroup = try JSONDecoder().decode(CompanionGroupSettings.self, from: Data(#"{"x":-1100,"y":60,"width":480,"height":360,"name":"Legacy"}"#.utf8))
        oldGroup.migrate(in: [left, primary])
        try check(oldGroup.displayUUID == "left" && oldGroup.displayPosition == DisplayPosition(x: 100, y: 60), "Legacy global Group frames migrate to display-relative bindings")
        let shifted = DisplayDescriptor(id: "left", name: "Left", frame: left.frame.offsetBy(dx: -300, dy: 200), visibleFrame: left.visibleFrame.offsetBy(dx: -300, dy: 200))
        try check(oldGroup.windowFrame(in: [shifted, primary])?.origin == NSPoint(x: -1400, y: 260), "Group positioning follows display rearrangement without changing relative coordinates")
        try check(oldGroup.windowFrame(in: [primary]) == nil && oldGroup.displayUUID == "left", "Disconnected Groups never fall back to another display")
        let solo = CompanionBubble()
        solo.configure(avatar: NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil), side: .right)
        solo.show(name: "", text: "独立气泡也能朝右，文字左对齐。", near: near)
        let soloRow = solo.panel.contentView!.subviews[0]
        let soloImage = soloRow.subviews.compactMap { $0 as? NSImageView }.first!
        let soloBody = soloRow.subviews.compactMap { $0 as? NSVisualEffectView }.first!
        try check(soloImage.frame.minX > soloBody.frame.maxX && solo.messageAlignments == [.left], "Individual bubbles also place right-side avatars and left-aligned text correctly")
        try capture(solo.panel, "companion-bubble-right"); solo.hide()
        let group = CompanionBubble(groupFrame: NSRect(x: 160, y: 180, width: 480, height: 280))
        let image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        group.show(name: "", text: "论文我修改了一版，你看看？", near: near, speakerID: a.settings.id, avatar: image, side: .right)
        group.show(name: "", text: "我看过了，也改了一版。", near: near, speakerID: b.settings.id, avatar: image, side: .left)
        group.show(name: "", text: "这句没有头像，文字仍然左对齐。", near: near, speakerID: a.settings.id, side: .right)
        try await Task.sleep(nanoseconds: 250_000_000)
        guard let scroll = group.scrollView, let document = scroll.documentView else { throw CocoaError(.validationMissingMandatoryProperty) }
        try check(group.messageFrames[0].maxX == scroll.contentSize.width && group.messageFrames[1].minX == 0, "Group rows align to the chosen window edge")
        try check(group.messageFrames[2].maxX == scroll.contentSize.width && group.messageAlignments.allSatisfy { $0 == .left }, "Right-side and avatar-free bubbles keep text left-aligned")
        let rightImage = document.subviews[0].subviews.compactMap { $0 as? NSImageView }.first!
        let rightBody = document.subviews[0].subviews.compactMap { $0 as? NSVisualEffectView }.first!
        try check(rightImage.frame.minX > rightBody.frame.maxX, "Right-side avatars sit outside the mirrored bubble tail")
        try check(group.messageFrames.last?.minY == 0 && document.frame.height >= scroll.contentSize.height, "Short conversations sit at the bottom of the fixed viewport")
        try check(group.panel.frame.size == NSSize(width: 480, height: 280), "Adding messages preserves Group window size")
        group.panel.display(); CATransaction.flush()
        try capture(group.panel, "companion-group-chat")
        if let close = group.closeButton(at: 2) {
            let center = NSPoint(x: close.bounds.midX, y: close.bounds.midY)
            group.updateHover(at: group.panel.convertPoint(toScreen: close.convert(center, to: nil)))
            try check(!close.isHidden && !group.panel.ignoresMouseEvents, "Group scrolling and hover close controls remain interactive")
            close.performClick(nil)
            try check(group.sentenceCount == 2 && group.texts(for: b.settings.id).count == 1, "Closing a Group message leaves other speakers' messages intact")
        }
        for index in 0..<10 {
            group.show(name: "", text: "第\(index)条：This long message wraps inside the fixed conversation window without horizontal overflow.", near: near,
                       speakerID: index % 2 == 0 ? a.settings.id : b.settings.id, side: index % 2 == 0 ? .left : .right)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(document.frame.height > scroll.contentSize.height && group.followsLatest, "Overflow scrolls vertically and follows the latest message")
        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: wheel) {
            scroll.scrollWheel(with: event)
            try await Task.sleep(nanoseconds: 100_000_000)
            try check(scroll.contentView.bounds.minY > 0, "Mouse wheel still scrolls vertically with the scrollbars hidden")
            scroll.contentView.scroll(to: .zero)
        }
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
        try check(scroll.contentView.bounds.minX == 0 && !scroll.hasHorizontalScroller && !scroll.hasVerticalScroller && !group.followsLatest, "Both scrollbars are hidden, horizontal scrolling is disabled, and scrolling up pauses following")
        let visible = document.subviews.first { $0.frame.intersects(scroll.contentView.bounds) }!
        let previousOffset = visible.frame.minY - scroll.contentView.bounds.minY
        group.show(name: "", text: "New message while reading older messages.", near: near, speakerID: a.settings.id)
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(!group.followsLatest && abs(visible.frame.minY - scroll.contentView.bounds.minY - previousOffset) < 1, "Incoming messages preserve the visible reading position")
        scroll.contentView.scroll(to: .zero)
        group.show(name: "", text: "回到底部后继续跟随。", near: near, speakerID: b.settings.id)
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(group.followsLatest, "Following resumes when the reader returns to the bottom")
        group.panel.setFrame(NSRect(x: 160, y: 180, width: 280, height: 220), display: true)
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(document.frame.width == scroll.contentSize.width && group.messageFrames.allSatisfy { $0.minX >= 0 && $0.maxX <= scroll.contentSize.width + 0.5 }, "Resizing reflows every row without horizontal overflow")
        try capture(group.panel, "companion-group-narrow")
        group.removeSpeaker(a.settings.id)
        try check(group.speakerIDs == Set([b.settings.id]) && group.sentenceCount > 0, "Removing one member leaves the other member's messages intact")
        group.hide()

        let id = c.addGroup()
        c.assignGroup(a.settings.id, to: id); c.assignGroup(b.settings.id, to: id)
        c.updateCharacter(b.settings.id) { $0.bubbleSide = .right }
        let persisted = try JSONDecoder().decode(CompanionSettings.self, from: JSONEncoder().encode(c.settings))
        try check(persisted.groups.contains { $0.id == id } && persisted.characters[b.settings.id.uuidString]?.groupID == id && persisted.characters[b.settings.id.uuidString]?.bubbleSide == .right, "Group geometry, membership and per-model side survive serialization")
        try check(!c.canPlaceBubble(a.settings.id), "Grouped characters use Group placement instead of individual offsets")
        let settingsWindow = status.settingsWindow
        settingsWindow.show(); settingsWindow.model.selection = CompanionGroupSelection.tag(id)
        manager.onChange?()
        try check(settingsWindow.model.selection == CompanionGroupSelection.tag(id) && settingsWindow.model.isValidSelection(CompanionGroupSelection.tag(id)), "Group sidebar selection survives character and display updates")
        try await Task.sleep(nanoseconds: 180_000_000)
        if let window = settingsWindow.window { try capture(window, "companion-group-settings") }
        settingsWindow.window?.orderOut(nil)
        c.beginGroupPlacement(id)
        guard let shared = c.groupWindow(id) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let historyBeforePreview = c.entries.count
        try check(shared.groupPreviewTexts.count >= 3 && shared.sentenceCount == 0 && Set(shared.messageSides) == Set([.left, .right]), "Adjustment mode shows a complete preview using member directions")
        try capture(shared.panel, "companion-group-placement-preview")
        shared.advance(to: Date().addingTimeInterval(600))
        try check(shared.groupPreviewTexts.count >= 3 && c.entries.count == historyBeforePreview, "Preview stays visible without expiring or writing fake history")
        c.updateGroup(id) { $0.name = "Group Test" }
        try check(shared.panel.isVisible, "Changing settings while Companion is disabled preserves the adjustment window")
        try check(shared.panel.styleMask.contains(.titled) && shared.panel.styleMask.contains(.resizable), "Adjustment mode exposes native window dragging and resizing")
        shared.panel.setContentSize(NSSize(width: 420, height: 240)); shared.panel.setFrameOrigin(NSPoint(x: 240, y: 200))
        c.finishGroupPlacement(id, save: true)
        let saved = c.groupFrame(c.settings.groups.first { $0.id == id }!)!
        try check(saved.size == NSSize(width: 420, height: 240) && !shared.panel.styleMask.contains(.titled) && shared.groupPreviewTexts.isEmpty, "Finishing adjustment saves content dimensions and restores the frameless window")
        c.beginGroupPlacement(id); shared.panel.setContentSize(NSSize(width: 500, height: 320))
        c.finishGroupPlacement(id, save: false)
        try check(shared.panel.frame == saved, "Cancelling Group adjustment restores the previous frame")
        c.settings.bubbleRetentionSeconds = 8
        for (sequence, record, text) in [(100, a, "甲。乙。"), (101, b, "丙！丁？"), (102, a, "戊。") ] {
            c.receive(["type": "utterance", "sequence": sequence, "characterId": record.settings.id.uuidString, "text": text])
        }
        for _ in 0..<40 {
            if shared.displayedTexts == ["甲。", "乙。", "丙！", "丁？", "戊。"] { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        c.tick()
        try check(shared.displayedTexts == ["甲。", "乙。", "丙！", "丁？", "戊。"] && shared.messageSides == [.left, .left, .right, .right, .left], "One shared queue mixes speakers in arrival order with their own sides: \(shared.displayedTexts) \(shared.messageSides)")
        let originalVisibility = a.settings.isVisible
        a.settings.isVisible = false; c.tick()
        try check(shared.displayedTexts == ["丙！", "丁？"], "Hiding one model only clears that member's Group messages")
        a.settings.isVisible = originalVisibility; c.stopTopic()
        c.receive(["type": "utterance", "sequence": 105, "characterId": a.settings.id.uuidString, "text": String(repeating: "甲", count: 20)])
        c.receive(["type": "utterance", "sequence": 106, "characterId": b.settings.id.uuidString, "text": "乙。"])
        a.settings.isVisible = false; c.tick()
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(shared.displayedTexts == ["乙。"], "Hiding a typing member releases the shared queue for the next speaker")
        a.settings.isVisible = originalVisibility; c.stopTopic()
        c.receive(["type": "utterance", "sequence": 107, "characterId": b.settings.id.uuidString, "text": "正在调整时，真实消息也会继续播放。"])
        c.beginGroupPlacement(id)
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(shared.groupPreviewTexts.count >= 3 && !shared.displayedTexts.isEmpty && (shared.displayedTexts.first?.count ?? 0) > 1, "Full preview leaves real typing and its deadlines running independently")
        c.finishGroupPlacement(id, save: false)
        try check(shared.groupPreviewTexts.isEmpty && shared.sentenceCount == 1, "Leaving adjustment restores real messages and removes only preview content")
        c.stopTopic()
        let other = c.addGroup(); c.assignGroup(b.settings.id, to: other)
        c.receive(["type": "utterance", "sequence": 103, "characterId": a.settings.id.uuidString, "text": String(repeating: "甲", count: 20)])
        c.receive(["type": "utterance", "sequence": 104, "characterId": b.settings.id.uuidString, "text": "乙。"])
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(c.speechTexts(b.settings.id) == ["乙。"] && (c.speechTexts(a.settings.id).first?.count ?? 0) < 20, "Independent Groups type concurrently without blocking each other")
        c.stopTopic()
        let originalTopology = manager.displayRegistry.testingDisplays
        let displays = manager.displayRegistry.displays
        if let physical = displays.first(where: { $0.id == c.settings.groups.first(where: { $0.id == id })?.displayUUID }) {
            let virtual = DisplayDescriptor(id: "group-test-display", name: "Group Test Display", frame: physical.frame, visibleFrame: physical.visibleFrame)
            manager.displayRegistry.testingDisplays = displays + [virtual]
            c.bindGroup(id, to: virtual.id)
            let binding = c.settings.groups.first { $0.id == id }!
            try check(binding.displayUUID == virtual.id && binding.displayPosition != nil, "Each Group can be explicitly bound to its own display")
            c.receive(["type": "utterance", "sequence": 108, "characterId": a.settings.id.uuidString, "text": "甲。"])
            manager.displayRegistry.testingDisplays = displays; c.tick()
            try check(!shared.panel.isVisible && !c.isGroupDisplayConnected(id) && c.settings.groups.first(where: { $0.id == id })?.displayUUID == virtual.id, "Display disconnect hides the Group while preserving its binding")
            c.receive(["type": "utterance", "sequence": 109, "characterId": a.settings.id.uuidString, "text": "不会跳到另一块屏幕。"])
            try check(shared.sentenceCount == 0 && c.groupEditingID == nil, "Disconnected Group messages do not appear on an available fallback display")
            let movedVirtual = DisplayDescriptor(id: virtual.id, name: virtual.name, frame: virtual.frame.offsetBy(dx: 20, dy: 20), visibleFrame: virtual.visibleFrame.offsetBy(dx: 20, dy: 20))
            manager.displayRegistry.testingDisplays = displays + [movedVirtual]; c.tick()
            try check(c.isGroupDisplayConnected(id) && shared.panel.frame == binding.windowFrame(in: displays + [movedVirtual]), "Reconnecting the display restores the Group at its bound relative position")
            c.bindGroup(id, to: physical.id)
        }
        manager.displayRegistry.testingDisplays = originalTopology; c.tick()
        c.deleteGroup(id); c.deleteGroup(other)
        try check(settingsWindow.model.selection == "general", "Deleting the selected Group returns the sidebar to a valid page")
        try check(c.group(for: a.settings.id) == nil && c.group(for: b.settings.id) == nil && c.canPlaceBubble(a.settings.id), "Deleting Groups returns members to individual bubbles")
        c.updateCharacter(b.settings.id) { $0.bubbleSide = .left }
    }
}
