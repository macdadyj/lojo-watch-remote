import XCTest

/// Taps the home list, a past session, Speak, and I'm done on the watchOS simulator.
/// The app is launched with `-WatchRemoteUITest`, so the microphone and the real host stay off.
final class WatchScaffoldUITests: XCTestCase {
    /// `DemoCatalog` session ids. Kept here so this bundle does not link the app target's package twice.
    private static let sessionRowIDs = [
        "0199aaaa-0000-7000-8000-000000000001",
        "0199aaaa-0000-7000-8000-000000000002",
        "0199aaaa-0000-7000-8000-000000000003",
    ]
    private static let idleSessionID = "0199aaaa-0000-7000-8000-000000000003"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScaffoldTapsHomeSessionAndSpeak() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WatchRemoteUITest", "-WatchRemoteInjectClip", "pause-task"]
        app.launch()

        let list = app.scrollViews["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "home session list did not appear")
        XCTAssertFalse(
            app.staticTexts["Test clip missing."].exists,
            "audio injection hook could not load pause-task"
        )
        assertSpeakClearsLastVisible(Self.sessionRows(app), in: app, scrollID: "session.list")
        assertActionHintFits(app)
        shot(app, "scaffold-home")

        let row = reveal(app.buttons["session.row.\(Self.idleSessionID)"], in: list)
        XCTAssertTrue(row.waitForExistence(timeout: 8), "idle session row missing")
        row.tap()

        let restored = app.scrollViews["voice.history"]
        XCTAssertTrue(restored.waitForExistence(timeout: 8), "tapping a past chat did not reopen it")
        XCTAssertTrue(
            app.staticTexts["Note the overlay route"].waitForExistence(timeout: 4),
            "restored chat did not show its messages"
        )
        XCTAssertTrue(
            app.staticTexts["The computer is reachable only on the private overlay."].waitForExistence(timeout: 4),
            "restored chat did not show the session summary"
        )
        let tools = app.buttons["voice.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 4), "tool calls were not grouped")
        XCTAssertTrue(tools.label.contains("Worked"), "tool calls were not grouped")
        XCTAssertFalse(app.staticTexts["Tool: Tool"].exists, "a nameless tool row is still a transcript line")
        XCTAssertFalse(
            app.staticTexts["Execute curl -fsS https://example.invalid/weather"].exists,
            "a raw command is visible before the tool row is expanded"
        )
        XCTAssertFalse(
            app.staticTexts["That chat is no longer on this computer."].exists,
            "a live demo session was reported missing"
        )
        let speak = app.buttons["voice.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 8), "restored chat did not stay open")
        assertSpeakClearsLastVisible(Self.transcriptLines(app), in: app, scrollID: "voice.history")
        assertActionHintFits(app)
        shot(app, "scaffold-restored")
        speak.tap()

        let status = app.staticTexts["voice.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), "listening state did not appear")
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Listening", "Listening"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [listening], timeout: 8),
            .completed,
            "Speak did not show Listening"
        )
        XCTAssertTrue(
            app.staticTexts["Note the overlay route"].waitForExistence(timeout: 4),
            "restored messages disappeared after Speak"
        )
        shot(app, "scaffold-listening")

        let done = app.buttons["voice.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "I'm done control missing while listening")
        XCTAssertEqual(done.label, "I'm done")
        done.tap()

        let history = app.scrollViews["voice.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 8), "I'm done closed the chat")
        XCTAssertFalse(list.isHittable, "I'm done left the conversation")
        XCTAssertTrue(
            app.staticTexts["list sessions"].waitForExistence(timeout: 4),
            "I'm done did not send what was said"
        )
        XCTAssertTrue(
            app.staticTexts["Note the overlay route"].exists,
            "I'm done dropped the open chat"
        )
        let sent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Sent", "Sent"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 8), .completed, "I'm done did not show Sent")
        XCTAssertTrue(app.buttons["voice.speak"].waitForExistence(timeout: 4), "I'm done removed Speak")
        assertSpeakClearsLastVisible(Self.transcriptLines(app), in: app, scrollID: "voice.history")
        shot(app, "scaffold-done")
    }

    /// The home list and a long transcript keep more than one row on screen. Counts happen before any swipe.
    func testHomeShowsTwoChatsAndTheTranscriptShowsEnoughBubbles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WatchRemoteUITest"]
        app.launch()

        let list = app.scrollViews["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "home session list did not appear")
        let first = app.buttons["session.row.\(Self.sessionRowIDs[0])"]
        XCTAssertTrue(first.waitForExistence(timeout: 8), "home rows did not appear")
        let visibleRows = Self.sessionRows(app).filter { shown($0, in: list) }
        let frames = Self.sessionRows(app).map { "\($0.identifier) \($0.exists) \($0.frame)" }.joined(separator: "; ")
        XCTAssertGreaterThanOrEqual(
            visibleRows.count,
            2,
            "home shows \(visibleRows.count) chat rows in \(list.frame); \(frames)"
        )

        let longID = "0199aaaa-0000-7000-8000-000000000005"
        let row = reveal(app.buttons["session.row.\(longID)"], in: list)
        XCTAssertTrue(row.waitForExistence(timeout: 8), "long chat row missing")
        row.tap()

        let history = app.scrollViews["voice.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 8), "long chat did not open")
        let lines = app.staticTexts.matching(identifier: "voice.line")
        let reply = lines.matching(NSPredicate(format: "label == %@", "Yes. The latest line is this one.")).firstMatch
        let mine = lines.matching(NSPredicate(format: "label == %@", "Still with me?")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 8), "latest reply missing")
        XCTAssertTrue(mine.waitForExistence(timeout: 4), "user line missing")

        let needed = app.frame.height >= 230 ? 3 : 2
        let visibleEnough = NSPredicate { _, _ in
            self.visibleBubbleCount(in: history, app: app) >= needed
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleEnough, object: nil)], timeout: 6),
            .completed,
            "transcript shows \(visibleBubbleCount(in: history, app: app)) bubbles in \(history.frame); wanted \(needed); \(bubbleFrames(app))"
        )
        let visible = visibleBubbleCount(in: history, app: app)
        XCTAssertTrue(shown(reply, in: history), "latest reply is off screen")
        XCTAssertTrue(shown(mine, in: history), "user line is off screen")
        XCTAssertGreaterThan(mine.frame.maxX, history.frame.midX, "user bubble is not on the right")
        XCTAssertLessThan(mine.frame.width, history.frame.width * 0.92, "user bubble fills the row")
        XCTAssertLessThan(reply.frame.minX, history.frame.midX, "assistant bubble does not start on the left")
        let status = app.staticTexts["voice.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 4), "delivery status missing")
        XCTAssertGreaterThan(status.frame.midY, reply.frame.midY, "delivery status is not under the last bubble")
        shot(app, "scaffold-bubbles")
    }

    /// Speak sits under the scroll view. Its frame must not cross the scroll view or the visible part of the lowest row.
    private func assertSpeakClearsLastVisible(
        _ elements: [XCUIElement],
        in app: XCUIApplication,
        scrollID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let speak = app.buttons["voice.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 8), "Speak missing", file: file, line: line)
        let scroll = app.scrollViews[scrollID]
        XCTAssertTrue(scroll.exists, "missing \(scrollID)", file: file, line: line)
        for _ in 0..<4 where !elements.contains(where: { shown($0, in: scroll) }) {
            scroll.swipeUp()
        }
        let scrollOverlap = speak.frame.intersection(scroll.frame)
        XCTAssertFalse(
            scrollOverlap.width > 1 && scrollOverlap.height > 1,
            "Speak \(speak.frame) covers \(scrollID) \(scroll.frame)",
            file: file,
            line: line
        )
        let visible = elements.compactMap { element -> (XCUIElement, CGRect)? in
            guard shown(element, in: scroll) else { return nil }
            return (element, element.frame.intersection(scroll.frame))
        }
        XCTAssertFalse(
            visible.isEmpty,
            "no visible row or transcript text in \(scroll.frame)",
            file: file,
            line: line
        )
        guard let last = visible.max(by: { $0.1.maxY < $1.1.maxY }) else { return }
        let overlap = speak.frame.intersection(last.1)
        XCTAssertFalse(
            overlap.width > 1 && overlap.height > 1,
            "Speak \(speak.frame) covers the last visible text \"\(last.0.label)\" \(last.1)",
            file: file,
            line: line
        )
    }

    private func visibleBubbleCount(in history: XCUIElement, app: XCUIApplication) -> Int {
        let query = app.staticTexts.matching(identifier: "voice.line")
        let total = query.count
        let start = max(total - 12, 0)
        return (start..<total).filter { shown(query.element(boundBy: $0), in: history) }.count
    }

    private func bubbleFrames(_ app: XCUIApplication) -> String {
        let query = app.staticTexts.matching(identifier: "voice.line")
        let total = query.count
        let start = max(total - 4, 0)
        return (start..<total).map { "\($0) \(query.element(boundBy: $0).frame)" }.joined(separator: "; ")
    }

    private func reveal(_ row: XCUIElement, in list: XCUIElement) -> XCUIElement {
        if !row.waitForExistence(timeout: 4) || !row.isHittable {
            for _ in 0..<4 where !(row.exists && row.isHittable) {
                list.swipeUp()
            }
        }
        return row
    }

    private func shown(_ element: XCUIElement, in scroll: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let overlap = element.frame.intersection(scroll.frame)
        return overlap.width > 2 && overlap.height > 2
    }

    private func assertActionHintFits(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let action = app.buttons["voice.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 4), "Action Button control is missing", file: file, line: line)
        XCTAssertFalse(action.label.contains("…"), "Action Button hint is truncated", file: file, line: line)
        XCTAssertTrue(
            app.frame.insetBy(dx: -2, dy: -2).contains(action.frame),
            "Action Button hint is off the screen \(action.frame)",
            file: file,
            line: line
        )
    }

    private static func sessionRows(_ app: XCUIApplication) -> [XCUIElement] {
        sessionRowIDs.map { app.buttons["session.row.\($0)"] }
    }

    private static func transcriptLines(_ app: XCUIApplication) -> [XCUIElement] {
        let query = app.staticTexts.matching(identifier: "voice.line")
        let count = min(query.count, 12)
        return (0..<count).map { query.element(boundBy: $0) }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
