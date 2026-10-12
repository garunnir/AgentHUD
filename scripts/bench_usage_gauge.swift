import Foundation

// Mirrors CodexProvider tail parsing for every session inside the active window,
// then shows which session the HUD would pick and what it would display.
let home = NSHomeDirectory()
let sessionsRoot = (home as NSString).appendingPathComponent(".codex/sessions")
let activeWindow: TimeInterval = 3600
let completionRetention: TimeInterval = 1800
let limitGrace: TimeInterval = 1800

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func iso(_ formatter: ISO8601DateFormatter, _ d: Date) -> String {
    formatter.string(from: d)
}

let files = try! FileManager.default.subpathsOfDirectory(atPath: sessionsRoot).filter { $0.hasSuffix(".jsonl") }
let cutoff = Date().addingTimeInterval(-max(activeWindow, completionRetention))
var formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

struct Parsed {
    var id: String
    var lastActivityAt: Date
    var primaryUsed: Double?
    var primaryResets: Date?
    var secondaryUsed: Double?
    var secondaryResets: Date?
    var tokenCountEvents: Int
}

var parsed: [Parsed] = []

for relative in files {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
    let modified = (attrs[.modificationDate] as? Date) ?? Date()
    guard modified >= cutoff else { continue }

    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
    defer { try? stream.close() }
    guard let firstLine = try? readFirstLineOf(stream) else { continue }
    guard let json = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
          json["type"] as? String == "session_meta",
          let payload = json["payload"] as? [String: Any] else { continue }
    let id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? "?"
    var lastActivity = parseDate(json["timestamp"] as? String) ?? .distantPast
    var pUsed: Double?; var pResets: Date?; var sUsed: Double?; var sResets: Date?
    var events = 0

    let length = (try? stream.seekToEnd()) ?? 0
    let offset = length > 262144 ? length - 262144 : 0
    try? stream.seek(toOffset: offset)
    if let data = try? stream.readToEnd() {
        var content = String(data: data, encoding: .utf8) ?? ""
        if offset > 0, let nl = content.firstIndex(of: "\n") { content = String(content[content.index(after: nl)...]) }
        for line in content.components(separatedBy: "\n").dropLast() {
            guard let d = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let stamp = entry["timestamp"] as? String, let t = parseDate(stamp) else { continue }
            guard t >= lastActivity else { continue }
            lastActivity = t
            guard let body = entry["payload"] as? [String: Any] else { continue }
            guard (entry["type"] as? String) == "event_msg", (body["type"] as? String) == "token_count" else { continue }
            events += 1
            guard let limits = body["rate_limits"] as? [String: Any] else { continue }
            if let w = limits["primary"] as? [String: Any],
               let u = w["used_percent"] as? Double, let r = w["resets_at"] as? Int64 {
                pUsed = u; pResets = Date(timeIntervalSince1970: TimeInterval(r))
            }
            if let w = limits["secondary"] as? [String: Any],
               let u = w["used_percent"] as? Double, let r = w["resets_at"] as? Int64 {
                sUsed = u; sResets = Date(timeIntervalSince1970: TimeInterval(r))
            }
        }
    }

    let age = Date().timeIntervalSince(lastActivity)
    guard age <= completionRetention || age <= activeWindow || (pResets.map { Date() < $0.addingTimeInterval(limitGrace) } ?? false) else { continue }
    parsed.append(Parsed(id: id, lastActivityAt: lastActivity, primaryUsed: pUsed, primaryResets: pResets,
                          secondaryUsed: sUsed, secondaryResets: sResets, tokenCountEvents: events))
}

func readFirstLineOf(_ stream: FileHandle) -> String? {
    var data = Data()
    while data.count < 262144 {
        guard let chunk = try? stream.read(upToCount: 8192), !chunk.isEmpty else { break }
        data.append(chunk)
        if data.contains(0x0A) { break }
    }
    guard let content = String(data: data, encoding: .utf8) else { return nil }
    return String(content.prefix { $0 != "\n" })
}

print("sessions the HUD would hold: \(parsed.count)\n")
for p in parsed.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) {
    print("id: \(p.id)")
    print("  lastActivity: \(iso(formatter, p.lastActivityAt))   token_count events: \(p.tokenCountEvents)")
    print("  primary:   used=\(p.primaryUsed.map { "\($0)%" } ?? "nil")  resets=\(p.primaryResets.map { iso(formatter, $0) } ?? "nil")")
    print("  secondary: used=\(p.secondaryUsed.map { "\($0)%" } ?? "nil")  resets=\(p.secondaryResets.map { iso(formatter, $0) } ?? "nil")")
}

if let latest = parsed.filter({ $0.primaryUsed != nil }).max(by: { $0.lastActivityAt < $1.lastActivityAt }) {
    print("\n=> HUD picks session \(latest.id)")
    let used = latest.primaryUsed ?? 0
    print("   shows 5h remaining: \(Int((100 - used).rounded()))%   weekly remaining: \(Int((100 - (latest.secondaryUsed ?? 0)).rounded()))%")
} else {
    print("\n=> no session with limits; HUD shows 'No limit info'")
}