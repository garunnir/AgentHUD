import Foundation

// Replicates CodexProvider.discover() phase by phase (same file reads, same JSON
// parsing) so startup cost can be measured without launching the app.
let home = NSHomeDirectory()
let sessionsRoot = (home as NSString).appendingPathComponent(".codex/sessions")
let indexPath = (home as NSString).appendingPathComponent(".codex/session_index.jsonl")

func now() -> Double { Date().timeIntervalSinceReferenceDate }
func ms(_ d: Double) -> String { String(format: "%7.1f ms", d * 1000) }

// refreshTitles(): reads the whole session index on every scan.
var titles: [String: String] = [:]
var indexStamp: (length: Int64, modified: Date)?
func refreshTitles() {
    let s = now()
    guard FileManager.default.fileExists(atPath: indexPath) else { titles = [:]; indexStamp = nil; return }
    let attrs = try! FileManager.default.attributesOfItem(atPath: indexPath)
    let length = (attrs[.size] as? Int64) ?? 0
    let modified = (attrs[.modificationDate] as? Date) ?? Date()
    if let cur = indexStamp, cur.length == length, cur.modified == modified { return }
    guard let data = FileManager.default.contents(atPath: indexPath),
          let content = String(data: data, encoding: .utf8) else { return }
    var new: [String: String] = [:]
    for line in content.components(separatedBy: "\n") {
        guard let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = j["id"] as? String, let title = j["thread_name"] as? String else { continue }
        new["codex:\(id)"] = title
    }
    titles = new
    indexStamp = (length, modified)
    print("  refreshTitles (index changed): \(ms(now() - s))  entries=\(new.count)")
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

let tEnumerate = now()
let files = try! FileManager.default.subpathsOfDirectory(atPath: sessionsRoot).filter { $0.hasSuffix(".jsonl") }
print("enumerate:   \(files.count) files  \(ms(now() - tEnumerate))")

// Phase 1: stat + first line + session_meta JSON.
var metas: [(path: String, id: String, length: Int64, modified: Date)] = []
let tMeta = now()
for relative in files {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
    let length = (attrs[.size] as? Int64) ?? 0
    let modified = (attrs[.modificationDate] as? Date) ?? Date()
    guard let first = readFirstLine(path),
          let json = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
          json["type"] as? String == "session_meta",
          let payload = json["payload"] as? [String: Any],
          let id = payload["id"] as? String ?? payload["session_id"] as? String else { continue }
    metas.append((path, id, length, modified))
}
print("stat+meta:    \(metas.count) sessions  \(ms(now() - tMeta))")

// Phase 2: tail read + per-line JSON (what discover() then does).
let tTail = now()
var lines = 0
var bytes = 0
for meta in metas {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: meta.path)) else { continue }
    defer { try? stream.close() }
    let length = (try? stream.seekToEnd()) ?? 0
    let offset = length > 262144 ? length - 262144 : 0
    try? stream.seek(toOffset: offset)
    guard let data = try? stream.readToEnd() else { continue }
    var content = String(data: data, encoding: .utf8) ?? ""
    if offset > 0, let nl = content.firstIndex(of: "\n") { content = String(content[content.index(after: nl)...]) }
    bytes += content.utf8.count
    for line in content.components(separatedBy: "\n").dropLast() {
        lines += 1
        guard let d = line.data(using: .utf8) else { continue }
        _ = try? JSONSerialization.jsonObject(with: d)
    }
}
print("tail+parse:   \(lines) lines, \(bytes / 1024 / 1024) MB  \(ms(now() - tTail))")

// Phase 3: warm scan (everything cached by length+mtime).
let tWarm = now()
var cachedHits = 0
for meta in metas {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: meta.path) else { continue }
    let length = (attrs[.size] as? Int64) ?? 0
    let modified = (attrs[.modificationDate] as? Date) ?? Date()
    if length == meta.length && modified == meta.modified { cachedHits += 1 }
}
print("warm (stat):  \(cachedHits) hits  \(ms(now() - tWarm))")
print("session_index.jsonl size: \((try! FileManager.default.attributesOfItem(atPath: indexPath)[.size] as? Int64 ?? 0) / 1024) KB")