import XCTest

/// Phone chats stay open when a turn is idle, and a follow-up sends in the same thread.
final class PhoneChatUITests: XCTestCase {
    private let idleSessionID = "0199aaaa-0000-7000-8000-000000000003"
    private let longSessionID = "0199aaaa-0000-7000-8000-000000000005"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIdleChatReopensSendsAndSurvivesRelaunch() throws {
        let app = launch()
        openIdle(app)
        XCTAssertTrue(app.descendants(matching: .any)["chat.thread"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Note the overlay route"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.staticTexts["The computer is reachable only on the private overlay."].waitForExistence(timeout: 4),
            "history did not show the idle chat"
        )
        send(app, "add a note")
        XCTAssertTrue(app.staticTexts["Done. add a note"].waitForExistence(timeout: 8), "follow-up did not get a reply")
        shot(app, "phone-idle-reopened")

        app.terminate()
        let again = launch()
        openIdle(again)
        XCTAssertTrue(again.staticTexts["Done. add a note"].waitForExistence(timeout: 8), "relaunch dropped the chat")
        send(again, "and another")
        XCTAssertTrue(again.staticTexts["Done. and another"].waitForExistence(timeout: 8))
        shot(again, "phone-relaunch-follow-up")
    }

    func testNewChatShowsTheReply() throws {
        let app = launch()
        let newChat = app.buttons["chat.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8))
        newChat.tap()
        let prompt = composer(app, identifier: "chat.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 4))
        prompt.tap()
        prompt.typeText("Ship the list")
        app.buttons["chat.start"].tap()
        XCTAssertTrue(app.staticTexts["Done. Ship the list"].waitForExistence(timeout: 8))
        shot(app, "phone-new-chat")
    }

    func testBackgroundForegroundKeepsTheThreadResponsive() throws {
        let app = launch()
        openIdle(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["chat.thread"].waitForExistence(timeout: 8))
        send(app, "still here")
        XCTAssertTrue(app.staticTexts["Done. still here"].waitForExistence(timeout: 8))
        shot(app, "phone-foreground")
    }

    func testAutoApproveToggleAndVisibleControls() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["session.list"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["computer.picker"].exists)

        app.tabBars.buttons["Computer"].tap()
        XCTAssertTrue(app.buttons["Scan QR code"].waitForExistence(timeout: 6))

        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["settings.autoApprove"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), "auto-approve toggle missing")
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        shot(app, "phone-auto-approve")

        app.tabBars.buttons["Sessions"].tap()
        openIdle(app)
        let end = app.buttons["chat.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 6))
        end.tap()
        XCTAssertTrue(app.staticTexts["Ended."].waitForExistence(timeout: 4))
        XCTAssertTrue(composer(app, identifier: "chat.composer").exists, "ending the chat removed the composer")
        let perChat = app.switches["chat.autoApprove"]
        XCTAssertTrue(perChat.waitForExistence(timeout: 4))
        perChat.tap()
        shot(app, "phone-controls")
    }

    func testLongChatStaysAnchoredOnTheLatestMessage() throws {
        let app = launch()
        let list = app.descendants(matching: .any)["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 12))
        var row = app.descendants(matching: .any)["session.row.\(longSessionID)"]
        if !row.waitForExistence(timeout: 2) {
            app.swipeUp()
            row = app.descendants(matching: .any)["session.row.\(longSessionID)"]
        }
        XCTAssertTrue(row.waitForExistence(timeout: 6), "long chat row missing")
        row.tap()
        let history = app.descendants(matching: .any)["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        let latest = line(history, "Yes. The latest line is this one.")
        XCTAssertTrue(latest.waitForExistence(timeout: 8))
        let oldest = line(history, "oldest note in this chat")
        XCTAssertTrue(oldest.waitForExistence(timeout: 4), "the first message is missing from the chat")
        XCTAssertTrue(waitUntilVisible(latest, in: history), "opening a long chat hid the latest message")
        XCTAssertFalse(visible(oldest, in: history), "opening a long chat showed the first message")
        let mine = line(history, "Still with me?")
        XCTAssertTrue(mine.waitForExistence(timeout: 4), "the user line is missing")
        XCTAssertTrue(waitUntilVisible(mine, in: history), "the user line is off screen")
        XCTAssertLessThan(mine.frame.width, history.frame.width * 0.85, "user bubble is full width")
        XCTAssertGreaterThan(mine.frame.maxX, history.frame.midX, "user bubble is not on the right")
        XCTAssertLessThan(latest.frame.minX, history.frame.midX, "assistant reply does not start on the left")
        send(app, "ping the bottom")
        let reply = line(history, "Done. ping the bottom")
        XCTAssertTrue(reply.waitForExistence(timeout: 8), "the reply did not arrive")
        XCTAssertTrue(waitUntilVisible(reply, in: history), "the latest message is off screen")
        XCTAssertFalse(visible(oldest, in: history), "sending jumped back to the start of the chat")
        shot(app, "phone-long-anchored")
    }

    func testToolCallsCollapseToOneRow() throws {
        let app = launch()
        openIdle(app)
        XCTAssertTrue(app.staticTexts["Worked · 3 steps"].waitForExistence(timeout: 6), "tool calls were not grouped")
        XCTAssertFalse(app.staticTexts["Tool: Tool"].exists)
        XCTAssertFalse(app.staticTexts["Execute curl -fsS https://example.invalid/weather"].exists)
        let tools = app.buttons["chat.tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 4))
        tools.tap()
        let opened = NSPredicate { _, _ in
            let value = tools.value as? String ?? ""
            let showsCommand = value.contains("Ran a command") || self.line(app, "Ran a command").exists
            let showsSearch = value.contains("Searched the web") || app.staticTexts["Searched the web"].exists
            let showsTool = value.contains("Used a tool") || app.staticTexts["Used a tool"].exists
            return showsCommand && showsSearch && showsTool
        }
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: opened, object: nil)], timeout: 4),
            .completed,
            "expanding the tool row did not show the steps"
        )
        shot(app, "phone-tools-collapsed")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-WatchRemoteUITest"]
        app.launch()
        return app
    }

    private func openIdle(_ app: XCUIApplication) {
        let list = app.descendants(matching: .any)["session.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 12))
        var row = app.descendants(matching: .any)["session.row.\(idleSessionID)"]
        if !row.waitForExistence(timeout: 2) {
            app.swipeUp()
            row = app.descendants(matching: .any)["session.row.\(idleSessionID)"]
        }
        XCTAssertTrue(row.waitForExistence(timeout: 6), "idle chat row missing")
        row.tap()
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let field = composer(app, identifier: "chat.composer")
        XCTAssertTrue(field.waitForExistence(timeout: 6), "composer missing")
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
        }
        field.typeText(text)
        let send = app.buttons["chat.send"]
        let enabled = NSPredicate(format: "isEnabled == true AND isHittable == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: send)], timeout: 6), .completed)
        send.tap()
    }

    private func composer(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let field = app.textFields[identifier]
        if field.waitForExistence(timeout: 3) { return field }
        let view = app.textViews[identifier]
        if view.waitForExistence(timeout: 2) { return view }
        return field
    }

    private func line(_ parent: XCUIElement, _ label: String) -> XCUIElement {
        parent.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func visible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists, container.exists else { return false }
        let overlap = element.frame.intersection(container.frame)
        return overlap.width > 2 && overlap.height > 2
    }

    private func waitUntilVisible(
        _ element: XCUIElement,
        in container: XCUIElement,
        timeout: TimeInterval = 4
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            self.visible(element, in: container)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
