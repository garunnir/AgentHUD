import Foundation

// Measures the cost of the Codex scan steps so the slow path can be identified.
let sessionsRoot = NSString(string: "\(NSHomeDirectory())/.codex/sessions").expandingTildeInPath

func now() -> Double { Date().timeIntervalSinceReferenceDate }

let t0 = now()
let files = try! FileManager.default.subpathsOfDirectory(atPath: sessionsRoot).filter { $0.hasSuffix(".jsonl") }
let t1 = now()
print("enumerate: \(files.count) files in \(String(format: "%.3f", t1 - t0))s")

var statTime = 0.0
for relative in files {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    let s = now()
    _ = try? FileManager.default.attributesOfItem(atPath: path)
    statTime += now() - s
}
print("attributesOfItem x\(files.count): \(String(format: "%.3f", statTime))s")

// First line: current implementation reads a 256 KB prefix and splits the whole thing.
func readFirstLineCurrent(_ path: String) -> String? {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? stream.close() }
    let chunk = try? stream.read(upToCount: 262144)
    guard let chunk = chunk, let content = String(data: chunk, encoding: .utf8) else { return nil }
    return content.components(separatedBy: "\n").first
}

let t2 = now()
var bytesPrefix = 0
for relative in files.prefix(200) {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    if let line = readFirstLineCurrent(path) { bytesPrefix += line.utf8.count }
}
print("readFirstLine (current, 200 files): \(String(format: "%.3f", now() - t2))s")

// First line: stop at the first newline instead of decoding a fixed prefix.
func readFirstLineFast(_ path: String) -> String? {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? stream.close() }
    var data = Data()
    while data.count < 65536, let chunk = try? stream.read(upToCount: 4096), !chunk.isEmpty {
        data.append(chunk)
        if data.contains(0x0A) { break }
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    return String(text.prefix { $0 != "\n" })
}

let t3 = now()
for relative in files.prefix(200) {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    _ = readFirstLineFast(path)
}
print("readFirstLine (stop at newline, 200 files): \(String(format: "%.3f", now() - t3))s")

// Tail scan: current implementation reads the last 256 KB of every file.
func readTailCurrent(_ path: String) -> String {
    guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
    defer { try? stream.close() }
    let length = (try? stream.seekToEnd()) ?? 0
    let offset = length > 262144 ? length - 262144 : 0
    try? stream.seek(toOffset: offset)
    guard let data = try? stream.readToEnd() else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

let t4 = now()
var tailBytes = 0
for relative in files.prefix(200) {
    let path = (sessionsRoot as NSString).appendingPathComponent(relative)
    tailBytes += readTailCurrent(path).utf8.count
}
print("readTail 256KB (200 files): \(String(format: "%.3f", now() - t4))s, avg \(tailBytes / 200) bytes")