import Foundation

/// Resumes a conversation stopped by a usage limit once, shortly after the limit resets
/// (port of the Windows AutoResumer).
/// Claude: `claude --resume <id> -p --permission-mode acceptEdits`
/// Codex:  `codex exec resume --skip-git-repo-check -c sandbox_mode=workspace-write <id> -`
/// The prompt goes through stdin to avoid shell quoting issues.
public final class AutoResumer {
    public struct Launch: Equatable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: String
    }

    public static var defaultPrompt: String { Localiz.current.string("Resume.DefaultPrompt") }
    /// Right after the reset the request can still be refused, so wait a little.
    public static let startDelay: TimeInterval = 60

    private let home: String
    private let logDirectory: URL
    private let now: () -> Date
    private let locate: (AgentType) -> String?
    /// Injected starter for tests; nil runs the real process (`run`).
    private let start: ((AgentSession, Launch, String) -> Bool)?
    private let lock = NSLock()
    /// One attempt per (session, reset time). Hitting the limit again changes the reset
    /// time, so that gets a fresh attempt.
    private var attempted: Set<String> = []

    public init(home: String = NSHomeDirectory(),
                logDirectory: URL,
                now: @escaping () -> Date = { Date() },
                locate: ((AgentType) -> String?)? = nil,
                start: ((AgentSession, Launch, String) -> Bool)? = nil) {
        self.home = home
        self.logDirectory = logDirectory
        self.now = now
        self.locate = locate ?? { AutoResumer.locateCLI($0, home: home) }
        self.start = start
    }

    public func isDue(_ session: AgentSession) -> Bool {
        guard let reset = session.rateLimitResetAt, session.parentSessionId == nil else { return false }
        let now = self.now()
        // A limit that reset long ago (HUD was closed) may already have been handled by the user.
        return now >= reset.addingTimeInterval(Self.startDelay)
            && now < reset.addingTimeInterval(CodexProvider.limitGrace)
    }

    public func check(_ sessions: [AgentSession], prompt: String) {
        for session in sessions where isDue(session) {
            guard let reset = session.rateLimitResetAt else { continue }
            lock.lock()
            let inserted = attempted.insert("\(session.id)|\(reset.timeIntervalSince1970)").inserted
            lock.unlock()
            guard inserted, let launch = launch(for: session) else { continue }
            _ = start?(session, launch, prompt) ?? run(session, launch, prompt)
        }
    }

    public func launch(for session: AgentSession) -> Launch? {
        guard session.agentType == .claudeCode || session.agentType == .codex,
              let separator = session.id.firstIndex(of: ":"),
              // Only a UUID-shaped session ID and fixed options go on the command line.
              let uuid = UUID(uuidString: String(session.id[session.id.index(after: separator)...])),
              let project = session.projectPath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory), isDirectory.boolValue,
              let executable = locate(session.agentType) else { return nil }
        let id = uuid.uuidString.lowercased()
        let arguments = session.agentType == .claudeCode
            ? ["--resume", id, "-p", "--permission-mode", "acceptEdits"]
            : ["exec", "resume", "--skip-git-repo-check", "-c", "sandbox_mode=workspace-write", id, "-"]
        return Launch(executable: executable, arguments: arguments, workingDirectory: project)
    }

    /// Default starter. Runs through a login shell so npm-installed CLIs (`#!/usr/bin/env node`)
    /// find node: a GUI app does not inherit the user's PATH.
    public func run(_ session: AgentSession, _ launch: Launch, _ prompt: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", launch.executable] + launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        // Output lands in the conversation transcript, so it is not captured.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            log("\(session.id) pid \(process.processIdentifier): \(launch.executable) \(launch.arguments.joined(separator: " ")) (cwd \(launch.workingDirectory))")
            return true
        } catch {
            log("\(session.id): start failed: \(error.localizedDescription)")
            return false
        }
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        let url = logDirectory.appendingPathComponent("auto-resume.log")
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: - CLI lookup

    /// Usual install locations, then the login shell's PATH, then the CLI bundled in the
    /// newest VS Code extension.
    public static func locateCLI(_ type: AgentType, home: String) -> String? {
        let name = type == .claudeCode ? "claude" : "codex"
        let fileManager = FileManager.default
        let candidates = ["\(home)/.local/bin/\(name)", "\(home)/.claude/local/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return found }
        if let found = loginShellLookup(name) { return found }
        return type == .claudeCode
            ? newestExtensionBinary(home: home, prefix: "anthropic.claude-code-", relatives: ["resources/native-binary/claude"])
            : newestExtensionBinary(home: home, prefix: "openai.chatgpt-", relatives: ["bin/macos-aarch64/codex", "bin/macos-x86_64/codex"])
    }

    private static func loginShellLookup(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    private static func newestExtensionBinary(home: String, prefix: String, relatives: [String]) -> String? {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".vscode/extensions")
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(atPath: root.path) else { return nil }
        let binaries = directories.filter { $0.hasPrefix(prefix) }.flatMap { directory in
            relatives.map { root.appendingPathComponent(directory).appendingPathComponent($0).path }
        }.filter { fileManager.isExecutableFile(atPath: $0) }
        func modified(_ path: String) -> Date {
            (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        }
        return binaries.max { modified($0) < modified($1) }
    }
}
