import Foundation

/// The agent door on the computer (host/agentdoor.py, door version 2 and later) keeps Grok's
/// connection open while the phone is away. When the phone comes back with the same link id it
/// resends every frame after `seen`, including approval requests nobody answered, because Grok
/// never asks a second time on a new connection.
public enum DoorLink {
    public static let linkHeader = "X-WatchRemote-Link"
    public static let seenHeader = "X-WatchRemote-Seen"
    public static let doorHeader = "X-WatchRemote-Door"
    public static let resumedHeader = "X-WatchRemote-Resumed"

    public static func requestHeaders(linkID: String, seen: Int) -> [(String, String)] {
        [(linkHeader, linkID), (seenHeader, String(max(0, seen)))]
    }

    public static func headerValue(_ name: String, in head: String) -> String? {
        let wanted = name.lowercased()
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == wanted else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Zero for a door that predates links. That door closes Grok's connection with the phone's.
    public static func doorVersion(in head: String) -> Int {
        Int(headerValue(doorHeader, in: head) ?? "") ?? 0
    }

    /// True when the door reattached an existing link instead of opening a fresh Grok connection.
    public static func resumed(in head: String) -> Bool {
        headerValue(resumedHeader, in: head)?.lowercased() == "yes"
    }
}
