import XCTest
import WatchRemoteCore

final class WatchRemoteCoreTests: XCTestCase {
    func testOverlayAllowsTheCGNATRangeAndRefusesPublicAddresses() {
        XCTAssertTrue(OverlayPolicy.allows(address: "100.64.0.2"))
        XCTAssertTrue(OverlayPolicy.allows(address: "100.64.0.1"))
        XCTAssertTrue(OverlayPolicy.allows(address: "100.127.255.254"))
        XCTAssertFalse(OverlayPolicy.allows(address: "100.63.255.255"))
        XCTAssertFalse(OverlayPolicy.allows(address: "100.128.0.1"))
        XCTAssertFalse(OverlayPolicy.allows(address: "8.8.8.8"))
        XCTAssertFalse(OverlayPolicy.allows(address: "1.1.1.1"))
        XCTAssertFalse(OverlayPolicy.allows(address: "127.0.0.1"))
        XCTAssertFalse(OverlayPolicy.allows(address: "192.168.1.1"))
        XCTAssertFalse(OverlayPolicy.allows(address: "10.0.0.1"))
        XCTAssertFalse(OverlayPolicy.allows(address: "example-host"))
        XCTAssertFalse(OverlayPolicy.allows(address: "100.64.0.2.9"))
        XCTAssertFalse(OverlayPolicy.allows(address: "100.064.0.1"))
        XCTAssertFalse(OverlayPolicy.allows(address: "0100.64.0.1"))
        XCTAssertEqual(OverlayPolicy.canonical(address: "100.64.0.2"), "100.64.0.2")
        XCTAssertNil(OverlayPolicy.canonical(address: "100.064.0.2"))
        XCTAssertNotNil(OverlayPolicy.refusalReason(address: "8.8.8.8"))
        XCTAssertNil(OverlayPolicy.refusalReason(address: "100.64.0.2"))
        XCTAssertEqual(OverlayPolicy.exampleAddress, "100.64.0.2")
        XCTAssertEqual(OverlayPolicy.exampleUser, "user")
    }

    func testPreviewFixturesCoverEmptyFailureAndLongText() {
        XCTAssertEqual(DemoCatalog.preview(named: "empty")?.sessions.count, 0)
        XCTAssertEqual(DemoCatalog.preview(named: "offline")?.link, .offline)
        XCTAssertEqual(DemoCatalog.preview(named: "loading")?.link, .connecting)
        XCTAssertEqual(DemoCatalog.preview(named: "error")?.sessions.first?.status, .failed)
        XCTAssertEqual(DemoCatalog.preview(named: "pairing")?.link, .needsPairing)
        let long = DemoCatalog.preview(named: "long")
        XCTAssertGreaterThan(long?.sessions.first?.title.count ?? 0, 40)
        XCTAssertNil(DemoCatalog.preview(named: "sessions"))
        XCTAssertFalse(DemoCatalog.snapshot().hostLabel.contains("@"))
    }

    func testHeadlessCommandDoesNotCarrySecretsOrAutoApprove() {
        let script = GrokCommands.headlessScript(prompt: "it's $(rm -rf /)", cwd: "/work", resume: "abc")
        XCTAssertTrue(script.contains("streaming-json"))
        XCTAssertTrue(script.contains("--permission-mode dontAsk"))
        XCTAssertTrue(script.contains("--no-auto-update"))
        XCTAssertTrue(script.contains("-r"))
        XCTAssertFalse(script.contains("always-approve"))
        XCTAssertFalse(script.contains("--yolo"))
        XCTAssertFalse(script.contains("GROK_AGENT_SECRET"))
        XCTAssertFalse(script.contains("--secret"))
        XCTAssertTrue(script.contains("-p 'it'\\''s $(rm -rf /)'"))
        let wrapped = GrokCommands.headless(prompt: "it's $(rm -rf /)", cwd: "/work", resume: nil)
        XCTAssertTrue(wrapped.hasPrefix("bash -lc '"))
        XCTAssertTrue(wrapped.hasSuffix("'"))
        XCTAssertEqual(ShellQuoting.singleQuote("a'b$(c)"), "'a'\\''b$(c)'")
    }

    func testStreamingJSONAndUsage() {
        let line = #"{"type":"text","data":"Hello"}"#
        XCTAssertEqual(GrokOutput.parseStreamingLine(line), .text("Hello"))
        let end = #"{"type":"end","stopReason":"end_turn","sessionId":"0199aaaa-0000-7000-8000-000000000003","usage":{"input_tokens":812,"output_tokens":45}}"#
        guard case .end(let id, let reason, let usage) = GrokOutput.parseStreamingLine(end) else {
            return XCTFail("expected end")
        }
        XCTAssertEqual(id, "0199aaaa-0000-7000-8000-000000000003")
        XCTAssertEqual(reason, "end_turn")
        XCTAssertEqual(usage, "812 in · 45 out")
        let usageJSON = #"{"sessionId":"abc","session":{"input_tokens":3,"output_tokens":4}}"#
        XCTAssertEqual(GrokOutput.parseUsage(usageJSON), "3 in · 4 out")
    }

    func testSessionsListParsesJSONAndRows() {
        let json = #"{"sessions":[{"sessionId":"0199aaaa-0000-7000-8000-000000000001","title":"Logs","summary":"Reading","status":"running"}]}"#
        let parsed = GrokOutput.parseSessionsList(json)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "Logs")
        XCTAssertEqual(parsed[0].status, .running)
        let row = "main 0199bbbb-0000-7000-8000-000000000009 2026-10-04 idle Note the overlay"
        let rows = GrokOutput.parseSessionsList(row)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "0199bbbb-0000-7000-8000-000000000009")
        XCTAssertEqual(rows[0].status, .idle)
    }

    func testACPPermissionRoundTrip() {
        var codec = ACPCodec()
        let (initID, initJSON) = codec.initialize()
        XCTAssertEqual(initID, 1)
        XCTAssertTrue(initJSON.contains("\"protocolVersion\":1"))
        XCTAssertFalse(initJSON.contains("yoloMode\":true"))
        let request = PermissionRequest(
            id: "s:7",
            sessionID: "s",
            rpcID: "7",
            rpcIDIsNumber: true,
            title: "Edit a file",
            detail: "parser",
            allowOptionID: "allow-once",
            denyOptionID: "reject-once"
        )
        let allow = codec.permissionResponse(for: request, allow: true)
        let allowObject = try? JSONSerialization.jsonObject(with: Data(allow.utf8)) as? [String: Any]
        let result = allowObject?["result"] as? [String: Any]
        let outcome = result?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["outcome"] as? String, "selected")
        XCTAssertEqual(outcome?["optionId"] as? String, "allow-once")
        XCTAssertEqual(allowObject?["id"] as? Int, 7)
        let incoming = """
        {"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"title":"Edit a file"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Deny","kind":"reject_once"}]}}
        """
        guard case .permission(let parsed) = codec.parse(incoming) else {
            return XCTFail("expected permission")
        }
        XCTAssertEqual(parsed.allowOptionID, "allow-once")
        XCTAssertEqual(parsed.denyOptionID, "reject-once")
        XCTAssertEqual(parsed.title, "Edit a file")
        let update = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done"}}}}
        """
        guard case .update(_, let event) = codec.parse(update) else {
            return XCTFail("expected update")
        }
        XCTAssertEqual(event, .text("Done"))
    }

    func testWebSocketFramesAndUpgrade() {
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
        XCTAssertTrue(WebSocketFramer.acceptsUpgrade(header))
        XCTAssertFalse(WebSocketFramer.acceptsUpgrade("HTTP/1.1 200 OK\r\n\r\n"))
        var framer = WebSocketFramer()
        let payload = Data("Hello".utf8)
        var server = Data([0x81, UInt8(payload.count)])
        server.append(payload)
        let frames = framer.append(server)
        XCTAssertEqual(frames, [WebSocketFrame(opcode: .text, payload: payload)])
        let mask: [UInt8] = [9, 8, 7, 6]
        let client = WebSocketFramer.encodeClientText("Hi", mask: mask)
        XCTAssertEqual(client[0], 0x81)
        XCTAssertEqual(client[1] & 0x80, 0x80)
        let encoded = Array(client.suffix(2))
        XCTAssertEqual(encoded[0], UInt8(ascii: "H") ^ 9)
        XCTAssertEqual(encoded[1], UInt8(ascii: "i") ^ 8)
        XCTAssertEqual(WebSocketFramer.percentEncode("a b"), "a%20b")
    }

    func testKnownHostsAndAuthorizeCommand() {
        var known = KnownHosts()
        let entry = KnownHostEntry(host: "100.64.0.2", port: 22, keyType: "ssh-ed25519", base64: "AAAA")
        XCTAssertEqual(known.verdict(host: entry.host, port: entry.port, keyType: entry.keyType, base64: entry.base64), .firstUse(entry))
        known.trust(entry)
        let again = KnownHosts(text: known.text())
        XCTAssertEqual(again.verdict(host: entry.host, port: entry.port, keyType: entry.keyType, base64: entry.base64), .trusted)
        if case .changed = again.verdict(host: entry.host, port: entry.port, keyType: entry.keyType, base64: "BBBB") {
        } else {
            XCTFail("expected a changed key")
        }
        let command = AuthorizeCommand.text(publicKey: "ssh-ed25519 AAAA watch-remote@iphone")
        XCTAssertEqual(command, "watch-remote-authorize 'ssh-ed25519 AAAA watch-remote@iphone'")
        XCTAssertFalse(command.contains("PRIVATE"))
        XCTAssertFalse(command.contains("authorized_keys"))
        XCTAssertEqual(SSHFingerprint.sha256Base64(of: Data()), "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    func testMockApproveDenyAndStop() {
        var engine = MockEngine()
        let session = engine.start(prompt: "Fix the parser", cwd: nil)
        XCTAssertEqual(session.status, .running)
        let request = engine.raisePermission(sessionID: session.id)
        XCTAssertEqual(request?.title, "Run the project tests")
        XCTAssertEqual(engine.sessions[0].status, .needsApproval)
        XCTAssertEqual(engine.allow(sessionID: session.id)?.status, .idle)
        _ = engine.raisePermission(sessionID: session.id)
        XCTAssertEqual(engine.deny(sessionID: session.id)?.status, .stopped)
        let again = engine.start(prompt: "Read logs", cwd: nil)
        XCTAssertEqual(engine.stop(sessionID: again.id)?.summary, "Stopped from the watch.")
    }

    func testPairingPayloadRoundTripAndValidation() throws {
        let fingerprint = "SHA256:" + String(repeating: "A", count: 43)
        let payload = try PairingPayload(
            label: "example-host",
            address: "100.64.0.2",
            user: "user",
            port: 22,
            secret: "example-secret",
            fingerprint: "sha256:" + String(repeating: "A", count: 43) + "="
        )
        XCTAssertEqual(payload.fingerprint, fingerprint)
        XCTAssertEqual(payload.address, "100.64.0.2")
        let url = try payload.urlString()
        XCTAssertTrue(url.hasPrefix("watchremote://pair?d="))
        let decoded = try PairingPayload.decode("  \(url)\n")
        XCTAssertEqual(decoded, payload)
        XCTAssertFalse(decoded.summary.contains("example-secret"))
        XCTAssertTrue(decoded.summary.contains("Agent secret included."))
        XCTAssertTrue(decoded.summary.contains(fingerprint))
        let golden = "eyJhZGRyZXNzIjoiMTAwLjY0LjAuMiIsImZpbmdlcnByaW50IjoiU0hBMjU2OkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJsYWJlbCI6ImV4YW1wbGUtaG9zdCIsInBvcnQiOjIyLCJzZWNyZXQiOiJleGFtcGxlLXNlY3JldCIsInVzZXIiOiJ1c2VyIiwidiI6MX0"
        XCTAssertEqual(try payload.token(), golden)
        XCTAssertEqual(try PairingPayload.decode(golden).secret, "example-secret")

        let bare = try PairingPayload(label: " example-host ", address: "100.64.0.1", user: "user", port: 22)
        XCTAssertNil(bare.secret)
        XCTAssertNil(bare.fingerprint)
        XCTAssertEqual(
            try bare.token(),
            "eyJhZGRyZXNzIjoiMTAwLjY0LjAuMSIsImxhYmVsIjoiZXhhbXBsZS1ob3N0IiwicG9ydCI6MjIsInVzZXIiOiJ1c2VyIiwidiI6MX0"
        )
        let json = #"{"v":1,"user":"user","port":22,"address":"100.127.255.254","label":"example-host"}"#
        XCTAssertEqual(try PairingPayload.decode(json).address, "100.127.255.254")

        XCTAssertThrowsError(try PairingPayload(label: "example-host", address: "8.8.8.8", user: "user", port: 22)) { error in
            XCTAssertEqual(error as? PairingError, .addressOutsideOverlay)
        }
        for refused in ["10.0.0.1", "127.0.0.1", "192.168.1.1", "example-host", "100.64.0.2.9", "100.064.0.1", "100.128.0.1"] {
            XCTAssertThrowsError(try PairingPayload(label: "example-host", address: refused, user: "user", port: 22))
        }
        XCTAssertThrowsError(try PairingPayload(label: "example-host", address: "100.64.0.2", user: "bad user", port: 22))
        XCTAssertThrowsError(try PairingPayload(label: "example-host", address: "100.64.0.2", user: "user", port: 0))
        XCTAssertThrowsError(try PairingPayload(label: "example-host", address: "100.64.0.2", user: "user", port: 22, secret: "short"))
        XCTAssertThrowsError(try PairingPayload(label: "example-host", address: "100.64.0.2", user: "user", port: 22, fingerprint: "MD5:abcd"))
        XCTAssertThrowsError(try PairingPayload.decode(#"{"v":2,"label":"example-host","address":"100.64.0.2","user":"user","port":22}"#)) { error in
            XCTAssertEqual(error as? PairingError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try PairingPayload.decode("")) { error in
            XCTAssertEqual(error as? PairingError, .empty)
        }
        XCTAssertThrowsError(try PairingPayload.decode("watchremote://pair"))
        XCTAssertFalse(try PairingPayload.decode(url).summary.contains("example-secret"))
    }

    func testSnapshotCarriesTheComputerList() throws {
        var snapshot = DemoCatalog.snapshot()
        snapshot.computers = [
            ComputerSummary(id: "computer", label: "example-host"),
            ComputerSummary(id: "computer-2", label: "example-host-2"),
        ]
        snapshot.activeComputerID = "computer"
        let text = try XCTUnwrap(LinkCodec.encodeSnapshot(snapshot))
        let decoded = try XCTUnwrap(LinkCodec.decodeSnapshot(text))
        XCTAssertEqual(decoded.computers.map(\.id), ["computer", "computer-2"])
        XCTAssertEqual(decoded.activeComputerID, "computer")
        let legacy = #"{"mode":"demo","link":"demo","sessions":[],"approvalsAvailable":true,"hostLabel":"example-host"}"#
        let older = try XCTUnwrap(LinkCodec.decodeSnapshot(legacy))
        XCTAssertEqual(older.hostLabel, "example-host")
        XCTAssertTrue(older.computers.isEmpty)
        XCTAssertEqual(older.activeComputerID, "")
        let command = PhoneCommand(kind: .selectComputer, computerID: "computer-2")
        let encoded = try XCTUnwrap(LinkCodec.encodeCommand(command))
        XCTAssertEqual(LinkCodec.decodeCommand(encoded), command)
        XCTAssertFalse(decoded.directReady)
        var ready = decoded
        ready.directReady = true
        let again = try XCTUnwrap(LinkCodec.encodeSnapshot(ready))
        XCTAssertEqual(LinkCodec.decodeSnapshot(again)?.directReady, true)
    }

    func testDirectPairingRoundTripOmitsSecretsFromTheSummary() throws {
        let key = Base64URL.encode(Data(repeating: 0x11, count: 32))
        let token = "roomtokenvalue0001"
        let relay = "wss://relay.example/v1/room"
        let payload = try PairingPayload(
            label: "example-host",
            address: "100.64.0.2",
            user: "user",
            port: 22,
            secret: "example-secret",
            relayURL: relay,
            token: token,
            e2eKey: key
        )
        XCTAssertEqual(payload.relayURL, relay)
        XCTAssertEqual(payload.token, token)
        XCTAssertTrue(payload.hasDirectRelay)
        XCTAssertTrue(payload.summary.contains("Direct connection included."))
        XCTAssertFalse(payload.summary.contains(token))
        XCTAssertFalse(payload.summary.contains(key))
        XCTAssertFalse(payload.summary.contains("example-secret"))
        XCTAssertFalse(payload.summary.contains(relay))
        let decoded = try PairingPayload.decode(try payload.urlString())
        XCTAssertEqual(decoded, payload)
        XCTAssertThrowsError(try PairingPayload(
            label: "example-host",
            address: "100.64.0.2",
            user: "user",
            port: 22,
            relayURL: "ws://relay.example/v1/room",
            token: token,
            e2eKey: key
        )) { error in
            XCTAssertEqual(error as? PairingError, .invalidRelay)
        }
        XCTAssertEqual(DemoCatalog.preview(named: "direct")?.link, .connected)
        XCTAssertEqual(DemoCatalog.preview(named: "watch-unpaired")?.link, .needsPairing)
    }

    func testRelaySealRoundTripAndReplay() throws {
        let key = Data(repeating: 0x11, count: 32)
        let plain = Data("{\"id\":\"1\",\"op\":\"ping\"}".utf8)
        let frame = try RelayBox.seal(plaintext: plain, key: key, direction: .watchToHost, counter: 1)
        XCTAssertEqual(Array(frame.prefix(10)), [1, 1, 0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(
            frame.dropFirst(10).prefix(22),
            Data([0x8b, 0xc3, 0x13, 0x05, 0x49, 0x72, 0x25, 0x51, 0x73, 0x25, 0xc9, 0x9e, 0x7a, 0x51, 0xaa, 0x28, 0xab, 0xcd, 0x1e, 0x80, 0x3c, 0x99])
        )
        XCTAssertEqual(
            frame.suffix(16),
            Data([0xb2, 0xfd, 0xc5, 0x00, 0xf2, 0xc2, 0x0b, 0x7a, 0xcd, 0xa9, 0xb0, 0xc0, 0x74, 0x21, 0x1b, 0x68])
        )
        var replay = RelayReplay()
        XCTAssertEqual(try RelayBox.open(frame: frame, key: key, expecting: .watchToHost, replay: &replay), plain)
        XCTAssertThrowsError(try RelayBox.open(frame: frame, key: key, expecting: .watchToHost, replay: &replay)) { error in
            XCTAssertEqual(error as? RelayBoxError, .replayed)
        }
        let second = try RelayBox.seal(plaintext: Data("second".utf8), key: key, direction: .watchToHost, counter: 2)
        XCTAssertEqual(try RelayBox.open(frame: second, key: key, expecting: .watchToHost, replay: &replay), Data("second".utf8))
        var restored = RelayReplay.restored(highest: replay.highest)
        XCTAssertThrowsError(try RelayBox.open(frame: second, key: key, expecting: .watchToHost, replay: &restored))
        let third = try RelayBox.seal(plaintext: Data("third".utf8), key: key, direction: .watchToHost, counter: 3)
        XCTAssertEqual(try RelayBox.open(frame: third, key: key, expecting: .watchToHost, replay: &restored), Data("third".utf8))
        XCTAssertThrowsError(try RelayBox.open(frame: third, key: key, expecting: .hostToWatch, replay: &RelayReplay())) { error in
            XCTAssertEqual(error as? RelayBoxError, .wrongDirection)
        }
        var fresh = RelayReplay()
        var forged = try RelayBox.seal(plaintext: plain, key: key, direction: .watchToHost, counter: 9)
        forged[forged.index(before: forged.endIndex)] ^= 0x01
        XCTAssertThrowsError(try RelayBox.open(frame: forged, key: key, expecting: .watchToHost, replay: &fresh)) { error in
            XCTAssertEqual(error as? RelayBoxError, .refused)
        }
        XCTAssertEqual(fresh.highest, 0)
        XCTAssertEqual(try RelayBox.open(frame: frame, key: key, expecting: .watchToHost, replay: &fresh), plain)
        let message = DirectMessage(op: .start, id: "2", prompt: "Read the build logs")
        let encoded = try XCTUnwrap(DirectMessage.encode(message))
        XCTAssertEqual(DirectMessage.decode(encoded), message)
    }

    func testRelayPinAndSnapshotRoundTrip() {
        let digest = Data([0xab, 0xcd])
        XCTAssertTrue(RelayPin.matches(certificateSHA256: digest, pinnedHex: "AB:CD"))
        XCTAssertFalse(RelayPin.matches(certificateSHA256: digest, pinnedHex: "abcd00"))
        XCTAssertEqual(RelayPin.authorizationHeader(token: " tok "), "Bearer tok")
        let snapshot = DemoCatalog.snapshot().trimmed(summaryLimit: 40)
        let text = try? XCTUnwrap(LinkCodec.encodeSnapshot(snapshot))
        let decoded = text.flatMap(LinkCodec.decodeSnapshot)
        XCTAssertEqual(decoded?.sessions.count, 3)
        XCTAssertEqual(decoded?.hostLabel, "example-host")
        let command = PhoneCommand(kind: .approve, sessionID: DemoCatalog.approvalID, permissionID: "perm-demo")
        let encoded = try? XCTUnwrap(LinkCodec.encodeCommand(command))
        XCTAssertEqual(encoded.flatMap(LinkCodec.decodeCommand), command)
    }
}
