import Foundation

public final class ClaudeCodeProvider: IAgentProvider {
    public let agentType: AgentType = .claudeCode
    public var watchRoots: [String] { [sessionsRoot, projectsRoot] }

    /// Usage is summed over the last 7 days, so older transcript events never count.
    private static let usageWindow: TimeInterval = 7 * 86400

    private let sessionsRoot: String
    private let projectsRoot: String
    private var activeWindow: TimeInterval
    private var transcripts: [String: (length: Int64, modified: Date, info: TranscriptInfo)] = [:]

    public init(home: String, activeWindow: TimeInterval = 3600) {
        sessionsRoot = (home as NSString).appendingPathComponent(".claude/sessions")
        projectsRoot = (home as NSString).appendingPathComponent(".claude/projects")
        self.activeWindow = activeWindow
    }

    public func setActiveWindow(_ value: TimeInterval) {
        activeWindow = max(60, value)
    }

    public func discover() async throws -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: sessionsRoot) else { return [] }

        let processes = ProcessHelper.allPIDs()
        var result: [AgentSession] = []

        let files = try FileManager.default.contentsOfDirectory(atPath: sessionsRoot)
            .filter { $0.hasSuffix(".json") }

        for file in files {
            let path = (sessionsRoot as NSString).appendingPathComponent(file)
            guard let stream = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
            defer { try? stream.close() }

            let data = try? stream.readToEnd()
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let pid = json["pid"] as? Int32, pid > 0 else { continue }

            let alive = processes.contains(pid)
            let updatedAt = parseDate(json["updatedAt"]) ?? fileModificationDate(path)
            let state = alive ? mapState(json["status"] as? String, activity: updatedAt) : .stopped
            let recentlyActive = Date().timeIntervalSince(updatedAt) <= activeWindow

            if json["entrypoint"] as? String == "claude-vscode" && state == .idle
                && UUID(uuidString: sessionId) != nil && !hasTranscript(sessionId) { continue }

            let transcript = transcriptIsStale(sessionId)
                ? TranscriptInfo()
                : try await readTranscript(sessionId)
            var finalState = state
            if alive && transcript.hasPendingQuestion
                && state != AgentState.error && state != AgentState.stopped && state != AgentState.waitingForApproval {
                finalState = .waitingForInput
            }

            let wakeupAt = alive ? transcript.wakeupAt : nil
            let hasBackground = alive && (transcript.backgroundSince?.timeIntervalSinceNow ?? 0) > -3600

            if finalState == .idle && (transcript.midTurn || hasBackground || (wakeupAt?.timeIntervalSinceNow ?? 0) > 0) {
                finalState = .working
            }
            if alive && (transcript.rateLimitResetAt?.timeIntervalSinceNow ?? 0) > 0
                && state != AgentState.stopped && state != AgentState.waitingForApproval {
                finalState = .rateLimited
            }

            let session = AgentSession(
                id: "claude:\(sessionId)",
                agentType: .claudeCode,
                state: finalState,
                hasUnreadCompletion: false,
                completionDetectedAt: nil,
                processId: Int(pid),
                projectPath: json["cwd"] as? String,
                worktreePath: findGitRoot(json["cwd"] as? String),
                sessionTitle: transcript.title ?? json["name"] as? String,
                currentTask: nil,
                startedAt: parseDate(json["startedAt"]) ?? fileCreationDate(path),
                lastActivityAt: updatedAt,
                isActive: alive && recentlyActive,
                wakeupAt: wakeupAt,
                hasBackgroundTasks: hasBackground,
                parentSessionId: nil,
                rateLimitResetAt: transcript.rateLimitResetAt,
                tokens5h: transcript.usage?.filter { $0.at > Date().addingTimeInterval(-18000) }.reduce(0) { $0 + $1.tokens } ?? 0,
                tokensWeek: transcript.usage?.reduce(0) { $0 + $1.tokens } ?? 0,
                primaryLimit: nil,
                secondaryLimit: nil,
                limitsUpdatedAt: nil
            )
            result.append(session)
        }
        return result
    }

    private func hasTranscript(_ sessionId: String) -> Bool {
        guard FileManager.default.fileExists(atPath: projectsRoot) else { return false }
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else { return false }
        return projects.contains { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("\(sessionId).jsonl")) }
    }

    /// True when the transcript has not been touched since before the usage window,
    /// so reading it could only surface events older than the window.
    private func transcriptIsStale(_ sessionId: String) -> Bool {
        // Transcript mtimes below the usage window can only hold events that are already
        // older than the 7-day window, so they add nothing to any session.
        let cutoff = Date().addingTimeInterval(-Self.usageWindow)
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else { return true }
        for project in projects {
            let path = (project as NSString).appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            return fileModificationDate(path) < cutoff
        }
        return true
    }

    private struct TranscriptInfo {
        var title: String?
        var hasPendingQuestion: Bool = false
        var rateLimitResetAt: Date?
        var usage: [(at: Date, tokens: Int64)]?
        var midTurn: Bool = false
        var wakeupAt: Date?
        var backgroundSince: Date?
    }

    private func readTranscript(_ sessionId: String) async throws -> TranscriptInfo {
        guard UUID(uuidString: sessionId) != nil,
              FileManager.default.fileExists(atPath: projectsRoot) else { return TranscriptInfo() }

        let projects = try FileManager.default.contentsOfDirectory(atPath: projectsRoot)
        for project in projects {
            let path = (project as NSString).appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: path) else { continue }

            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let length = (attrs[.size] as? Int64) ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()

            if let cached = transcripts[path], cached.length == length, cached.modified == modified {
                return cached.info
            }

            var info = TranscriptInfo()
            var aiTitle: String?
            var customTitle: String?
            var rateLimitReset: Date?
            var midTurn = false
            var wakeupAt: Date?
            var background: [String: Date] = [:]
            var backgroundCalls: Set<String> = []
            var pendingQuestions: Set<String> = []
            var usage: [String: (at: Date, tokens: Int64)] = [:]

            guard let stream = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? stream.close() }

            let data = try? stream.readToEnd()
            guard let data = data, let content = String(data: data, encoding: .utf8) else { continue }

            for line in content.components(separatedBy: "\n") {
                if line.contains("\"isApiErrorMessage\":true") {
                    rateLimitReset = parseRateLimit(line, sessionId: sessionId)
                    continue
                }
                if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                    rateLimitReset = nil
                }
                if !line.contains("\"isSidechain\":true") {
                    if line.contains("\"type\":\"assistant\"") {
                        midTurn = !line.contains("\"stop_reason\":\"end_turn\"")
                    } else if line.contains("\"type\":\"user\"") {
                        midTurn = line.contains("\"tool_result\"")
                        if !midTurn { wakeupAt = nil }
                    } else if line.contains("\"subtype\":\"turn_duration\"") {
                        midTurn = false
                    }
                }
                if line.contains("\"usage\":{") && line.contains("\"type\":\"assistant\"") {
                    addUsage(&usage, line)
                }
                if !line.contains("\"aiTitle\"") && !line.contains("\"customTitle\"")
                    && !line.contains("\"tool_use\"") && !line.contains("\"tool_result\"")
                    && !line.contains("task-notification") { continue }

                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["sessionId"] as? String == sessionId,
                      let type = json["type"] as? String else { continue }

                let sidechain = json["isSidechain"] as? Bool ?? false
                if !sidechain && type == "user",
                   let message = json["message"] as? [String: Any],
                   let userContent = message["content"] {
                    trackBackground(&background, &backgroundCalls, json: json, content: userContent)
                }
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if !sidechain && type == "assistant", block["type"] as? String == "tool_use",
                           isBackgroundCall(block), let callId = block["id"] as? String {
                            backgroundCalls.insert(callId)
                        }
                        if type == "assistant", block["type"] as? String == "tool_use",
                           block["name"] as? String == "AskUserQuestion", let questionId = block["id"] as? String {
                            pendingQuestions.insert(questionId)
                        } else if type == "assistant", block["type"] as? String == "tool_use",
                                  block["name"] as? String == "ScheduleWakeup" {
                            wakeupAt = parseWakeup(json, block)
                        } else if !sidechain && type == "assistant", block["type"] as? String == "tool_use",
                                  block["name"] as? String == "TaskStop",
                                  let stopInput = block["input"] as? [String: Any] {
                            for (_, value) in stopInput {
                                if let str = value as? String { background.removeValue(forKey: str) }
                            }
                        } else if type == "user", block["type"] as? String == "tool_result",
                                  let answeredId = block["tool_use_id"] as? String {
                            pendingQuestions.remove(answeredId)
                        }
                    }
                }
                if type == "ai-title", let title = json["aiTitle"] as? String { aiTitle = title }
                if type == "custom-title", let title = json["customTitle"] as? String { customTitle = title }
            }

            info.title = (customTitle?.isEmpty == false) ? customTitle : aiTitle
            info.hasPendingQuestion = !pendingQuestions.isEmpty
            info.rateLimitResetAt = rateLimitReset
            info.usage = usage.values.map { $0 }
            info.midTurn = midTurn
            info.wakeupAt = wakeupAt
            info.backgroundSince = background.values.max()
            transcripts[path] = (length, modified, info)
            return info
        }
        return TranscriptInfo()
    }

    private func addUsage(_ usage: inout [String: (at: Date, tokens: Int64)], _ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let u = message["usage"] as? [String: Any],
              let id = message["id"] as? String,
              let stamp = json["timestamp"] as? String,
              let at = ISO8601DateFormatter().date(from: stamp) else { return }
        let atUTC = at
        if Date().timeIntervalSince(atUTC) > 604800 { return }
        let tokens = (u["input_tokens"] as? Int64 ?? 0) + (u["output_tokens"] as? Int64 ?? 0) + (u["cache_creation_input_tokens"] as? Int64 ?? 0)
        usage[id] = (atUTC, tokens)
    }

    private func trackBackground(_ background: inout [String: Date], _ calls: inout Set<String>, json: [String: Any], content: Any) {
        let at: Date
        if let stamp = json["timestamp"] as? String, let parsed = ISO8601DateFormatter().date(from: stamp) {
            at = parsed
        } else {
            at = Date()
        }
        if let text = content as? String {
            if text.contains("<task-notification>") {
                let pattern = #"<task-id>\s*([^<\s]+)\s*</task-id>"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(text.startIndex..., in: text)
                    for match in regex.matches(in: text, range: range) {
                        if let idRange = Range(match.range(at: 1), in: text) {
                            background.removeValue(forKey: String(text[idRange]))
                        }
                    }
                }
            }
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        for block in blocks {
            if block["type"] as? String != "tool_result" {
                if let text = blockText(block), text.contains("<task-notification>") {
                    let pattern = #"<task-id>\s*([^<\s]+)\s*</task-id>"#
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        let range = NSRange(text.startIndex..., in: text)
                        for match in regex.matches(in: text, range: range) {
                            if let idRange = Range(match.range(at: 1), in: text) {
                                background.removeValue(forKey: String(text[idRange]))
                            }
                        }
                    }
                }
                continue
            }
            guard let callId = block["tool_use_id"] as? String, calls.contains(callId),
                  let text = blockText(block) else { continue }
            let pattern = #"running in background with ID: (\w+)|Async agent launched[\s\S]*?agentId: (\w+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let idRange = Range(match.range(at: 1), in: text) {
                    background[String(text[idRange])] = at
                } else if let idRange = Range(match.range(at: 2), in: text) {
                    background[String(text[idRange])] = at
                }
            }
        }
    }

    private func blockText(_ block: [String: Any]) -> String? {
        if block["type"] as? String == "text", let text = block["text"] as? String { return text }
        guard let inner = block["content"] else { return nil }
        if let str = inner as? String { return str }
        if let arr = inner as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }

    private func isBackgroundCall(_ block: [String: Any]) -> Bool {
        switch block["name"] as? String {
        case "Agent", "Task": return true
        case "Bash", "PowerShell":
            guard let input = block["input"] as? [String: Any] else { return false }
            return input["run_in_background"] as? Bool ?? false
        default: return false
        }
    }

    private func parseWakeup(_ json: [String: Any], _ block: [String: Any]) -> Date? {
        guard let input = block["input"] as? [String: Any],
              let delay = input["delaySeconds"] as? Double,
              let stamp = json["timestamp"] as? String,
              let at = ISO8601DateFormatter().date(from: stamp) else { return nil }
        return at.addingTimeInterval(min(max(delay, 60), 3600) + 30)
    }

    private func parseRateLimit(_ line: String, sessionId: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["sessionId"] as? String == sessionId else { return nil }
        var text = ""
        if let message = json["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if json["error"] as? String != "rate_limit" && !RateLimitParser.looksLikeUsageLimit(text) { return nil }
        let at: Date
        if let stamp = json["timestamp"] as? String, let parsed = ISO8601DateFormatter().date(from: stamp) {
            at = parsed
        } else {
            at = Date()
        }
        return RateLimitParser.parseReset(text, at: at) ?? at.addingTimeInterval(RateLimitParser.fallbackDelay)
    }

    private func mapState(_ status: String?, activity: Date) -> AgentState {
        switch status?.lowercased() {
        case "busy", "working", "running": return .working
        case "thinking": return .thinking
        case "waiting", "waiting_for_input": return .waitingForInput
        case "waiting_for_approval": return .waitingForApproval
        case "error": return .error
        case "idle": return .idle
        default: return .unknown
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let millis = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }
        if let str = value as? String {
            return ISO8601DateFormatter().date(from: str)
        }
        return nil
    }

    private func fileModificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    private func fileCreationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? Date()
    }

    private func findGitRoot(_ path: String?) -> String? {
        guard let path = path else { return nil }
        var url = URL(fileURLWithPath: path)
        while true {
            let gitPath = url.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitPath) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}
