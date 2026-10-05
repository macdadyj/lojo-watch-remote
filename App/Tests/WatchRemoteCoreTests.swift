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
        let (_, loadJSON) = codec.loadSession(sessionID: "abc", cwd: "/work")
        let loadObject = try? JSONSerialization.jsonObject(with: Data(loadJSON.utf8)) as? [String: Any]
        let loadParams = loadObject?["params"] as? [String: Any]
        XCTAssertEqual(loadObject?["method"] as? String, "session/load")
        XCTAssertEqual(loadParams?["sessionId"] as? String, "abc")
        XCTAssertEqual(loadParams?["cwd"] as? String, "/work")
        XCTAssertFalse(loadJSON.contains("bash"))
        XCTAssertFalse(loadJSON.contains("server-key"))
        let nested = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn","usage":{"input_tokens":3,"output_tokens":4}}}"#
        XCTAssertEqual(GrokOutput.parseUsage(nested), "3 in · 4 out")
        let plain = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#
        XCTAssertTrue(ACPCodec.approvalsAvailable(inResultJSON: plain))
        let headless = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{"approvals":false}}}"#
        XCTAssertFalse(ACPCodec.approvalsAvailable(inResultJSON: headless))
    }

    func testSessionListUsesGrokExtensionNameAndUnwrapsTheResult() {
        var codec = ACPCodec()
        let (_, listJSON) = codec.listSessions()
        let listObject = try? JSONSerialization.jsonObject(with: Data(listJSON.utf8)) as? [String: Any]
        XCTAssertEqual(listObject?["method"] as? String, "_x.ai/session/list")
        let (_, legacyJSON) = codec.listSessionsLegacy()
        let legacyObject = try? JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any]
        XCTAssertEqual(legacyObject?["method"] as? String, "x.ai/session/list")
        let (_, usageJSON) = codec.sessionUsage(sessionID: "abc")
        let usageObject = try? JSONSerialization.jsonObject(with: Data(usageJSON.utf8)) as? [String: Any]
        XCTAssertEqual(usageObject?["method"] as? String, "_x.ai/session/usage")
        let wrapped = #"{"jsonrpc":"2.0","id":2,"result":{"result":{"sessions":[{"sessionId":"abc","title":"Logs","summary":"Reading","status":"running"}]}}}"#
        let sessions = ACPCodec.sessions(inResultJSON: wrapped)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "abc")
        XCTAssertEqual(sessions[0].title, "Logs")
        XCTAssertEqual(sessions[0].status, .running)
        let flat = #"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"def","title":"Door","status":"idle"}]}}"#
        XCTAssertEqual(ACPCodec.sessions(inResultJSON: flat).first?.title, "Door")
        let usage = #"{"jsonrpc":"2.0","id":3,"result":{"result":{"usage":{"inputTokens":3,"outputTokens":4}}}}"#
        XCTAssertEqual(GrokOutput.parseUsage(usage), "3 in · 4 out")
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
        let upgrade = String(decoding: WebSocketFramer.upgradeRequest(host: "127.0.0.1:2419", path: "/ws", webSocketKey: "abc", authorization: "example-secret"), as: UTF8.self)
        XCTAssertTrue(upgrade.contains("GET /ws HTTP/1.1"))
        XCTAssertTrue(upgrade.contains("Authorization: Bearer example-secret"))
        XCTAssertFalse(upgrade.contains("server-key"))
        XCTAssertFalse(upgrade.contains("?"))
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
        let raw = Data([
            0x03, 0xa1, 0x07, 0xbf, 0xf3, 0xce, 0x10, 0xbe, 0x1d, 0x70, 0xdd, 0x18, 0xe7, 0x4b, 0xc0, 0x99,
            0x67, 0xe4, 0xd6, 0x30, 0x9b, 0xa5, 0x0d, 0x5f, 0x1d, 0xdc, 0x86, 0x64, 0x12, 0x55, 0x31, 0xb8,
        ])
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4 watch-remote@iphone"
        XCTAssertEqual(OpenSSHPublicKey.ed25519(rawPublicKey: raw), line)
        let blob = line.split(separator: " ")[1]
        XCTAssertFalse(blob.contains("-"))
        XCTAssertFalse(blob.contains("_"))
        XCTAssertTrue(blob.contains("+"))
        XCTAssertTrue(blob.contains("/"))
        XCTAssertFalse(line.hasSuffix("/"))
        let authorize = AuthorizeCommand.text(publicKey: line)
        XCTAssertEqual(authorize, "watch-remote-authorize '\(line)'")
        XCTAssertFalse(authorize.contains("\n"))
        let urlSafe = line.replacingOccurrences(
            of: "AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4",
            with: "AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7_zzhC-HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4"
        )
        let wrapped = line.replacingOccurrences(of: "HXDdGOdLw", with: "HXDd-\nGOdLw")
        let partial = line.replacingOccurrences(of: "zzhC+", with: "zzhC-")
        let inserted = line.replacingOccurrences(of: "HXDdGOd", with: "HXDd-GOd")
        XCTAssertEqual(OpenSSHPublicKey.canonical(urlSafe), line)
        XCTAssertEqual(OpenSSHPublicKey.canonical(wrapped), line)
        XCTAssertEqual(OpenSSHPublicKey.canonical(partial), line)
        XCTAssertNotEqual(OpenSSHPublicKey.canonical(inserted), line)
        XCTAssertEqual(AuthorizeCommand.text(publicKey: partial), authorize)
        let enroll = EnrollHTTP.request(host: "100.64.0.2", port: 2478, ticket: "roomtokenvalue0001", publicKey: line)
        let enrollText = String(data: enroll ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(enrollText.hasPrefix("POST /v1/enroll HTTP/1.1\r\n"))
        XCTAssertTrue(enrollText.contains("Authorization: Bearer roomtokenvalue0001\r\n"))
        XCTAssertTrue(enrollText.contains("\r\n\r\n\(line)"))
        XCTAssertFalse(enrollText.contains("http://"))
        XCTAssertNil(EnrollHTTP.request(host: "100.64.0.2", port: 2478, ticket: "bad\nticket", publicKey: line))
        let ok = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}\n".utf8)
        XCTAssertEqual(EnrollHTTP.response(from: ok)?.status, 200)
        XCTAssertTrue(EnrollHTTP.response(from: ok)?.body.contains("\"ok\":true") ?? false)
        let refused = Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 8\r\n\r\nRefused\n".utf8)
        XCTAssertEqual(EnrollHTTP.response(from: refused)?.status, 401)
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
        XCTAssertEqual(try payload.encodedToken(), golden)
        XCTAssertEqual(try PairingPayload.decode(golden).secret, "example-secret")

        let bare = try PairingPayload(label: " example-host ", address: "100.64.0.1", user: "user", port: 22)
        XCTAssertNil(bare.secret)
        XCTAssertNil(bare.fingerprint)
        XCTAssertEqual(
            try bare.encodedToken(),
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
        let ticket = "roomtokenvalue0001"
        let enrolled = try PairingPayload(
            label: "example-host",
            address: "100.64.0.2",
            user: "user",
            port: 22,
            ticket: ticket,
            enrollPort: 2478
        )
        XCTAssertTrue(enrolled.canEnroll)
        XCTAssertTrue(enrolled.summary.contains("This iPhone can authorize itself."))
        XCTAssertFalse(enrolled.summary.contains(ticket))
        XCTAssertEqual(try PairingPayload.decode(try enrolled.urlString()).ticket, ticket)
        XCTAssertThrowsError(try PairingPayload(
            label: "example-host",
            address: "100.64.0.2",
            user: "user",
            port: 22,
            ticket: "short"
        )) { error in
            XCTAssertEqual(error as? PairingError, .invalidTicket)
        }
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
        var wrongDirection = RelayReplay()
        XCTAssertThrowsError(try RelayBox.open(frame: third, key: key, expecting: .hostToWatch, replay: &wrongDirection)) { error in
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

    func testVoiceDialogueMatchesCommandsAndConfirmsAllowInTwoSteps() {
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Allow", phase: .idle), .requestAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Allow!", phase: .idle), .requestAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("please approve it", phase: .idle), .requestAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("yes", phase: .idle), .unrecognized)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("confirm", phase: .idle), .unrecognized)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Yes, confirm", phase: .idle), .unrecognized)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("OK", phase: .idle), .unrecognized)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("go ahead", phase: .idle), .unrecognized)

        XCTAssertEqual(VoiceDialogueMatcher.interpret("yes", phase: .awaitingAllowYes), .confirmAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("confirm", phase: .awaitingAllowYes), .confirmAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Yes, confirm", phase: .awaitingAllowYes), .confirmAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("okay", phase: .awaitingAllowYes), .confirmAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("go ahead", phase: .awaitingAllowYes), .confirmAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("allow", phase: .awaitingAllowYes), .requestAllow)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("deny", phase: .awaitingAllowYes), .deny)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("stop", phase: .awaitingAllowYes), .stop)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("never mind", phase: .awaitingAllowYes), .cancelConfirm)
        XCTAssertEqual(
            VoiceDialogueMatcher.interpret("Fix the tests", phase: .awaitingAllowYes),
            .newTask("Fix the tests")
        )

        XCTAssertEqual(VoiceDialogueMatcher.interpret("deny", phase: .idle), .deny)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Don't allow", phase: .idle), .deny)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Don\u{2019}t allow", phase: .idle), .deny)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("do not approve", phase: .idle), .deny)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("no", phase: .idle), .deny)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("reject it", phase: .idle), .deny)

        XCTAssertEqual(VoiceDialogueMatcher.interpret("stop", phase: .idle), .stop)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("STOP the task", phase: .idle), .stop)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("cancel", phase: .idle), .stop)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("halt it", phase: .idle), .stop)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("please stop", phase: .idle), .stop)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("stop session", phase: .idle), .stopSession)

        XCTAssertEqual(VoiceDialogueMatcher.interpret("list sessions", phase: .idle), .listSessions)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("status", phase: .idle), .status)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("switch computer", phase: .idle), .switchComputer(nil))
        XCTAssertEqual(VoiceDialogueMatcher.interpret("switch computer to", phase: .idle), .switchComputer(nil))
        XCTAssertEqual(
            VoiceDialogueMatcher.interpret("switch to example-host", phase: .idle),
            .switchComputer("example host")
        )
        XCTAssertEqual(VoiceDialogueMatcher.interpret("Fix the tests", phase: .idle), .newTask("Fix the tests"))

        XCTAssertEqual(VoiceDialogueMatcher.interpret("", phase: .idle), .unrecognized)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("   ", phase: .idle), .unrecognized)
        XCTAssertEqual(VoiceDialogueMatcher.interpret("please", phase: .idle), .unrecognized)
        XCTAssertEqual(
            VoiceDialogueMatcher.interpret("allow the parser to write the file", phase: .idle),
            .newTask("allow the parser to write the file")
        )
        XCTAssertEqual(
            VoiceDialogueMatcher.interpret("stop by the lab", phase: .idle),
            .newTask("stop by the lab")
        )
        XCTAssertEqual(VoiceDialogueMatcher.interpret("don't stop", phase: .idle), .newTask("don't stop"))
        XCTAssertEqual(VoiceDialogueMatcher.interpret("allowance", phase: .idle), .newTask("allowance"))
        XCTAssertEqual(
            VoiceDialogueMatcher.interpret("Ask Grok to fix the tests", phase: .idle),
            .newTask("Ask Grok to fix the tests")
        )

        let line = VoiceAllowScript.readback(title: "Edit the file", detail: "Write the tests")
        XCTAssertTrue(line.contains("Edit the file"))
        XCTAssertTrue(line.contains("Write the tests"))
        XCTAssertTrue(line.hasSuffix(VoiceAllowScript.confirmCue))
        XCTAssertNotEqual(VoiceDialogueMatcher.interpret(line, phase: .idle), .requestAllow)
        XCTAssertNotEqual(VoiceDialogueMatcher.interpret(line, phase: .awaitingAllowYes), .confirmAllow)
        XCTAssertNotEqual(VoiceDialogueMatcher.interpret(line, phase: .awaitingAllowYes), .requestAllow)

        let long = VoiceAllowScript.readback(title: String(repeating: "word ", count: 80), detail: "detail")
        XCTAssertTrue(long.hasSuffix(VoiceAllowScript.confirmCue))
        XCTAssertLessThanOrEqual(long.count, 180)

        XCTAssertEqual(
            VoiceAllowScript.matchingLabel(spoken: "example host", labels: ["example-host"]),
            "example-host"
        )
        XCTAssertNil(VoiceAllowScript.matchingLabel(spoken: "lab", labels: ["lab-1", "lab-2"]))
        XCTAssertNil(VoiceAllowScript.matchingLabel(spoken: "a", labels: ["example-host"]))

        let sessions = [
            GrokSession(id: "1", title: "Logs", summary: "", status: .running),
            GrokSession(id: "2", title: "Edit", summary: "", status: .needsApproval),
        ]
        XCTAssertEqual(VoiceAllowScript.sessionsSpeech(sessions), "2 sessions. Logs, Running. Edit, Needs approval.")
        XCTAssertEqual(VoiceAllowScript.sessionsSpeech([]), "No sessions.")
        XCTAssertEqual(
            VoiceAllowScript.statusSpeech(host: "example-host", linkTitle: "Connected", running: 2, waiting: 1),
            "example-host. Connected. 1 task needs approval."
        )
        XCTAssertEqual(
            VoiceAllowScript.statusSpeech(host: "example-host", linkTitle: "Connected", running: 0, waiting: 0),
            "example-host. Connected. Nothing is running."
        )
    }

    func testVoiceTaskAsksBeforeSendingUnlessAutoSendIsOn() {
        XCTAssertEqual(
            VoiceTaskPolicy.disposition(transcript: "  Fix the tests  ", autoSend: false),
            .confirm("Fix the tests")
        )
        XCTAssertEqual(
            VoiceTaskPolicy.disposition(transcript: "Fix\nthe tests", autoSend: true),
            .send("Fix the tests")
        )
        XCTAssertEqual(VoiceTaskPolicy.disposition(transcript: "   ", autoSend: true), .ignore)
        XCTAssertEqual(VoiceTaskPolicy.disposition(transcript: "", autoSend: false), .ignore)
        XCTAssertEqual(VoiceTaskPolicy.disposition(transcript: "cancel", autoSend: false), .confirm("cancel"))
        XCTAssertEqual(VoiceTaskPolicy.disposition(transcript: "stop", autoSend: true), .send("stop"))
        XCTAssertEqual(
            VoiceTaskPolicy.disposition(transcript: "summarize the open changes", autoSend: true),
            .send("summarize the open changes")
        )
    }

    func testVoiceResultPickerReadsFinishedChangesOnly() {
        let running = GrokSession(id: "1", title: "Logs", summary: "Looking", status: .running)
        let done = GrokSession(
            id: "1",
            title: "Logs",
            summary: "Build passed.",
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            VoiceResultPicker.latestResult(previous: [running], current: [done], includeNew: true),
            VoiceResult(sessionID: "1", text: "Build passed.")
        )
        XCTAssertNil(VoiceResultPicker.latestResult(previous: [], current: [done], includeNew: true))
        XCTAssertNil(VoiceResultPicker.latestResult(previous: [running], current: [running], includeNew: true))

        let approval = GrokSession(id: "1", title: "Logs", summary: "Wants to edit.", status: .needsApproval)
        XCTAssertNil(VoiceResultPicker.latestResult(previous: [running], current: [approval], includeNew: true))

        let failed = GrokSession(id: "1", title: "Logs", summary: "The agent server did not answer.", status: .failed)
        XCTAssertEqual(
            VoiceResultPicker.latestResult(previous: [running], current: [failed], includeNew: false)?.text,
            "The agent server did not answer."
        )

        let kept = GrokSession(id: "1", title: "Logs", summary: "Build passed.", status: .idle)
        let fresh = GrokSession(id: "2", title: "New", summary: "Done.", status: .stopped)
        XCTAssertEqual(
            VoiceResultPicker.latestResult(previous: [done], current: [kept, fresh], includeNew: true)?.sessionID,
            "2"
        )
        XCTAssertNil(VoiceResultPicker.latestResult(previous: [done], current: [kept, fresh], includeNew: false))

        let older = GrokSession(
            id: "1",
            title: "A",
            summary: "First result.",
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let newer = GrokSession(
            id: "2",
            title: "B",
            summary: "Second result.",
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 9)
        )
        let olderWas = GrokSession(id: "1", title: "A", summary: "Old.", status: .running)
        let newerWas = GrokSession(id: "2", title: "B", summary: "Old.", status: .running)
        XCTAssertEqual(
            VoiceResultPicker.latestResult(
                previous: [olderWas, newerWas],
                current: [older, newer],
                includeNew: true
            )?.text,
            "Second result."
        )

        let sameTimeFirst = GrokSession(id: "1", title: "A", summary: "Alpha.", status: .idle)
        let sameTimeSecond = GrokSession(id: "2", title: "B", summary: "Beta.", status: .idle)
        XCTAssertEqual(
            VoiceResultPicker.latestResult(
                previous: [olderWas, newerWas],
                current: [sameTimeFirst, sameTimeSecond],
                includeNew: false
            )?.text,
            "Alpha."
        )

        let long = String(repeating: "word ", count: 80)
        let longSession = GrokSession(id: "1", title: "Logs", summary: long, status: .stopped)
        let spoken = VoiceResultPicker.latestResult(previous: [running], current: [longSession], includeNew: true)
        XCTAssertLessThanOrEqual(spoken?.text.count ?? 0, 280)
        XCTAssertTrue(spoken?.text.hasSuffix("…") ?? false)
    }

    func testHandsFreeSilenceSendsWithoutDoneAndSpokenApprovalsStayTwoStep() throws {
        var detector = VoiceEndpointDetector(configuration: VoiceEndpointDetector.Configuration(
            threshold: 0.02,
            onset: 0.1,
            silence: 0.5,
            minimumSpeech: 0.2,
            maximumSpeech: 1
        ))
        XCTAssertNil(detector.observe(rms: 0, at: 0.4))
        XCTAssertNil(detector.observe(rms: 0.01, at: 0.45))
        XCTAssertNil(detector.observe(rms: 0.2, at: 0.5))
        let began = try XCTUnwrap(detector.observe(rms: 0.2, at: 0.6))
        XCTAssertEqual(began, .began)
        XCTAssertFalse(VoiceHandsFreePolicy.shouldSend(after: began))
        XCTAssertNil(detector.observe(rms: 0.2, at: 0.9))
        XCTAssertNil(detector.observe(rms: 0, at: 1.2))
        let ended = try XCTUnwrap(detector.observe(rms: 0, at: 1.4))
        XCTAssertEqual(ended, .ended(.silence))
        XCTAssertTrue(VoiceHandsFreePolicy.shouldSend(after: ended))

        var limited = VoiceEndpointDetector(configuration: VoiceEndpointDetector.Configuration(
            threshold: 0.02,
            onset: 0,
            silence: 10,
            minimumSpeech: 0,
            maximumSpeech: 1
        ))
        XCTAssertEqual(limited.observe(rms: 0.2, at: 0), .began)
        XCTAssertEqual(limited.observe(rms: 0.2, at: 1), .ended(.maximum))
        XCTAssertEqual(limited.phase, .idle)
        XCTAssertNil(limited.observe(rms: 0, at: 1.2))

        XCTAssertEqual(VoiceEndpointDetector.Configuration.handsFree.silence, 0.65)
        XCTAssertNil(VoiceTranscriptGate.commandText("stop", isFinal: false))
        XCTAssertNil(VoiceTranscriptGate.commandText("   ", isFinal: true))
        XCTAssertEqual(VoiceTranscriptGate.commandText("  stop the task  ", isFinal: true), "stop the task")

        var capture = VoiceCaptureBuffer(prerollFrames: 4, chunkFrames: 4)
        XCTAssertEqual(capture.append([1, 2], hearingSpeech: false), [])
        XCTAssertEqual(capture.append([3, 4, 5, 6], hearingSpeech: true), [[1, 2, 3, 4]])
        XCTAssertEqual(capture.finish(), [5, 6])
        var silent = VoiceCaptureBuffer(prerollFrames: 4, chunkFrames: 4)
        XCTAssertTrue(silent.append([9], hearingSpeech: false).isEmpty)

        let samples: [Int16] = [0, 16_384, -16_384]
        let packet = VoicePacket.audio(id: "utterance", sequence: 2, samples: samples, isLast: true)
        let encoded = try XCTUnwrap(VoiceWire.encode(packet))
        XCTAssertEqual(try XCTUnwrap(VoiceWire.decode(encoded)), packet)
        XCTAssertEqual(VoicePCM.samples(base64: packet.pcmBase64), samples)
        XCTAssertNil(VoiceWire.decode("{"))
        XCTAssertEqual(VoicePCM.rms([]), 0)
        XCTAssertEqual(VoicePCM.resample([0, 1], from: 16_000, to: 16_000), [0, 1])
        let quieter = VoicePCM.resample([0, 1], from: 2, to: 4)
        XCTAssertEqual(quieter.count, 4)
        XCTAssertEqual(quieter[0], Float(0))
        XCTAssertEqual(quieter[2], Float(1))

        let sessions = DemoCatalog.sessions()
        var context = VoiceTurnContext(
            inConversation: true,
            hostLabel: "example-host",
            linkTitle: "Connected",
            sessions: sessions,
            computers: [ComputerSummary(id: "computer", label: "example-host")],
            activeComputerID: ""
        )
        let idleYes = VoiceTurnPlanner.effect(for: "yes", context: context)
        XCTAssertEqual(idleYes.action, .none)
        XCTAssertNotEqual(idleYes.command, .confirmAllow)

        let allow = VoiceTurnPlanner.effect(for: "allow", context: context)
        XCTAssertEqual(allow.phase, .awaitingAllowYes)
        XCTAssertEqual(allow.action, .none)
        XCTAssertEqual(allow.pendingAllowSessionID, DemoCatalog.approvalID)
        XCTAssertTrue(allow.spoken.hasSuffix(VoiceAllowScript.confirmCue))
        XCTAssertTrue(allow.listenAgain)
        context.pendingAllowSessionID = allow.pendingAllowSessionID

        let denied = VoiceTurnPlanner.effect(for: "deny", context: context)
        XCTAssertEqual(denied.action, .deny(sessionID: DemoCatalog.approvalID))
        XCTAssertEqual(denied.spoken, "Denied.")
        XCTAssertEqual(denied.phase, .idle)
        XCTAssertNil(denied.pendingAllowSessionID)

        let stopped = VoiceTurnPlanner.effect(for: "stop", context: context)
        XCTAssertEqual(stopped.action, .stop(sessionID: DemoCatalog.approvalID))
        XCTAssertTrue(stopped.spoken.hasPrefix("Stopping "))
        XCTAssertNotEqual(stopped.action, .allow(sessionID: DemoCatalog.approvalID))

        let yes = VoiceTurnPlanner.effect(for: "yes", context: context)
        XCTAssertEqual(yes.action, .allow(sessionID: DemoCatalog.approvalID))
        XCTAssertEqual(yes.spoken, "Allowed.")
        XCTAssertTrue(yes.listenAgain)

        let task = VoiceTurnPlanner.effect(for: "Fix the tests", context: context)
        XCTAssertEqual(task.action, .startTask("Fix the tests"))
        XCTAssertTrue(task.listenAgain)
        XCTAssertEqual(task.phase, .idle)

        let lines = VoiceLoopHarness.lines(sessions: sessions, hostLabel: "example-host", linkTitle: "Connected")
        XCTAssertTrue(lines[0].contains("Done is not used"))
        XCTAssertTrue(lines.contains { $0.contains(VoiceAllowScript.confirmCue) })
        XCTAssertTrue(lines.contains { $0.contains("Allowed.") })
        XCTAssertTrue(lines.contains { $0.contains("Denied.") })
        XCTAssertTrue(lines.contains { $0.contains("Stopping") })
        XCTAssertTrue(lines.contains { $0.contains("0.65s") })
    }
}
