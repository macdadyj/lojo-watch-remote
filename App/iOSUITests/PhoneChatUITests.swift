import XCTest

/// Phone chats stay open when a turn is idle, and a follow-up sends in the same thread.
final class PhoneChatUITests: XCTestCase {
    private let idleSessionID = "0199aaaa-0000-7000-8000-000000000003"

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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
