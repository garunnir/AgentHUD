import Foundation

// Compares the current per-line JSONSerialization loop with a filtered + JSONDecoder loop.
let sessionsRoot = NSString(string: "\(NSHomeDirectory())/.codex/sessions").expandingTildeInPath
let files = try! FileManager.default.subpathsOfDirectory(atPath: sessionsRoot).filter { $0.hasSuffix(".jsonl") }
let sample = Array(files.prefix(200))

func now() -> Double { Date().timeIntervalSinceReferenceDate }

func tail(_ path: String) -> String {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
    defer { try? stream.close() }
    let length = (try? stream.seekToEnd()) ?? 0
    let offset = length > 262144 ? length - 262144 : 0
    try? stream.seek(toOffset: offset)
    guard let data = try? stream.readToEnd() else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Current implementation: split into Strings, JSONSerialization every line.
let t0 = now()
var currentLines = 0
for relative in sample {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    let content = tail(path)
    for line in content.components(separatedBy: "\n").dropLast() {
        currentLines += 1
        guard let data = line.data(using: .utf8) else { continue }
        _ = try? JSONSerialization.jsonObject(with: data)
    }
}
let currentTime = now() - t0
print("current: \(currentLines) lines, \(String(format: "%.3f", currentTime))s")

// MARK: - Optimized: byte-level iteration, cheap substring filter, JSONDecoder for keepers.
struct Event: Decodable {
    struct Payload: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let used_percent: Double?
                let resets_at: Int64?
            }
            let primary: Window?
            let secondary: Window?
        }
        let type: String?
        let name: String?
        let call_id: String?
        let used_percent: Double?
        let resets_at: Int64?
        let rate_limits: RateLimits?
    }
    let timestamp: String?
    let type: String?
    let payload: Payload?
}
let decoder = JSONDecoder()

let t1 = now()
var keptLines = 0
var scannedBytes = 0
let needles: [UInt8] = Array("task_started task_complete turn_aborted user_message token_count usage_limit_exceeded request_user_input reasoning function_call custom_tool_call".utf8)

for relative in sample {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    let content = tail(path)
    scannedBytes += content.utf8.count
    var lineStart = content.startIndex
    while lineStart < content.endIndex, let lineEnd = content[lineStart...].firstIndex(of: "\n") {
        let line = content[lineStart..<lineEnd]
        if !line.isEmpty, line.utf8.contains(where: { $0 == UInt8(ascii: "\"") }) {
            // Cheap pre-filter: only parse lines that mention a state/limit relevant token.
            let hits = needles.withContiguousStorageIfAvailable { buf in
                var found = false
                var index = 0
                while index <= line.utf8.count - 12, !found {
                    // naive substring check on the raw slice
                    let slice = String(line.dropFirst(index).prefix(40))
                    found = slice.contains("task_started") || slice.contains("task_complete")
                        || slice.contains("turn_aborted") || slice.contains("user_message")
                        || slice.contains("token_count") || slice.contains("usage_limit")
                        || slice.contains("request_user_input") || slice.contains("reasoning")
                        || slice.contains("function_call") || slice.contains("custom_tool_call")
                        || slice.contains("timestamp")
                    index += 1
                }
                return found
            } ?? true
            if hits {
                keptLines += 1
                _ = try? decoder.decode(Event.self, from: String(line).data(using: .utf8)!)
            }
        }
        lineStart = content.index(after: lineEnd)
    }
}
print("optimized: \(keptLines) lines kept of \(currentLines), \(String(format: "%.3f", now() - t1))s, \(scannedBytes / 1024) KB scanned")