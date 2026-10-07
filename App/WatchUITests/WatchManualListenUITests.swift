import XCTest

/// Manual listen, Action Button, wrist-down, and the duration cap.
/// The microphone and the live relay stay off. Injected clips stand in for speech.
final class WatchManualListenUITests: XCTestCase {
    private static let idleSessionID = "0199aaaa-0000-7000-8000-000000000003"
    private static let pairingRejected = "This relay did not accept this pairing."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Action Button starts listening. A second press sends and leaves the chat open.
    func testActionButtonStartsAndSecondPressSendsWithoutEnding() throws {
        let app = launch(clip: "pause-task")
        openIdle(app)
        app.buttons["voice.action"].tap()
        let status = try status(app)
        XCTAssertEqual(try waitValue(status, "Listening"), .completed, "Action Button did not start listening")
        app.buttons["voice.action"].tap()
        XCTAssertTrue(app.scrollViews["voice.history"].waitForExistence(timeout: 8), "Action Button closed the chat")
        XCTAssertFalse(app.scrollViews["session.list"].isHittable, "Action Button left the conversation")
        XCTAssertTrue(app.staticTexts["You: list sessions"].waitForExistence(timeout: 8), "Action Button did not send")
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists, "Action Button cleared the restored chat")
        XCTAssertEqual(try waitValue(status, "Sent"), .completed)
        XCTAssertTrue(app.buttons["voice.speak"].waitForExistence(timeout: 4), "Speak did not return")
        shot(app, "manual-action")
    }

    /// Speak starts. I'm done sends. The session stays open.
    func testSpeakThenImDoneSendsWithoutEnding() throws {
        let app = launch(clip: "pause-task", phoneOff: true)
        openIdle(app)
        app.buttons["voice.speak"].tap()
        let status = try status(app)
        XCTAssertEqual(try waitValue(status, "Listening"), .completed)
        let done = app.buttons["voice.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        XCTAssertEqual(done.label, "I'm done")
        done.tap()
        XCTAssertTrue(app.staticTexts["You: list sessions"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Heard list sessions"].waitForExistence(timeout: 4), "the mock computer did not answer")
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists)
        XCTAssertTrue(app.buttons["voice.speak"].waitForExistence(timeout: 4))
        shot(app, "manual-done")
    }

    /// Wrist down keeps the chat, does not show the false pairing error, and wrist up is still listening.
    func testWristDownKeepsChatAndDoesNotShowPairingError() throws {
        let app = launch(clip: "pause-task", phoneOff: true, hooks: true)
        openIdle(app)
        app.buttons["voice.speak"].tap()
        let status = try status(app)
        XCTAssertEqual(try waitValue(status, "Listening"), .completed)
        let wrist = app.buttons["voice.wrist"]
        XCTAssertTrue(wrist.waitForExistence(timeout: 4), "wrist control missing")
        wrist.tap()
        XCTAssertFalse(app.staticTexts[Self.pairingRejected].exists, "wrist down showed the pairing reject banner")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists, "wrist down showed a failure banner")
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists, "wrist down cleared the chat")
        XCTAssertTrue(app.staticTexts["The computer is reachable only on the private overlay."].exists)
        XCTAssertTrue(app.scrollViews["voice.history"].exists)
        shot(app, "manual-wrist-down")
        app.buttons["voice.wrist"].tap()
        XCTAssertEqual(try waitValue(status, "Listening"), .completed, "wrist up did not resume listening")
        XCTAssertFalse(app.staticTexts[Self.pairingRejected].exists, "wrist up showed the pairing reject banner")
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists, "wrist up cleared the chat")
        shot(app, "manual-wrist-up")
    }

    /// The duration cap sends without I'm done and does not close the chat.
    func testMaxDurationSendsAndKeepsTheChat() throws {
        let app = launch(clip: "pause-task", phoneOff: true, maxListen: true)
        openIdle(app)
        app.buttons["voice.speak"].tap()
        XCTAssertTrue(
            app.staticTexts["You: list sessions"].waitForExistence(timeout: 8),
            "the duration cap did not send"
        )
        XCTAssertTrue(app.staticTexts["Heard list sessions"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists, "the duration cap closed the chat")
        XCTAssertFalse(app.scrollViews["session.list"].isHittable)
        XCTAssertTrue(app.buttons["voice.speak"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts[Self.pairingRejected].exists)
        shot(app, "manual-cap")
    }

    private func launch(
        clip: String? = nil,
        phoneOff: Bool = false,
        hooks: Bool = false,
        maxListen: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-WatchRemoteUITest"]
        if phoneOff {
            arguments.append("-WatchRemotePhoneOff")
        }
        if let clip {
            arguments.append(contentsOf: ["-WatchRemoteInjectClip", clip])
        }
        if hooks {
            arguments.append("-WatchRemoteShowHooks")
        }
        if maxListen {
            arguments.append("-WatchRemoteMaxListen")
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func openIdle(_ app: XCUIApplication) {
        let list = app.scrollViews["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "home session list did not appear")
        var row = app.buttons["session.row.\(Self.idleSessionID)"]
        if !row.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "idle session row missing")
        row.tap()
        XCTAssertTrue(app.scrollViews["voice.history"].waitForExistence(timeout: 8), "the chat did not open")
    }

    private func status(_ app: XCUIApplication) throws -> XCUIElement {
        let status = app.staticTexts["voice.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), "voice status did not appear")
        return status
    }

    private func waitValue(_ status: XCUIElement, _ text: String) throws -> XCTWaiter.Result {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text),
            object: status
        )
        return XCTWaiter.wait(for: [expectation], timeout: 8)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
