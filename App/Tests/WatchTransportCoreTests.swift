import XCTest
import WatchRemoteCore

final class WatchTransportCoreTests: XCTestCase {
    func testPollURLFollowsThePairedRelay() {
        XCTAssertEqual(RelayPoll.pollURL(fromRelayURL: "wss://relay.example.com/v1/room")?.absoluteString, "https://relay.example.com/v1/watch")
        XCTAssertEqual(RelayPoll.pollURL(fromRelayURL: "wss://relay.example.com/base/v1/room/")?.absoluteString, "https://relay.example.com/base/v1/watch")
        XCTAssertEqual(RelayPoll.pollURL(fromRelayURL: "ws://127.0.0.1:18765/v1/room")?.absoluteString, "http://127.0.0.1:18765/v1/watch")
        XCTAssertEqual(RelayPoll.pollURL(fromRelayURL: "wss://relay.example.com:8443")?.absoluteString, "https://relay.example.com:8443/v1/watch")
        XCTAssertNil(RelayPoll.pollURL(fromRelayURL: "ws://relay.example.com/v1/room"))
        XCTAssertNil(RelayPoll.pollURL(fromRelayURL: "https://relay.example.com/v1/room"))
    }

    func testPollRequestAndResponseCoding() throws {
        let request = RelayPoll.Request(send: ["AQI="], after: 4, epoch: "e1", wait: 25_000)
        let data = try XCTUnwrap(RelayPoll.encode(request))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(text, #"{"after":4,"epoch":"e1","send":["AQI="],"wait":25000}"#)
        let reply = Data(#"{"ok":true,"epoch":"e1","host":false,"frames":[{"seq":5,"data":"AA=="}]}"#.utf8)
        let decoded = try XCTUnwrap(RelayPoll.decode(reply))
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.host, false)
        XCTAssertEqual(decoded.frames, [RelayPoll.Frame(seq: 5, data: "AA==")])
        XCTAssertEqual(RelayPoll.decode(Data(#"{"ok":false,"error":"rate"}"#.utf8))?.error, "rate")
    }

    func testPollOutcomesAndBackoff() {
        XCTAssertEqual(RelayPoll.outcome(status: 200), .ok)
        XCTAssertEqual(RelayPoll.outcome(status: 401), .pairingRejected)
        XCTAssertEqual(RelayPoll.outcome(status: 404), .relayOutdated)
        XCTAssertEqual(RelayPoll.outcome(status: 429), .slowDown)
        XCTAssertEqual(RelayPoll.outcome(status: 502), .retry)
        XCTAssertEqual(RelayPoll.backoff(failures: 1, outcome: .retry), 1)
        XCTAssertEqual(RelayPoll.backoff(failures: 9, outcome: .retry), 8)
        XCTAssertEqual(RelayPoll.backoff(failures: 1, outcome: .relayOutdated), 30)
    }

    func testCursorTakesEachFrameOnceAndResetsOnANewEpoch() {
        var cursor = RelayPollCursor()
        let first = RelayPoll.Response(ok: true, epoch: "a", host: true, frames: [.init(seq: 2, data: "y"), .init(seq: 1, data: "x")])
        XCTAssertEqual(cursor.take(first).map(\.data), ["x", "y"])
        XCTAssertEqual(cursor.after, 2)
        XCTAssertEqual(cursor.take(first), [])
        let more = RelayPoll.Response(ok: true, epoch: "a", host: true, frames: [.init(seq: 2, data: "y"), .init(seq: 3, data: "z")])
        XCTAssertEqual(cursor.take(more).map(\.data), ["z"])
        let restarted = RelayPoll.Response(ok: true, epoch: "b", host: true, frames: [.init(seq: 1, data: "fresh")])
        XCTAssertEqual(cursor.take(restarted).map(\.data), ["fresh"])
        XCTAssertEqual(cursor.epoch, "b")
        XCTAssertEqual(cursor.after, 1)
    }

    func testCountersFollowTheClockAndNeverRepeat() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RelayCounter.next(after: 0, now: now), 1_700_000_000_000)
        XCTAssertEqual(RelayCounter.next(after: 1_700_000_000_500, now: now), 1_700_000_000_501)
    }

    func testDirectMessageCarriesAutoApproveOnlyWhenSet() throws {
        var message = DirectMessage(op: .start, id: "w1", prompt: "hi")
        let plain = try XCTUnwrap(DirectMessage.encode(message))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("autoApprove"))
        message.autoApprove = true
        let sealed = try XCTUnwrap(DirectMessage.encode(message))
        XCTAssertTrue(String(decoding: sealed, as: UTF8.self).contains(#""autoApprove":true"#))
        XCTAssertEqual(DirectMessage.decode(sealed)?.autoApprove, true)
    }

    func testRelayGoesFirstWhenPaired() {
        XCTAssertEqual(WatchRouting.path(hasRelayPairing: true, relayHostOnline: nil, phoneReachable: true, phoneActivated: true), .relay)
        XCTAssertEqual(WatchRouting.path(hasRelayPairing: true, relayHostOnline: true, phoneReachable: true, phoneActivated: true), .relay)
        XCTAssertEqual(WatchRouting.path(hasRelayPairing: true, relayHostOnline: false, phoneReachable: true, phoneActivated: true), .phone)
        XCTAssertEqual(WatchRouting.path(hasRelayPairing: true, relayHostOnline: false, phoneReachable: false, phoneActivated: true), .relay)
        XCTAssertEqual(WatchRouting.path(hasRelayPairing: false, relayHostOnline: nil, phoneReachable: false, phoneActivated: true), .phone)
        XCTAssertEqual(WatchRouting.path(hasRelayPairing: false, relayHostOnline: nil, phoneReachable: false, phoneActivated: false), .unavailable)
    }

    func testMergedSessionsPreferTheRelayAndKeepPhoneOnlyChats() {
        let relay = [
            GrokSession(id: "a", title: "A", summary: "", status: .idle, transcript: ["You: hi", "Grok: hello"]),
            GrokSession(id: "b", title: "B", summary: "", status: .running, transcript: ["You: x"]),
        ]
        let phone = [
            GrokSession(id: "b", title: "B", summary: "", status: .idle, transcript: ["You: x", "Grok: y"]),
            GrokSession(id: "c", title: "C", summary: "", status: .idle),
            GrokSession(id: "a", title: "A old", summary: "", status: .idle, transcript: ["You: hi"]),
        ]
        let merged = WatchRouting.mergeSessions(relay: relay, phone: phone)
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(merged[0].title, "A")
        XCTAssertEqual(merged[1].transcript, ["You: x", "Grok: y"])
        XCTAssertEqual(merged[1].status, .running)
    }

    func testANewChatIsFoundByItsPrompt() {
        let sessions = [
            GrokSession(id: "old", title: "Old", summary: "", status: .idle, transcript: ["You: Can you hear me"]),
            GrokSession(id: "local-1", title: "Something", summary: "", status: .running, transcript: ["You: Can you hear me?"]),
        ]
        XCTAssertEqual(WatchRouting.newChat(for: "can you hear me", known: ["old"], in: sessions)?.id, "local-1")
        let titled = [GrokSession(id: "n", title: "Read the build", summary: "", status: .running)]
        XCTAssertEqual(WatchRouting.newChat(for: "Read the build logs", known: [], in: titled)?.id, "n")
        XCTAssertNil(WatchRouting.newChat(for: "x", known: ["old", "local-1"], in: sessions))
    }

    func testAReplyCountsOnlyAfterTheLatestPrompt() {
        let lines = ["You: earlier", "Grok: Ready.", "You: Reopen the chat"]
        XCTAssertFalse(WatchRouting.hasReply(after: "Reopen the chat", in: lines))
        XCTAssertTrue(WatchRouting.hasReply(after: "Reopen the chat", in: lines + ["Grok: Reopened."]))
        XCTAssertTrue(WatchRouting.hasReply(after: "earlier", in: lines))
        XCTAssertTrue(WatchRouting.mentions("reopen the chat.", in: lines))
        XCTAssertFalse(WatchRouting.mentions("Ready", in: lines))
    }

    func testAPollReplyThatSaysMoreIsWaitingStillDecodes() throws {
        let reply = Data(#"{"ok":true,"epoch":"e1","host":true,"frames":[{"seq":1,"data":"AA=="}],"more":true}"#.utf8)
        XCTAssertEqual(try XCTUnwrap(RelayPoll.decode(reply)).frames?.map(\.seq), [1])
    }

    func testALostPollAfterWristUpDoesNotSendTurnsToTheIPhone() {
        func path(failures: Int, up: Bool = false) -> WatchTurnPath {
            WatchRouting.path(
                hasRelayPairing: true,
                relayHostOnline: WatchRouting.relayHostOnline(relayUp: up, relayFailed: false, failures: failures, lastHostOnline: true),
                phoneReachable: true,
                phoneActivated: true
            )
        }
        XCTAssertEqual(path(failures: 0, up: true), .relay)
        XCTAssertEqual(path(failures: 1), .relay)
        XCTAssertEqual(path(failures: RelayPoll.unreachableAfterFailures - 1), .relay)
        XCTAssertEqual(path(failures: RelayPoll.unreachableAfterFailures), .phone, "a relay that stays unreachable hands turns to the iPhone")
        XCTAssertNil(WatchRouting.relayHostOnline(relayUp: false, relayFailed: false, failures: 0, lastHostOnline: nil))
        XCTAssertEqual(WatchRouting.relayHostOnline(relayUp: true, relayFailed: false, failures: 0, lastHostOnline: false), false)
        XCTAssertEqual(WatchRouting.relayHostOnline(relayUp: false, relayFailed: true, failures: 0, lastHostOnline: true), false)
    }

    func testComingBackReloadsTheOpenChatAndRunningOnes() {
        let sessions = [
            GrokSession(id: "done", title: "", summary: "", status: .idle),
            GrokSession(id: "busy", title: "", summary: "", status: .running),
            GrokSession(id: "asks", title: "", summary: "", status: .needsApproval),
            GrokSession(id: "local-1", title: "", summary: "", status: .running),
            GrokSession(id: "more", title: "", summary: "", status: .running),
        ]
        XCTAssertEqual(ForegroundCatchUp.chatsToReload(open: "done", sessions: sessions), ["done", "busy", "asks"])
        XCTAssertEqual(ForegroundCatchUp.chatsToReload(open: "busy", sessions: sessions), ["busy", "asks", "more"])
        XCTAssertEqual(ForegroundCatchUp.chatsToReload(open: nil, sessions: [sessions[0]]), [])
    }

    func testDictationAddsToWhatWasTyped() {
        XCTAssertEqual(DictationText.merge(typed: "", spoken: "summarize the changes"), "summarize the changes")
        XCTAssertEqual(DictationText.merge(typed: "Please ", spoken: "summarize the changes"), "Please summarize the changes")
        XCTAssertEqual(DictationText.merge(typed: "Please", spoken: "  "), "Please")
    }

    func testDemoTakesItsTimeOnlyWhenAsked() {
        XCTAssertEqual(DemoTiming.replyDelay(for: "Take your  time on this"), DemoTiming.slowSeconds)
        XCTAssertEqual(DemoTiming.replyDelay(for: "add a note"), DemoTiming.quickSeconds)
    }

    func testSettingsShowsTheBuild() {
        XCTAssertEqual(AppBuild.label(info: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "219"]), "Version 1.0 (build 219)")
        XCTAssertEqual(AppBuild.label(info: nil), "Version ? (build ?)")
    }

    func testAutoApproveIsOnUntilTurnedOff() {
        XCTAssertTrue(WatchApprovalSetting().value)
        XCTAssertTrue(WatchApprovalSetting().allows(chat: "any"))
    }

    func testApprovalSettingTakesTheLatestChangeFromEitherDevice() {
        var setting = WatchApprovalSetting(value: false)
        XCTAssertTrue(setting.notePhone(true))
        XCTAssertTrue(setting.allows(chat: nil))
        XCTAssertFalse(setting.notePhone(true))

        XCTAssertTrue(setting.chooseOnWatch(false))
        XCTAssertTrue(setting.awaitingPhone)
        XCTAssertFalse(setting.notePhone(true), "a stale iPhone snapshot flipped the Watch choice back")
        XCTAssertFalse(setting.allows(chat: "a"))
        XCTAssertFalse(setting.notePhone(false))
        XCTAssertFalse(setting.awaitingPhone)

        XCTAssertTrue(setting.notePhone(true), "a later iPhone change was ignored")
        XCTAssertTrue(setting.value)
    }

    func testApprovalSettingChatOverrides() {
        var setting = WatchApprovalSetting(value: false)
        setting.setChat("a", to: true)
        XCTAssertTrue(setting.allows(chat: "a"))
        XCTAssertFalse(setting.allows(chat: "b"))
        XCTAssertFalse(setting.allows(chat: nil))
        setting.setChat("a", to: nil)
        XCTAssertFalse(setting.allows(chat: "a"))
        let data = try? JSONEncoder().encode(setting)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(WatchApprovalSetting.self, from: $0) }, setting)
    }

    func testPhoneEchoAnswersNewAndContinuedChats() {
        var echo = PhoneEcho()
        XCTAssertNil(echo.accept(PhoneCommand(kind: .refresh)))
        let fresh = echo.accept(PhoneCommand(kind: .start, prompt: "Can you hear me"))
        XCTAssertEqual(fresh, "echo-new-1")
        XCTAssertFalse(WatchRouting.hasReply(after: "Can you hear me", in: echo.sessions[0].transcript ?? []))
        echo.answer("echo-new-1")
        XCTAssertTrue(WatchRouting.hasReply(after: "Can you hear me", in: echo.sessions[0].transcript ?? []))
        XCTAssertEqual(WatchRouting.newChat(for: "Can you hear me", known: [PhoneEcho.seedID], in: echo.sessions)?.id, "echo-new-1")
        XCTAssertEqual(echo.accept(PhoneCommand(kind: .start, prompt: "Again", sessionID: "echo-new-1")), "echo-new-1")
        XCTAssertEqual(echo.sessions.count, 2)
    }

    func testConnectionNoticeIsHonest() {
        XCTAssertNil(WatchRouting.notice(hasRelayPairing: false, relayUp: false, relayTrouble: true, relayHostOnline: nil, phoneReachable: false))
        XCTAssertEqual(
            WatchRouting.notice(hasRelayPairing: true, relayUp: false, relayTrouble: true, relayHostOnline: nil, phoneReachable: false),
            RelayUserNotice.reconnectingText
        )
        XCTAssertNil(WatchRouting.notice(hasRelayPairing: true, relayUp: false, relayTrouble: false, relayHostOnline: nil, phoneReachable: false))
        XCTAssertEqual(
            WatchRouting.notice(hasRelayPairing: true, relayUp: true, relayTrouble: false, relayHostOnline: false, phoneReachable: false),
            RelayUserNotice.computerOfflineText
        )
        XCTAssertNil(WatchRouting.notice(hasRelayPairing: true, relayUp: true, relayTrouble: false, relayHostOnline: false, phoneReachable: true))
        XCTAssertNil(WatchRouting.notice(hasRelayPairing: true, relayUp: true, relayTrouble: false, relayHostOnline: true, phoneReachable: false))
        XCTAssertEqual(
            WatchRouting.notice(hasRelayPairing: true, relayUp: true, relayTrouble: false, relayHostOnline: false, phoneReachable: false, noNetwork: true),
            RelayUserNotice.noNetworkText,
            "no radio is not the computer being offline"
        )
        XCTAssertEqual(
            WatchRouting.notice(hasRelayPairing: true, relayUp: false, relayTrouble: true, relayHostOnline: nil, phoneReachable: false, noNetwork: true),
            RelayUserNotice.noNetworkText
        )
        XCTAssertNil(WatchRouting.notice(hasRelayPairing: true, relayUp: false, relayTrouble: true, relayHostOnline: nil, phoneReachable: true, noNetwork: true))
        XCTAssertNotEqual(RelayUserNotice.noNetworkText, RelayUserNotice.computerOfflineText)
        XCTAssertNotEqual(RelayUserNotice.noNetworkText, RelayUserNotice.reconnectingText)
        XCTAssertTrue(RelayUserNotice.isConnectionNotice(RelayUserNotice.noNetworkText))
        XCTAssertFalse(RelayUserNotice.isConnectionNotice("The computer could not do that."))
    }

    func testNoNetworkSendsTurnsThroughThePhoneWhenItIsReachable() {
        XCTAssertEqual(
            WatchRouting.path(hasRelayPairing: true, relayHostOnline: true, phoneReachable: true, phoneActivated: true, watchHasNetwork: false),
            .phone
        )
        XCTAssertEqual(
            WatchRouting.path(hasRelayPairing: true, relayHostOnline: true, phoneReachable: false, phoneActivated: false, watchHasNetwork: false),
            .relay,
            "with the phone away the Watch keeps polling until its own radio is back"
        )
        XCTAssertEqual(
            WatchRouting.path(hasRelayPairing: true, relayHostOnline: false, phoneReachable: true, phoneActivated: true, phoneCanSSH: false),
            .relay,
            "a phone with no key yet does not take the turn off the relay"
        )
    }

    func testATimeoutWhileWaitingForRadioIsNoNetwork() {
        XCTAssertEqual(RelayPoll.fault(.notConnectedToInternet, waitedForConnectivity: false), .noNetwork)
        XCTAssertEqual(RelayPoll.fault(.dataNotAllowed, waitedForConnectivity: false), .noNetwork)
        XCTAssertEqual(RelayPoll.fault(.timedOut, waitedForConnectivity: true), .noNetwork)
        XCTAssertEqual(RelayPoll.fault(.timedOut, waitedForConnectivity: false), .relayUnreachable)
        XCTAssertEqual(RelayPoll.fault(.networkConnectionLost, waitedForConnectivity: true), .relayUnreachable)
        XCTAssertEqual(RelayPoll.detail(.timedOut, waitedForConnectivity: true), "The Watch has no network.")
        XCTAssertEqual(RelayPoll.detail(.timedOut, waitedForConnectivity: false), "The relay did not answer in time.")
        XCTAssertEqual(RelayPoll.detail(.networkConnectionLost, waitedForConnectivity: false), "The relay connection dropped.")
        XCTAssertLessThan(RelayPoll.watchWaitMilliseconds, RelayPoll.maxWaitMilliseconds)
        XCTAssertEqual(RelayPoll.watchTimeoutSeconds(waitMilliseconds: RelayPoll.watchWaitMilliseconds), 20)
        XCTAssertEqual(RelayPoll.noNetworkRetrySeconds, 1)
    }
}
