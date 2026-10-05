import Foundation
import WatchRemoteCore

/// Posts this iPhone's public key to the computer that is waiting after `watch-remote-pair`.
enum HostEnroll {
    static func submit(address: String, port: Int, ticket: String, publicKey: String) async -> String? {
        guard OverlayPolicy.allows(address: address), (1...65535).contains(port) else {
            return "That computer is outside the private overlay."
        }
        guard let url = URL(string: "http://\(address):\(port)/v1/enroll") else {
            return "The pairing channel could not be opened."
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(publicKey.utf8)
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "The computer did not accept this iPhone. Open Advanced and use the authorize command."
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            guard text.contains("\"ok\":true") else {
                return "The computer did not accept this iPhone. Open Advanced and use the authorize command."
            }
            return nil
        } catch {
            return "The computer did not answer. Leave watch-remote-pair open, then scan again."
        }
    }
}
