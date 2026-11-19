import Foundation

public final class CodexProvider: IAgentProvider {
    public let agentType: AgentType = .codex
    public var watchRoots: [String] { [sessionsRoot] }

    public static let limitGrace: TimeInterval = 1800
    /// Completed/inactive sessions stay listed this long after their last event.
    private static let completionRetention: TimeInterval = 1800

    private let retainedParentIDs: () -> [String]
    private let sessionsRoot: String
    private let indexPath: String
    private var titles: [String: String] = [:]
    private var indexStamp: (length: Int64, modified: Date)?
    private var cache: [String: CachedSession] = [:]
    private var activeWindowTicks: Int64

    public init(home: String, activeWindow: TimeInterval = 3600, retainedParentIDs: @escaping () -> [String] = { [] }) {
        self.retainedParentIDs = retainedParentIDs
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
            let inode = attrs[.systemFileNumber] as? UInt64
            let fileModified = (attrs[.modificationDate] as? Date) ?? Date()

            // Fast path for old rollouts: skip the parse unless a usage-limit error is
            // waiting to be read. This keeps startup fast with thousands of files.
            if fileModified < cutoff, !tailContains(path, "usage_limit_exceeded") {
                cache.removeValue(forKey: path)
                continue
            }

            if let cached = cache[path], cached.inode == inode, cached.length == fileLength, cached.modified == fileModified {
                let now = Date()
                let age = now.timeIntervalSince(cached.session.lastActivityAt)
                let limitPending = cached.session.rateLimitResetAt.map { now < $0.addingTimeInterval(Self.limitGrace) } ?? false
                let limited = cached.session.rateLimitResetAt.map { $0 > now } ?? false

                if age <= Self.completionRetention || age <= activeWindow || limitPending {
                    var session = cached.session
                    session.sessionTitle = titles[session.id] ?? session.sessionTitle
                    session.state = limited ? .rateLimited : session.state
                    if age > 120 && [.working, .thinking].contains(session.state) { session.state = .unknown }
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
            guard let id else { continue }
            let sessionId = UUID(uuidString: id)?.uuidString.lowercased() ?? id
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
                parentSessionId: CodexFamily.parentID(payload, ownID: sessionId),
                rateLimitResetAt: nil,
                tokens5h: 0,
                tokensWeek: 0,
                primaryLimit: nil,
                secondaryLimit: nil,
                limitsUpdatedAt: nil
            )

            session.isSubagent = CodexFamily.isChild(payload)
            if session.isChildSession { session.sessionTitle = titles[session.id] ?? payload["agent_nickname"] as? String ?? payload["agent_path"] as? String }

            var pendingQuestion: String?
            var pendingAsyncQuestions: [String?: IndexSet] = [:]
            var rateLimitReset: Date?
            var limitWindowReset: Date?
            var resumeOffset: Int64?
            if let previous = cache[path], previous.inode == inode, previous.session.id == session.id, fileLength > previous.length {
                resumeOffset = previous.readOffset
                session = previous.session
                pendingQuestion = previous.pendingQuestion
                pendingAsyncQuestions = previous.pendingAsyncQuestions
                rateLimitReset = previous.session.rateLimitResetAt
                limitWindowReset = previous.limitWindowReset
            }

            // On cold discovery use the recent tail. On growth resume at the last full
            // record so a large tool result cannot push an answer out of the next poll.
            guard let stream = fopen(path, "r") else { continue }
            defer { fclose(stream) }
            var readOffset = resumeOffset ?? max(0, fileLength - 262144)
            guard fseeko(stream, max(0, readOffset - 1), SEEK_SET) == 0 else { continue }
            var partial = readOffset > 0 && fgetc(stream) != 10
            var buffer: UnsafeMutablePointer<CChar>?
            var capacity = 0
            defer { free(buffer) }
            while readOffset < fileLength {
                let size = getline(&buffer, &capacity, stream)
                guard size > 0, let buffer, buffer[size - 1] == 10, Int64(size) <= fileLength - readOffset else { break }
                readOffset += Int64(size)
                if partial { partial = false; continue }
                let data = Data(bytesNoCopy: buffer, count: size, deallocator: .none)
                guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                guard let timestamp = parseDate(entry["timestamp"] as? String) else { continue }
                guard timestamp >= session.lastActivityAt else { continue }

                session.lastActivityAt = timestamp
                guard let body = entry["payload"] as? [String: Any] else { continue }
                let type = entry["type"] as? String ?? ""
                let bodyType = body["type"] as? String ?? ""
                let kind = (type, bodyType)

                if kind == ("event_msg", "token_count") {
                    limitWindowReset = exhaustedWindowReset(body) ?? limitWindowReset
                    let primary = parseWindow(body, "primary")
                    let secondary = parseWindow(body, "secondary")
                    if primary != nil || secondary != nil {
                        session.primaryLimit = primary
                        session.secondaryLimit = secondary
                        session.limitsUpdatedAt = timestamp
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

                let isCall = kind == ("response_item", "function_call") || kind == ("response_item", "custom_tool_call")
                let isOutput = kind == ("response_item", "function_call_output") || kind == ("response_item", "custom_tool_call_output")
                let isQuestion = isCall
                    && (body["name"] as? String == "request_user_input" || body["name"] as? String == "functions.request_user_input")
                let isAsyncQuestion = isCall
                    && (body["name"] as? String == "request_user_input_async" || body["name"] as? String == "functions.request_user_input_async")
                let isAnswer = isOutput
                    && pendingQuestion != nil && body["call_id"] as? String == pendingQuestion

                let finalReply = kind == ("response_item", "message") && body["role"] as? String == "assistant"
                    && body["phase"] as? String == "final_answer"
                if type == "turn_context", let turn = body["turn_id"] as? String { session.currentTurnID = turn }
                if finalReply { session.localCompletionRevision = "codex-end:\(timestamp.timeIntervalSince1970)" }
                var state = session.state
                switch kind {
                case ("event_msg", "task_started"), ("event_msg", "user_message"):
                    state = .working
                    session.completionRevision = nil
                    session.localCompletionRevision = nil
                    if bodyType == "task_started" { session.currentTurnID = body["turn_id"] as? String }
                case _ where kind == ("event_msg", "task_complete") || finalReply:
                    state = .completed
                    session.currentTurnID = body["turn_id"] as? String ?? session.currentTurnID
                    session.completionRevision = session.currentTurnID.map { "turn:\($0)" } ?? "codex-end:\(timestamp.timeIntervalSince1970)"
                case ("event_msg", "turn_aborted"):
                    state = .stopped
                    session.completionRevision = nil
                    session.localCompletionRevision = nil
                case ("response_item", "reasoning"): state = .thinking
                case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"): state = .working
                default: break
                }
                if isQuestion {
                    pendingQuestion = body["call_id"] as? String
                    state = .waitingForInput
                } else if isAnswer {
                    pendingQuestion = nil
                    state = .working
                } else if kind == ("event_msg", "task_started") || kind == ("event_msg", "user_message")
                    || kind == ("event_msg", "task_complete") || finalReply || kind == ("event_msg", "turn_aborted") {
                    pendingQuestion = nil
                }
                // Requesting escalation is not proof that a human approval is pending.
                if isAsyncQuestion {
                    let id = body["call_id"] as? String
                    let arguments = (body["arguments"] ?? body["input"]) as? String
                    let questions = arguments.flatMap { try? JSONDecoder().decode(AsyncQuestionArguments.self, from: Data($0.utf8)) }
                    pendingAsyncQuestions[id] = IndexSet(integersIn: 0..<max(1, questions?.questions.count ?? 1))
                }
                if !pendingAsyncQuestions.isEmpty {
                    if kind == ("response_item", "message"), body["role"] as? String == "user" {
                        for block in body["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "input_text" {
                            if let text = block["text"] as? String { Self.applyAsyncReply(text, to: &pendingAsyncQuestions) }
                        }
                    } else if kind == ("event_msg", "user_message") {
                        if let text = body["message"] as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Self.replyTag) {
                            Self.applyAsyncReply(text, to: &pendingAsyncQuestions)
                        } else {
                            pendingAsyncQuestions[nil] = nil // Only legacy requests without a call ID.
                        }
                    } else if kind == ("event_msg", "turn_aborted") {
                        pendingAsyncQuestions.removeAll()
                    }
                }
                if pendingQuestion != nil { state = .waitingForInput }
                session.needsInput = !pendingAsyncQuestions.isEmpty || pendingQuestion != nil

                session.state = state
                session.rateLimitResetAt = rateLimitReset
            }

            if session.lastActivityAt == .distantPast {
                session.lastActivityAt = fileModified
            }

            cache[path] = CachedSession(length: fileLength, inode: inode, readOffset: readOffset, modified: fileModified, session: session, pendingQuestion: pendingQuestion, pendingAsyncQuestions: pendingAsyncQuestions, limitWindowReset: limitWindowReset)

            session.sessionTitle = titles[session.id] ?? session.sessionTitle
            let now = Date()
            let age = now.timeIntervalSince(session.lastActivityAt)
            let limitPending = session.rateLimitResetAt.map { now < $0.addingTimeInterval(Self.limitGrace) } ?? false
            let limited = session.rateLimitResetAt.map { $0 > now } ?? false

            if age <= Self.completionRetention || age <= activeWindow || limitPending {
                session.state = limited ? .rateLimited : session.state
                session.isActive = limitPending || (session.state != .stopped && age <= activeWindow)
                if age > 120 && [.working, .thinking].contains(session.state) { session.state = .unknown }
            result.append(session)
            }
        }

        for path in cache.keys where !seen.contains(path) {
            cache.removeValue(forKey: path)
        }
        // A live child can outlast its parent's time window. Restore only the parent's
        // session_meta context (no historical transcript/activity/usage is replayed).
        var known = Set(result.map(\.id))
        var pending = result.compactMap(\.parentSessionId) + retainedParentIDs()
        var attempted = Set<String>()
        while !pending.isEmpty && attempted.count < 64 {
            let parentID = pending.removeLast()
            guard !known.contains(parentID), attempted.insert(parentID).inserted,
                  parentID.hasPrefix("codex:") else { continue }
            let raw = String(parentID.dropFirst(6))
            guard UUID(uuidString: raw) != nil,
                  let relative = files.first(where: { $0.lowercased().hasSuffix(raw.lowercased() + ".jsonl") }),
                  let line = try? readFirstLine((sessionsRoot as NSString).appendingPathComponent(relative)),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
                  (payload["id"] as? String ?? payload["session_id"] as? String)?.lowercased() == raw.lowercased() else { continue }
            var context = AgentSession(id: parentID, agentType: .codex, state: .unknown,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: nil,
                projectPath: payload["cwd"] as? String, worktreePath: nil,
                sessionTitle: titles[parentID] ?? payload["agent_nickname"] as? String,
                currentTask: nil, startedAt: .distantPast, lastActivityAt: .distantPast, isActive: false,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: CodexFamily.parentID(payload, ownID: raw),
                rateLimitResetAt: nil, tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
            context.isSubagent = CodexFamily.isChild(payload)
            context.isAncestorContext = true
            known.insert(parentID); result.append(context)
            if let next = context.parentSessionId { pending.append(next) }
        }
        return result
    }

    private struct AsyncQuestionArguments: Decodable {
        struct Question: Decodable {}
        let questions: [Question]
    }

    private static let replyTag = "<send_user_message_question_reply>"

    // Codex Desktop serializes each questionItemId as a JSON tuple inside its answer envelope.
    private static func applyAsyncReply(_ text: String, to pending: inout [String?: IndexSet]) {
        let end = "</send_user_message_question_reply>"
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.hasPrefix(replyTag), message.hasSuffix(end) else { return }
        let json = message.dropFirst(replyTag.count).dropLast(end.count)
        guard let replies = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return }
        for reply in replies {
            guard reply["answer"] is String, let raw = reply["questionItemId"] as? String,
                  let key = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any], key.count == 3,
                  key[0] as? String == "request_user_input_async", let call = key[1] as? String,
                  let index = key[2] as? Int, index >= 0, pending[call]?.contains(index) == true else { continue }
            pending[call]?.remove(index)
            if pending[call]?.isEmpty == true { pending[call] = nil }
        }
    }

    private struct CachedSession {
        let length: Int64
        let inode: UInt64?
        let readOffset: Int64
        let modified: Date
        let session: AgentSession
        let pendingQuestion: String?
        let pendingAsyncQuestions: [String?: IndexSet]
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
        let minutes = window["window_minutes"] as? Int
        return LimitWindow(
            usedPercent: used,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(resets)),
            windowMinutes: minutes
        )
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
            let canonical = UUID(uuidString: id)?.uuidString.lowercased() ?? id
            newTitles["codex:\(canonical)"] = title
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
