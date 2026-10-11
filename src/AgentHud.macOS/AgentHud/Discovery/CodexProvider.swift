import Foundation

public final class CodexProvider: IAgentProvider {
    public let agentType: AgentType = .codex
    public var watchRoots: [String] { [sessionsRoot] }

    public static let limitGrace: TimeInterval = 1800
    /// Completed/inactive sessions stay listed this long after their last event.
    private static let completionRetention: TimeInterval = 1800

    private let sessionsRoot: String
    private let indexPath: String
    private var titles: [String: String] = [:]
    private var indexStamp: (length: Int64, modified: Date)?
    private var cache: [String: CachedSession] = [:]
    private var activeWindowTicks: Int64

    public init(home: String, activeWindow: TimeInterval = 3600) {
        sessionsRoot = (home as NSString).appendingPathComponent(".codex/sessions")
        indexPath = (home as NSString).appendingPathComponent(".codex/session_index.jsonl")
        activeWindowTicks = Int64(activeWindow * 1_000_000)
    }

    public func setActiveWindow(_ seconds: Double) {
        activeWindowTicks = Int64(seconds * 1_000_000)
    }

    public var activeWindow: TimeInterval {
        Double(activeWindowTicks) / 1_000_000
    }

    public func discover() async throws -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: sessionsRoot) else { return [] }
        await refreshTitles()

        var result: [AgentSession] = []
        var seen = Set<String>()

        let files = try FileManager.default.subpathsOfDirectory(atPath: sessionsRoot)
            .filter { $0.hasSuffix(".jsonl") }

        // Anything untouched for longer than the retention window can only be listed
        // while it waits for a usage-limit reset, so older rollout files skip the full
        // parse after a cheap marker check instead of reading hundreds of KB each.
        let cutoff = Date().addingTimeInterval(-max(activeWindow, Self.completionRetention))

        for relative in files {
            let path = (sessionsRoot as NSString).appendingPathComponent(relative)
            seen.insert(path)

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let fileLength = (attrs[.size] as? Int64) ?? 0
            let fileModified = (attrs[.modificationDate] as? Date) ?? Date()

            // Fast path for old rollouts: skip the parse unless a usage-limit error is
            // waiting to be read. This keeps startup fast with thousands of files.
            if fileModified < cutoff, !tailContains(path, "usage_limit_exceeded") {
                cache.removeValue(forKey: path)
                continue
            }

            if var cached = cache[path], cached.length == fileLength, cached.modified == fileModified {
                let now = Date()
                let age = now.timeIntervalSince(cached.session.lastActivityAt)
                let limitPending = cached.session.rateLimitResetAt.map { now < $0.addingTimeInterval(Self.limitGrace) } ?? false
                let limited = cached.session.rateLimitResetAt.map { $0 > now } ?? false

                if age <= Self.completionRetention || age <= activeWindow || limitPending {
                    var session = cached.session
                    session.sessionTitle = titles[session.id]
                    session.state = limited ? .rateLimited : session.state
                    session.isActive = limitPending || (session.state != .stopped && age <= activeWindow)
                    result.append(session)
                }
                continue
            }

            guard let firstLine = try? readFirstLine(path) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any] else { continue }

            if let source = payload["source"] as? [String: Any],
               let subagent = source["subagent"] as? [String: Any],
               subagent["other"] as? String == "guardian" { continue }

            let id = (payload["id"] as? String) ?? (payload["session_id"] as? String)
            guard let sessionId = id else { continue }
            let cwd = payload["cwd"] as? String

            var session = AgentSession(
                id: "codex:\(sessionId)",
                agentType: .codex,
                state: .unknown,
                hasUnreadCompletion: false,
                completionDetectedAt: nil,
                processId: nil,
                projectPath: cwd,
                worktreePath: findGitRoot(cwd),
                sessionTitle: titles["codex:\(sessionId)"],
                currentTask: nil,
                startedAt: parseDate(payload["timestamp"] as? String) ?? fileCreationDate(path),
                lastActivityAt: parseDate(json["timestamp"] as? String) ?? parseDate(payload["timestamp"] as? String) ?? Date.distantPast,
                isActive: false,
                wakeupAt: nil,
                hasBackgroundTasks: false,
                parentSessionId: (payload["parent_thread_id"] as? String).map { "codex:\($0)" },
                rateLimitResetAt: nil,
                tokens5h: 0,
                tokensWeek: 0,
                primaryLimit: nil,
                secondaryLimit: nil
            )

            var pendingQuestion: String?
            var pendingAsyncQuestion = false
            var rateLimitReset: Date?
            var limitWindowReset: Date?

            guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
            defer { try? stream.close() }

            // Read only the tail (256 KB); when the offset is inside a line, drop the partial first line.
            let streamLength = (try? stream.seekToEnd()) ?? 0
            let offset = streamLength > 262144 ? streamLength - 262144 : 0
            try? stream.seek(toOffset: offset)
            guard let data = try? stream.readToEnd() else { continue }
            var content = String(data: data, encoding: .utf8) ?? ""
            if offset > 0, let newline = content.firstIndex(of: "\n") {
                content = String(content[content.index(after: newline)...])
            }
            let tail = content

            for line in tail.components(separatedBy: "\n").dropLast() {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                guard let timestamp = parseDate(entry["timestamp"] as? String) else { continue }
                guard timestamp >= session.lastActivityAt else { continue }

                session.lastActivityAt = timestamp
                guard let body = entry["payload"] as? [String: Any] else { continue }
                let type = entry["type"] as? String ?? ""
                let bodyType = body["type"] as? String ?? ""
                let kind = (type, bodyType)

                if kind == ("event_msg", "token_count") {
                    limitWindowReset = exhaustedWindowReset(body) ?? limitWindowReset
                    if let primary = parseWindow(body, "primary") {
                        session.primaryLimit = primary
                        session.secondaryLimit = parseWindow(body, "secondary") ?? session.secondaryLimit
                    }
                }
                if kind == ("event_msg", "task_started") || kind == ("event_msg", "user_message") {
                    rateLimitReset = nil
                }
                if kind.0 == "event_msg", let limitMessage = usageLimitMessage(body) {
                    rateLimitReset = RateLimitParser.parseReset(limitMessage, at: timestamp)
                        ?? (limitWindowReset.map { $0 > timestamp ? $0 : nil } ?? nil)
                        ?? timestamp.addingTimeInterval(RateLimitParser.fallbackDelay)
                }

                let isQuestion = kind == ("response_item", "function_call") || kind == ("response_item", "custom_tool_call")
                    && (body["name"] as? String == "request_user_input" || body["name"] as? String == "functions.request_user_input")
                let isAsyncQuestion = kind == ("response_item", "function_call") || kind == ("response_item", "custom_tool_call")
                    && (body["name"] as? String == "request_user_input_async" || body["name"] as? String == "functions.request_user_input_async")
                let isAnswer = kind == ("response_item", "function_call_output") || kind == ("response_item", "custom_tool_call_output")
                    && pendingQuestion != nil && body["call_id"] as? String == pendingQuestion

                var state = session.state
                switch kind {
                case ("event_msg", "task_started"), ("event_msg", "user_message"): state = .working
                case ("event_msg", "task_complete"): state = .idle
                case ("event_msg", "turn_aborted"): state = .stopped
                case ("response_item", "reasoning"): state = .thinking
                case ("response_item", "function_call"), ("response_item", "custom_tool_call"): state = .working
                default: break
                }
                if isQuestion {
                    pendingQuestion = body["call_id"] as? String
                    state = .waitingForInput
                } else if isAnswer {
                    pendingQuestion = nil
                    state = .working
                } else if kind == ("event_msg", "task_started") || kind == ("event_msg", "user_message")
                    || kind == ("event_msg", "task_complete") || kind == ("event_msg", "turn_aborted") {
                    pendingQuestion = nil
                }
                if isAsyncQuestion { pendingAsyncQuestion = true }
                if kind == ("event_msg", "user_message") || kind == ("event_msg", "turn_aborted") { pendingAsyncQuestion = false }
                if pendingAsyncQuestion { state = .waitingForInput }

                session.state = state
                session.rateLimitResetAt = rateLimitReset
            }

            if session.lastActivityAt == .distantPast {
                session.lastActivityAt = fileModified
            }

            cache[path] = CachedSession(length: fileLength, modified: fileModified, session: session, pendingQuestion: pendingQuestion, pendingAsyncQuestion: pendingAsyncQuestion, limitWindowReset: limitWindowReset)

            let now = Date()
            let age = now.timeIntervalSince(session.lastActivityAt)
            let limitPending = session.rateLimitResetAt.map { now < $0.addingTimeInterval(Self.limitGrace) } ?? false
            let limited = session.rateLimitResetAt.map { $0 > now } ?? false

            if age <= Self.completionRetention || age <= activeWindow || limitPending {
                session.state = limited ? .rateLimited : session.state
                session.isActive = limitPending || (session.state != .stopped && age <= activeWindow)
                result.append(session)
            }
        }

        for path in cache.keys where !seen.contains(path) {
            cache.removeValue(forKey: path)
        }
        return result
    }

    private struct CachedSession {
        let length: Int64
        let modified: Date
        let session: AgentSession
        let pendingQuestion: String?
        let pendingAsyncQuestion: Bool
        let limitWindowReset: Date?
    }

    private func usageLimitMessage(_ body: [String: Any]) -> String? {
        let error = body["error"] as? [String: Any] ?? body
        return error["codex_error_info"] as? String == "usage_limit_exceeded" ? error["message"] as? String ?? "" : nil
    }

    private func exhaustedWindowReset(_ body: [String: Any]) -> Date? {
        guard let limits = body["rate_limits"] as? [String: Any] else { return nil }
        var latest: Date?
        for name in ["primary", "secondary"] {
            guard let window = limits[name] as? [String: Any] else { continue }
            guard let used = window["used_percent"] as? Double, used >= 100 else { continue }
            guard let resets = window["resets_at"] as? Int64 else { continue }
            let time = Date(timeIntervalSince1970: TimeInterval(resets))
            if latest == nil || time > latest! { latest = time }
        }
        return latest
    }

    private func parseWindow(_ body: [String: Any], _ name: String) -> LimitWindow? {
        guard let limits = body["rate_limits"] as? [String: Any] else { return nil }
        guard let window = limits[name] as? [String: Any] else { return nil }
        guard let used = window["used_percent"] as? Double else { return nil }
        guard let resets = window["resets_at"] as? Int64 else { return nil }
        return LimitWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: TimeInterval(resets)))
    }

    /// Reads only the last few KB of a rollout file to look for a marker.
    private func tailContains(_ path: String, _ needle: String, maxBytes: Int = 8192) -> Bool {
        guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? stream.close() }
        let length = (try? stream.seekToEnd()) ?? 0
        guard length > 0 else { return false }
        let offset = length > UInt64(maxBytes) ? length - UInt64(maxBytes) : 0
        try? stream.seek(toOffset: offset)
        guard let data = try? stream.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(needle)
    }

    private func readFirstLine(_ path: String) throws -> String? {
        guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? stream.close() }
        // Stop at the first newline; decoding a fixed prefix would read ~256 KB per
        // file, which dominates the scan across thousands of rollout files.
        var data = Data()
        while data.count < 262144 {
            guard let chunk = try? stream.read(upToCount: 8192), !chunk.isEmpty else { break }
            data.append(chunk)
            if data.contains(0x0A) { break }
        }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        return String(content.prefix { $0 != "\n" })
    }

    private func refreshTitles() async {
        guard FileManager.default.fileExists(atPath: indexPath) else { titles = [:]; indexStamp = nil; return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: indexPath) else { return }
        let length = (attrs[.size] as? Int64) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date()
        let stamp = (length, modified)
        if let current = indexStamp, current.length == length, current.modified == modified { return }

        var newTitles: [String: String] = [:]
        guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: indexPath)),
              let data = try? stream.readToEnd(),
              let content = String(data: data, encoding: .utf8) else { return }
        try? stream.close()

        for line in content.components(separatedBy: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = json["id"] as? String, let title = json["thread_name"] as? String else { continue }
            newTitles["codex:\(id)"] = title
        }
        titles = newTitles
        indexStamp = stamp
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value = value else { return nil }
        // Remove trailing "Z" and parse as UTC explicitly
        let normalized = value.hasSuffix("Z") ? String(value.dropLast()) : value
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: normalized) { return date }
        // Fallback: without fractional seconds
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = formatter.date(from: normalized) { return date }
        print("CodexProvider: parseDate failed for '\(value)' normalized='\(normalized)'")
        return nil
    }

    private func fileCreationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? Date()
    }

    private func findGitRoot(_ path: String?) -> String? {
        guard let path = path else { return nil }
        var url = URL(fileURLWithPath: path)
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}
