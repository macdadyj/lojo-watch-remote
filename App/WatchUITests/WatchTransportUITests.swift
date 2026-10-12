import XCTest

/// End to end on the Watch simulator, with only the microphone scripted.
///
/// Relay: Watch app → HTTP long-poll → real Node relay → real `outbound.py` → fake Grok Build
/// (`host/relay_probe.py`). Phone: Watch app → phone link → iPhone echo. `-WatchRemoteUITest` is
/// intentionally absent because that flag turns the network off.
final class WatchTransportUITests: XCTestCase {
    /// The reply budget a person would notice. The fake model answers in well under a second.
    private let replySeconds: TimeInterval = 20
    private let relayURL = "ws://127.0.0.1:18765/v1/room"
    private let token = "roomtokenprobe0001"
    private let key = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRelayRepliesContinuesApprovesAndReopens() throws {
        try control("/reset")
        let app = launchRelay(utterances: ["Can you hear me", "Again", "Read the notes file"])

        waitForChats(app)
        shot(app, "relay-home")

        let asked = Date()
        speak(app)
        XCTAssertTrue(bubble(app, "Can you hear me").waitForExistence(timeout: 8), "the spoken words did not become a bubble")
        XCTAssertTrue(bubble(app, "I can hear you.").waitForExistence(timeout: replySeconds), "no reply bubble from the relay")
        print("relay reply after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s")
        assertBubbles(app, ["Can you hear me", "I can hear you."])
        assertSides(app, mine: "Can you hear me", theirs: "I can hear you.")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists, "Reconnecting stayed up after the relay answered")

        let title = app.staticTexts["voice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "the new chat never got its title from the computer")
        title.press(forDuration: 0.8)
        let diagnostics = app.staticTexts["voice.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 4), "long-press did not show transport diagnostics")
        XCTAssertTrue(diagnostics.label.contains("direct"), "diagnostics did not name the relay path: \(diagnostics.label)")
        XCTAssertTrue(diagnostics.label.contains("up"), "diagnostics did not show the relay link up: \(diagnostics.label)")
        title.press(forDuration: 0.8)
        shot(app, "relay-reply")

        try control("/drop")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].waitForExistence(timeout: 20), "dropping the relay did not show Reconnecting")
        shot(app, "relay-reconnecting")
        try control("/resume")
        XCTAssertTrue(waitForAbsence(app.staticTexts["Reconnecting…"], timeout: 30), "Reconnecting did not clear after the relay came back")
        XCTAssertFalse(app.staticTexts["Computer offline"].exists, "the computer is connected but the Watch says offline")

        speak(app)
        XCTAssertTrue(bubble(app, "Heard again.").waitForExistence(timeout: replySeconds), "the follow-up got no reply after the relay came back")
        assertBubbles(app, ["Can you hear me", "I can hear you.", "Again", "Heard again."])

        speak(app)
        let allow = app.buttons["tool.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: replySeconds), "the tool request did not show Allow with auto-approve off")
        shot(app, "relay-approval")
        allow.tap()
        XCTAssertTrue(
            bubble(app, "I read notes.txt. It says hello.").waitForExistence(timeout: replySeconds),
            "the tool reply did not arrive after Allow"
        )
        XCTAssertTrue(waitForAbsence(app.buttons["tool.allow"], timeout: 8), "the approval card stayed after Allow")

        let state = try grokState()
        let prompts = state.prompts
        XCTAssertEqual(prompts.map(\.text), ["Can you hear me", "Again", "Read the notes file"])
        XCTAssertEqual(Set(prompts.map(\.session)).count, 1, "a follow-up opened a new chat instead of continuing: \(prompts)")
        XCTAssertEqual(state.decisions, ["allow-once"])

        app.buttons["Chat actions"].tap()
        let chatSwitch = app.switches["chat.autoApprove"]
        XCTAssertTrue(chatSwitch.waitForExistence(timeout: 8), "the chat has no auto-approve switch")
        XCTAssertEqual(chatSwitch.value as? String, "0", "the chat switch did not follow the default (off)")
        shot(app, "relay-chat-actions")

        // A fresh launch: the chat list comes back and an older chat continues in its own session.
        app.terminate()
        let again = launchRelay(utterances: ["Reopen the chat"])
        let seed = again.buttons["session.row.session-seed"]
        XCTAssertTrue(seed.waitForExistence(timeout: 30), "chats were not listed after a relaunch")
        seed.tap()
        XCTAssertTrue(bubble(again, "Ready.").waitForExistence(timeout: 15), "the reopened chat did not show its messages")
        speak(again)
        XCTAssertTrue(bubble(again, "Reopened.").waitForExistence(timeout: replySeconds), "the reopened chat got no reply")
        assertBubbles(again, ["earlier", "Ready.", "Reopen the chat", "Reopened."])
        XCTAssertEqual(try grokState().prompts.last?.session, "session-seed", "the reopened chat did not continue its own session")
        shot(again, "relay-reopened")
    }

    func testAutoApproveLetsTheToolRunWithoutATap() throws {
        try control("/reset")
        let app = launchRelay(utterances: ["Read the notes file"], autoApprove: true)
        waitForChats(app)
        speak(app)
        XCTAssertTrue(
            bubble(app, "I read notes.txt. It says hello.").waitForExistence(timeout: replySeconds),
            "the tool did not run with auto-approve on"
        )
        XCTAssertFalse(app.buttons["tool.allow"].exists, "auto-approve still asked")
        XCTAssertEqual(try grokState().decisions, ["allow-once"])
        shot(app, "relay-auto-approved")
    }

    /// The Watch's phone path against an in-process iPhone echo. This gates: it does not depend on
    /// the simulator's WatchConnectivity, which CI runners have not delivered.
    func testPhonePathRepliesAndContinues() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-WatchRemoteTransportTest", "phone",
            "-WatchRemotePhoneLoopback",
            "-WatchRemoteInjectUtterance", "Can you hear me|Again",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["session.row.echo-1"].waitForExistence(timeout: 20), "the phone link did not deliver chats")
        speak(app)
        XCTAssertTrue(bubble(app, "I can hear you.").waitForExistence(timeout: replySeconds), "no reply bubble through the phone path")
        assertBubbles(app, ["Can you hear me", "I can hear you."])
        speak(app)
        let replies = app.staticTexts.matching(identifier: "voice.line").matching(NSPredicate(format: "label == %@", "I can hear you."))
        let second = NSPredicate { _, _ in replies.count >= 2 }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: second, object: nil)], timeout: replySeconds),
            .completed,
            "the follow-up did not continue the same chat"
        )
        assertBubbles(app, ["Can you hear me", "I can hear you.", "Again", "I can hear you."])
        shot(app, "phone-reply")
    }

    /// The same round trip over real simulator WatchConnectivity to the iPhone echo probe.
    /// It asserts whenever the simulator delivers, and is skipped with the reason when it does not.
    func testPhoneOverWatchConnectivityReplies() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WatchRemoteTransportTest", "phone", "-WatchRemoteInjectUtterance", "Can you hear me"]
        app.launch()
        guard app.buttons["session.row.echo-1"].waitForExistence(timeout: 30) else {
            shot(app, "phone-wc-missing")
            throw XCTSkip("simulator WatchConnectivity never delivered the iPhone snapshot")
        }
        speak(app)
        XCTAssertTrue(bubble(app, "Can you hear me").waitForExistence(timeout: 8), "the spoken words did not become a bubble")
        guard bubble(app, "I can hear you.").waitForExistence(timeout: replySeconds) else {
            shot(app, "phone-wc-no-answer")
            throw XCTSkip("simulator WatchConnectivity carried the chats but not the iPhone's answer; screen: \(screenText(app))")
        }
        shot(app, "phone-wc-reply")
    }

    // MARK: - Helpers

    private func launchRelay(utterances: [String], autoApprove: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-WatchRemoteTransportTest", "relay",
            "-WatchRemoteDirectPairing", pairingArgument(),
            "-WatchRemoteInjectUtterance", utterances.joined(separator: "|"),
            "-WatchRemoteAutoApprove", autoApprove ? "1" : "0",
        ]
        app.launch()
        return app
    }

    private func waitForChats(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard app.buttons["session.row.session-seed"].waitForExistence(timeout: 30) else {
            shot(app, "relay-no-chats")
            XCTFail("the relay did not deliver the computer's chats; screen: \(screenText(app))", file: file, line: line)
            return
        }
    }

    private func screenText(_ app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        return texts.joined(separator: " | ")
    }

    private func speak(_ app: XCUIApplication) {
        let speak = app.buttons["voice.speak"].firstMatch
        XCTAssertTrue(speak.waitForExistence(timeout: 15), "Speak was not on screen")
        speak.tap()
    }

    private func bubble(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(identifier: "voice.line").matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// Exactly these bubbles, in order. Status, hints and link messages must never be bubbles.
    private func assertBubbles(_ app: XCUIApplication, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        let query = app.staticTexts.matching(identifier: "voice.line")
        let settled = NSPredicate { _, _ in
            (0..<query.count).map { query.element(boundBy: $0).label } == expected
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 8)
        let shown = (0..<query.count).map { query.element(boundBy: $0).label }
        XCTAssertEqual(result, .completed, "bubbles were \(shown), wanted \(expected)", file: file, line: line)
    }

    private func assertSides(_ app: XCUIApplication, mine: String, theirs: String) {
        let history = app.scrollViews["voice.history"]
        XCTAssertTrue(history.exists, "the chat is not on screen")
        XCTAssertGreaterThan(bubble(app, mine).frame.maxX, history.frame.midX, "the user's bubble is not on the right")
        XCTAssertLessThan(bubble(app, theirs).frame.minX, history.frame.midX, "the reply bubble is not on the left")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private struct GrokState {
        var prompts: [(session: String, text: String)]
        var decisions: [String]
    }

    private func grokState() throws -> GrokState {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: control("/state")) as? [String: Any])
        let prompts = (object["prompts"] as? [[String: Any]] ?? []).map { row in
            (session: row["sessionId"] as? String ?? "", text: row["text"] as? String ?? "")
        }
        let decisions = (object["decisions"] as? [[String: Any]] ?? []).compactMap { $0["outcome"] as? String }
        return GrokState(prompts: prompts, decisions: decisions)
    }

    @discardableResult
    private func control(_ path: String) throws -> Data {
        let ready = expectation(description: path)
        var status = 0
        var body = Data()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18766\(path)"))
        URLSession.shared.dataTask(with: url) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
            ready.fulfill()
        }.resume()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "relay control \(path) did not answer")
        XCTAssertEqual(status, 200, "relay control \(path) failed")
        return body
    }

    private func pairingArgument() -> String {
        let pairing: [String: Any] = [
            "clear": false,
            "computerID": "probe",
            "key": key,
            "label": "example-host",
            "relayURL": relayURL,
            "token": token,
        ]
        let data = try? JSONSerialization.data(withJSONObject: pairing)
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
