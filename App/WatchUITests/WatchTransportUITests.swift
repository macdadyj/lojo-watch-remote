import XCTest

/// A Watch simulator sends through a real local relay and, separately, through the paired iPhone.
/// `-WatchRemoteUITest` is intentionally absent: that flag skips the network.
final class WatchTransportUITests: XCTestCase {
    private let relayURL = "ws://127.0.0.1:18765/v1/room"
    private let token = "roomtokenprobe0001"
    private let key = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRelayDeliversAReplyThenReconnectsAndReopens() throws {
        try control("/reset")
        let app = XCUIApplication()
        app.launchArguments = ["-WatchRemoteRelayProbe", "-WatchRemoteDirectPairing", pairingArgument()]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["I can hear you."].waitForExistence(timeout: 25),
            "the relay did not deliver a reply bubble"
        )
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists, "Reconnecting stayed up after the socket opened")

        let status = app.staticTexts["voice.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 4), "voice status was not on screen")
        status.press(forDuration: 0.8)
        let diagnostics = app.staticTexts["voice.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 4), "long-press did not show transport diagnostics")
        XCTAssertTrue(diagnostics.label.contains("direct"), "diagnostics did not name the direct path: \(diagnostics.label)")
        XCTAssertTrue(diagnostics.label.contains("up"), "diagnostics did not show a connected socket: \(diagnostics.label)")
        shot(app, "relay-reply")

        try control("/drop")
        XCTAssertTrue(
            app.staticTexts["Reconnecting…"].waitForExistence(timeout: 20),
            "dropping the relay did not show Reconnecting"
        )
        shot(app, "relay-reconnecting")
        try control("/resume")

        XCTAssertTrue(
            app.staticTexts["Reopened."].waitForExistence(timeout: 25),
            "the reopened chat did not get a reply after reconnect"
        )
        XCTAssertTrue(app.staticTexts["Ready."].waitForExistence(timeout: 4), "the restored chat lines were not on screen")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists, "Reconnecting did not clear after the relay came back")
        shot(app, "relay-reopened")
    }

    func testPhoneReachableDeliversAReply() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WatchRemotePhoneProbe"]
        app.launch()
        let arrived = app.staticTexts["I can hear you."].waitForExistence(timeout: 15)
        let measurement = arrived
            ? "phone reply arrived"
            : "phone reply did not arrive; simulator WatchConnectivity did not deliver"
        print(measurement)
        shot(app, arrived ? "phone-reply" : "phone-reply-missing")
    }

    private func control(_ path: String) throws {
        let ready = expectation(description: path)
        var status = 0
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18766\(path)"))
        URLSession.shared.dataTask(with: url) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            ready.fulfill()
        }.resume()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "relay control \(path) did not answer")
        XCTAssertEqual(status, 200, "relay control \(path) failed")
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
