import Foundation

// Measures the optimized Codex scan: stat all files, but only fully parse rollout
// files that are recent enough to be listed (or that carry a usage-limit marker).
let home = NSHomeDirectory()
let sessionsRoot = (home as NSString).appendingPathComponent(".codex/sessions")
let completionRetention: TimeInterval = 1800
let activeWindow: TimeInterval = 3600

func now() -> Double { Date().timeIntervalSinceReferenceDate }
func ms(_ d: Double) -> String { String(format: "%7.1f ms", d * 1000) }

func tailContains(_ path: String, _ needle: String, maxBytes: Int = 8192) -> Bool {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
    defer { try? stream.close() }
    let length = (try? stream.seekToEnd()) ?? 0
    guard length > 0 else { return false }
    let offset = length > UInt64(maxBytes) ? length - UInt64(maxBytes) : 0
    try? stream.seek(toOffset: offset)
    guard let data = try? stream.readToEnd(), let text = String(data: data, encoding: .utf8) else { return false }
    return text.contains(needle)
}

func readFirstLine(_ path: String) -> String? {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? stream.close() }
    var data = Data()
    while data.count < 262144 {
        guard let chunk = try? stream.read(upToCount: 8192), !chunk.isEmpty else { break }
        data.append(chunk)
        if data.contains(0x0A) { break }
    }
    guard let content = String(data: data, encoding: .utf8) else { return nil }
    return String(content.prefix { $0 != "\n" })
}

let t0 = now()
let files = try! FileManager.default.subpathsOfDirectory(atPath: sessionsRoot).filter { $0.hasSuffix(".jsonl") }
let tEnumerate = now()

let cutoff = Date().addingTimeInterval(-max(activeWindow, completionRetention))
var fullParses = 0
var skipped = 0
var sessionsFound = 0

for relative in files {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
    let modified = (attrs[.modificationDate] as? Date) ?? Date()
    if modified < cutoff, !tailContains(path, "usage_limit_exceeded") { skipped += 1; continue }

    fullParses += 1
    guard let first = readFirstLine(path),
          let json = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
          json["type"] as? String == "session_meta",
          let payload = json["payload"] as? [String: Any],
          payload["id"] as? String != nil || payload["session_id"] as? String != nil else { continue }
    sessionsFound += 1
}

let total = now() - t0
print("files:            \(files.count)")
print("enumerate:        \(ms(tEnumerate - t0))")
print("full parses:      \(fullParses)  (skipped \(skipped))")
print("sessions parsed:  \(sessionsFound)")
print("TOTAL:            \(ms(total))")