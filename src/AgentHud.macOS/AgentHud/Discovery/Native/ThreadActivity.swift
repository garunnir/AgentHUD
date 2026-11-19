import Foundation
import Darwin

public enum ThreadActivity: String, Sendable {
    case unknown, running, needsReview, unread, failed, interrupted
    public var label: String {
        switch self {
        case .unknown: ""
        case .running: "작업 중"
        case .needsReview: "완료 · 확인 필요"
        case .unread: "미확인 메시지"
        case .failed: "작업 실패"
        case .interrupted: "작업 중단"
        }
    }
    public func label(for app: AgentApp) -> String {
        if self == .needsReview && [.chatGPT, .claude].contains(app) { return "응답 종료 · 확인 필요" }
        return label
    }
}

public struct ActivityRecord: Codable, Sendable, Equatable {
    public let version: Int
    public let app: String
    public let sessionID: String
    public let state: String
    public let producer: String
    public let eventID: String
    public let sequence: Int
    public let timestamp: Double
    public let source: String?
    public let validUntil: Double?
    public let turnID: String?
    public var key: String { "\(app):\(sessionID)" }
}

public struct ActivityLedger: Sendable {
    public private(set) var records: [String: ActivityRecord] = [:]
    public private(set) var acknowledged: [String: String]
    public init(acknowledged: [String: String] = [:]) {
        self.acknowledged = Dictionary(acknowledged.map { ($0.key.contains(":") ? $0.key : "openCode:\($0.key)", $0.value) }, uniquingKeysWith: { _, new in new })
    }
    public func record(_ id: String, app: AgentApp = .openCode) -> ActivityRecord? { records["\(app.rawValue):\(id)"] }
    public mutating func apply(_ record: ActivityRecord) {
        if let old = records[record.key], old.sequence >= record.sequence { return }
        records[record.key] = record
    }
    public func completionRevision(_ id: String, app: AgentApp = .openCode) -> String? {
        guard let record = record(id, app: app), record.state == "completed" else { return nil }
        return record.eventID
    }
    public mutating func acknowledge(_ id: String, revision: String?, app: AgentApp = .openCode) {
        guard let revision, record(id, app: app)?.eventID == revision, record(id, app: app)?.state == "completed" else { return }
        acknowledged["\(app.rawValue):\(id)"] = revision
    }
    public func state(_ id: String, liveProducer: String?, app: AgentApp = .openCode) -> ThreadActivity {
        guard let record = record(id, app: app) else { return .unknown }
        switch record.state {
        case "running": return record.producer == liveProducer ? .running : .unknown
        case "completed": return acknowledged[record.key] == record.eventID ? .unknown : .needsReview
        case "failed": return .failed
        case "interrupted": return .interrupted
        default: return .unknown
        }
    }
}

public extension ThreadItem {
    var activitySessionID: String? {
        if case let .localCodex(id) = action { return id.uuidString.lowercased() }
        if app == .amp { return ThreadExtractor.ampSessionID(url) }
        if app == .claude, let url, let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "claude.ai" {
            let parts = parsed.pathComponents
            if parts.count == 3, parts[1] == "chat", ActivityFileStore.validSessionID(parts[2], app: .claude) { return parts[2].lowercased() }
        }
        guard app == .openCode, let url, let parsed = URL(string: url),
              parsed.scheme == "oc", parsed.host == "renderer", parsed.path.hasPrefix("/server/") else { return nil }
        let components = parsed.pathComponents
        guard let i = components.firstIndex(of: "session"), i + 2 == components.count else { return nil }
        let id = components[i + 1]
        return ActivityFileStore.validSessionID(id) ? id : nil
    }
}

public struct ActivityIdentity: Sendable {
    public let app: AgentApp
    public let sessionID: String
    public init(app: AgentApp, sessionID: String) { self.app = app; self.sessionID = sessionID }
}

public enum ActivityFileStore {

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Threaddeck/activity")
    }
    public static func validSessionID(_ id: String, app: AgentApp = .openCode) -> Bool {
        if app == .chatGPT || app == .claude { return id.count == 36 && UUID(uuidString: id) != nil }
        if app == .amp { return id.hasPrefix("T-") && id.count == 38 && UUID(uuidString: String(id.dropFirst(2))) != nil }
        guard app == .openCode else { return false }
        return id.hasPrefix("ses_") && (5...104).contains(id.utf8.count) && id.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    public static func decode(_ data: Data, sessionID: String, app: AgentApp = .openCode, now: Date = Date()) throws -> ActivityRecord {
        guard data.count <= 4096 else { throw ActivityFileError.unsafeFile }
        let record = try JSONDecoder().decode(ActivityRecord.self, from: data)
        guard record.version == 1, record.app == app.rawValue, validSessionID(sessionID, app: app), record.sessionID == sessionID,
              ["running", "completed", "failed", "interrupted"].contains(record.state),
              UUID(uuidString: record.producer) != nil, !record.eventID.isEmpty, record.eventID.utf8.count <= 150,
              record.sequence >= 0, record.timestamp.isFinite, record.timestamp > 0,
              record.timestamp <= now.timeIntervalSince1970 * 1000 + 5000 else { throw ActivityFileError.unsafeFile }
        if record.source == "hook" {
            guard [.chatGPT, .claude].contains(app), let until = record.validUntil, until.isFinite,
                  until >= record.timestamp, until <= record.timestamp + 120_000 else { throw ActivityFileError.unsafeFile }
        } else {
            guard record.source == nil, [.openCode, .amp].contains(app) else { throw ActivityFileError.unsafeFile }
        }
        return record
    }

    // Only known navigation IDs are read. Never enumerate source application data or parse conversation text.
    public static func read(ids: [String], root: URL = defaultURL, now: Date = Date()) -> (records: [ActivityRecord], liveProducers: Set<String>) {
        read(identities: ids.map { ActivityIdentity(app: .openCode, sessionID: $0) }, root: root, now: now)
    }
    public static func read(identities: [ActivityIdentity], root: URL = defaultURL, now: Date = Date()) -> (records: [ActivityRecord], liveProducers: Set<String>) {

        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return ([], []) }
        defer { close(directory) }
        var attributes = stat()
        guard fstat(directory, &attributes) == 0, attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else { return ([], []) }
        struct Heartbeat: Decodable { let version: Int; let app: String; let producer: String; let timestamp: Double }
        let records = identities.prefix(1000).compactMap { identity -> ActivityRecord? in
            let id = identity.sessionID; let app = identity.app
            guard validSessionID(id, app: app), let data = readFile("\(app.rawValue)-\(id).json", directory: directory) else { return nil }
            return try? decode(data, sessionID: id, app: app, now: now)
        }
        var live = Set<String>()
        for record in records {
            let producer = record.producer
            if record.source == "hook" {
                if let until = record.validUntil, until > now.timeIntervalSince1970 * 1000 { live.insert(producer) }
                continue
            }
            if let data = readFile("\(record.app)-heartbeat-\(producer).json", directory: directory),
               let heartbeat = try? JSONDecoder().decode(Heartbeat.self, from: data), heartbeat.version == 1,
               heartbeat.app == record.app, heartbeat.producer == producer {
                let age = now.timeIntervalSince1970 * 1000 - heartbeat.timestamp
                if age >= -5000 && age < 10_000 { live.insert(producer) }
            }
        }
        return (records, live)

    }
    private static func readFile(_ name: String, directory: Int32) -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0,
              attributes.st_size > 0, attributes.st_size <= 4096 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return data
    }
}

enum ActivityFileError: Error { case unsafeFile }
