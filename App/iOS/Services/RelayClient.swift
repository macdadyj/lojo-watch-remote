import CryptoKit
import Foundation
import WatchRemoteCore

enum RelayError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

final class RelayClient: NSObject, URLSessionDelegate {
    private var pinnedHex = ""
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func list(url: String, token: String?, pin: String?) async throws -> [GrokSession] {
        let body = try await request(url: url, token: token, pin: pin, path: "/v1/sessions", method: "GET", json: nil)
        return try decodeSessions(body)
    }

    func start(url: String, token: String?, pin: String?, prompt: String, cwd: String) async throws -> GrokSession {
        let payload: [String: String] = ["prompt": prompt, "cwd": cwd]
        let body = try await request(url: url, token: token, pin: pin, path: "/v1/sessions", method: "POST", json: payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(GrokSession.self, from: body)
    }

    func decide(url: String, token: String?, pin: String?, permissionID: String, allow: Bool) async throws {
        _ = try await request(
            url: url,
            token: token,
            pin: pin,
            path: "/v1/permissions/\(permissionID)",
            method: "POST",
            json: ["allow": allow]
        )
    }

    func cancel(url: String, token: String?, pin: String?, sessionID: String) async throws {
        _ = try await request(url: url, token: token, pin: pin, path: "/v1/sessions/\(sessionID)/cancel", method: "POST", json: [:])
    }

    func load(url: String, token: String?, pin: String?, sessionID: String) async throws -> [String] {
        let body = try await request(
            url: url,
            token: token,
            pin: pin,
            path: "/v1/sessions/\(sessionID)/resume",
            method: "POST",
            json: [:]
        )
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let lines = object?["lines"] as? [String] ?? []
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func prompt(url: String, token: String?, pin: String?, sessionID: String, prompt: String, cwd: String) async throws -> GrokSession {
        let body = try await request(
            url: url,
            token: token,
            pin: pin,
            path: "/v1/sessions/\(sessionID)/prompt",
            method: "POST",
            json: ["prompt": prompt, "cwd": cwd]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(GrokSession.self, from: body)
    }

    private func request(url: String, token: String?, pin: String?, path: String, method: String, json: Any?) async throws -> Data {
        guard let token, !token.isEmpty else { throw RelayError.message("Save the relay device token first.") }
        guard let pin, !pin.isEmpty else { throw RelayError.message("Save the relay certificate fingerprint first.") }
        guard let base = URL(string: url), let endpoint = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw RelayError.message("The relay address is not a URL.")
        }
        guard OverlayPolicy.allows(address: endpoint.host ?? "") else {
            throw RelayError.message("The relay has to be on the private overlay.")
        }
        pinnedHex = pin
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue(RelayPin.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.message("The relay did not answer.") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data, as: UTF8.self)
            throw RelayError.message(detail.isEmpty ? "Relay error \(http.statusCode)." : detail)
        }
        return data
    }

    private func decodeSessions(_ data: Data) throws -> [GrokSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        struct Body: Decodable { var sessions: [GrokSession] }
        return try decoder.decode(Body.self, from: data).sessions
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let encoded = SecCertificateCopyData(certificate) as Data
        let digest = Data(SHA256.hash(data: encoded))
        guard RelayPin.matches(certificateSHA256: digest, pinnedHex: pinnedHex) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
