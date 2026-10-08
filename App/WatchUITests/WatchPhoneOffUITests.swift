import XCTest

/// Scripted Watch cases with the iPhone simulated off (`-WatchRemotePhoneOff`).
/// The microphone, SSH, and the real relay stay off. A paired computer is the default.
/// `-WatchRemoteHostMissing` is the unpaired last resort. Clips come from `Fixtures/speech`.
final class WatchPhoneOffUITests: XCTestCase {
    private static let idleSessionID = "0199aaaa-0000-7000-8000-000000000003"
    private static let approvalSessionID = "0199aaaa-0000-7000-8000-000000000002"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// a. Home stays on screen, the path is direct, and the Action Button control is the default.
    func testAPhoneOffHomeShowsDirectAndPauseToSend() throws {
        let app = launch()
        let list = app.scrollViews["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "home session list did not appear")
        XCTAssertTrue(app.staticTexts["Path direct"].waitForExistence(timeout: 4), "phone-off home did not show the direct path")
        let action = app.buttons["voice.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 4), "Action Button control is missing")
        XCTAssertEqual(action.label, "Action Button")
        XCTAssertTrue(app.buttons["voice.speak"].waitForExistence(timeout: 4), "Speak is missing")
        XCTAssertFalse(app.staticTexts["Hands-free needs the iPhone app open. Tap Done after you speak."].exists)
        shot(app, "phone-off-home")
    }

    /// b. A past chat opens with its messages while the iPhone is off.
    func testBPhoneOffRestoresPastChat() throws {
        let app = launch()
        openIdle(app)
        XCTAssertTrue(app.staticTexts["Note the overlay route"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["The computer is reachable only on the private overlay."].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["That chat is no longer on this computer."].exists)
        shot(app, "phone-off-restored")
    }

    /// c. Speak listens. It does not open dictation when a computer is paired.
    func testCPhoneOffSpeakListensWithoutDictation() throws {
        let app = launch(clip: "pause-task")
        openIdle(app)
        app.buttons["voice.speak"].tap()
        let status = try status(app)
        XCTAssertEqual(try waitValue(status, "Listening"), .completed, "Speak did not listen with the iPhone off")
        XCTAssertFalse(app.staticTexts["Hands-free needs the iPhone app open. Tap Done after you speak."].exists)
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists, "restored messages disappeared")
        shot(app, "phone-off-listening")
    }

    /// d. I'm done sends the injected utterance and the mock computer answers. The chat stays open.
    func testDPhoneOffImDoneSendsAndMockHostReplies() throws {
        let app = launch(clip: "pause-task")
        openIdle(app)
        app.buttons["voice.speak"].tap()
        let status = try status(app)
        XCTAssertEqual(try waitValue(status, "Listening"), .completed)
        app.buttons["voice.done"].tap()
        XCTAssertTrue(app.scrollViews["voice.history"].waitForExistence(timeout: 8), "I'm done closed the chat")
        let sentLine = app.staticTexts["list sessions"]
        let reply = app.staticTexts["Heard list sessions"]
        XCTAssertTrue(sentLine.waitForExistence(timeout: 4), "the utterance was not sent")
        XCTAssertTrue(reply.waitForExistence(timeout: 4), "the mock computer did not answer")
        XCTAssertTrue(reply.isHittable, "the reply is off the bottom of the chat")
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists)
        XCTAssertEqual(try waitValue(status, "Sent"), .completed)
        XCTAssertTrue(app.buttons["voice.speak"].waitForExistence(timeout: 4), "Speak did not return")
        shot(app, "phone-off-done")
    }

    /// e. I'm done sends a clip that has no trailing silence. The turn does not wait for a pause.
    func testEPhoneOffNoPauseStillSends() throws {
        let app = launch(clip: "no-pause")
        XCTAssertFalse(app.staticTexts["Test clip missing."].waitForExistence(timeout: 2))
        openIdle(app)
        app.buttons["voice.speak"].tap()
        app.buttons["voice.done"].tap()
        XCTAssertTrue(
            app.staticTexts["keep going without a pause"].waitForExistence(timeout: 8),
            "I'm done dropped audio that had not paused"
        )
        XCTAssertTrue(app.staticTexts["Heard keep going without a pause"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Note the overlay route"].exists, "the chat closed")
        shot(app, "phone-off-no-pause")
    }

    /// f. yes and no clips get the mock approval replies, and the approval chat stays open.
    func testFPhoneOffYesAndNo() throws {
        let yes = launch(clip: "yes")
        openApproval(yes)
        yes.buttons["voice.speak"].tap()
        yes.buttons["voice.done"].tap()
        XCTAssertTrue(yes.staticTexts["yes"].waitForExistence(timeout: 8))
        XCTAssertTrue(yes.staticTexts["Allowed."].waitForExistence(timeout: 4), "yes did not get the mock allow reply")
        XCTAssertTrue(yes.staticTexts["Update the parser"].exists, "the approval chat closed")
        shot(yes, "phone-off-yes")
        yes.terminate()

        let no = launch(clip: "no")
        openApproval(no)
        no.buttons["voice.speak"].tap()
        no.buttons["voice.done"].tap()
        XCTAssertTrue(no.staticTexts["no"].waitForExistence(timeout: 8))
        XCTAssertTrue(no.staticTexts["Denied."].waitForExistence(timeout: 4), "no did not get the mock deny reply")
        XCTAssertTrue(no.staticTexts["Update the parser"].exists)
        shot(no, "phone-off-no")
    }

    /// g. No pairing shows the dictation fallback. An unknown session says it is gone.
    func testGPhoneOffWithoutHostOffersDictationAndMissingChat() throws {
        let unpaired = launch(hostMissing: true)
        XCTAssertTrue(unpaired.staticTexts["Path Pair on iPhone first"].waitForExistence(timeout: 40))
        unpaired.buttons["voice.speak"].tap()
        let status = try status(unpaired)
        XCTAssertEqual(try waitValue(status, "Dictation"), .completed, "an unpaired Watch listened instead of offering dictation")
        XCTAssertTrue(
            unpaired.staticTexts["Hands-free needs the iPhone app open. Tap Done after you speak."].waitForExistence(timeout: 4)
        )
        if !unpaired.buttons["Dictate"].waitForExistence(timeout: 2) {
            unpaired.swipeUp()
        }
        XCTAssertTrue(unpaired.buttons["Dictate"].waitForExistence(timeout: 4), "Dictate was not offered")
        shot(unpaired, "phone-off-unpaired")
        unpaired.terminate()

        let missing = launch(missingSession: true)
        XCTAssertTrue(
            missing.staticTexts["That chat is no longer on this computer."].waitForExistence(timeout: 40),
            "a missing chat was silent"
        )
        shot(missing, "phone-off-missing")
    }

    private func launch(clip: String? = nil, hostMissing: Bool = false, missingSession: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-WatchRemoteUITest", "-WatchRemotePhoneOff"]
        if let clip {
            arguments.append(contentsOf: ["-WatchRemoteInjectClip", clip])
        }
        if hostMissing {
            arguments.append("-WatchRemoteHostMissing")
        }
        if missingSession {
            arguments.append("-WatchRemoteMissingSession")
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func openIdle(_ app: XCUIApplication) {
        openRow(app, Self.idleSessionID)
    }

    private func openApproval(_ app: XCUIApplication) {
        openRow(app, Self.approvalSessionID)
    }

    private func openRow(_ app: XCUIApplication, _ identifier: String) {
        let list = app.scrollViews["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "home session list did not appear")
        let row = app.buttons["session.row.\(identifier)"]
        if !row.waitForExistence(timeout: 4) || !row.isHittable {
            for _ in 0..<4 where !(row.exists && row.isHittable) {
                list.swipeUp()
            }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "session row \(identifier) missing")
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
