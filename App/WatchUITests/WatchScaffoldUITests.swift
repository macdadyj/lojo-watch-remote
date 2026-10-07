import XCTest

/// Taps the home list, a past session, Speak, and I'm done on the watchOS simulator.
/// The app is launched with `-WatchRemoteUITest`, so the microphone and the real host stay off.
final class WatchScaffoldUITests: XCTestCase {
    /// `DemoCatalog.idleID`. Kept here so this bundle does not link the app target's package twice.
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
        shot(app, "scaffold-home")

        var row = app.buttons["session.row.\(Self.idleSessionID)"]
        if !row.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
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
        XCTAssertFalse(
            app.staticTexts["That chat is no longer on this computer."].exists,
            "a live demo session was reported missing"
        )
        let speak = app.buttons["voice.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 8), "restored chat did not stay open")
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
            app.staticTexts["You: list sessions"].waitForExistence(timeout: 4),
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
        shot(app, "scaffold-done")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
