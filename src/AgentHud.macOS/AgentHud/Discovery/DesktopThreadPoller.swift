import AppKit

struct DesktopThreadReport: Decodable, Sendable {
    let state: AgentState
    let at: Double?
    let turn: String?
}

/// Uses the provider's existing AgentHUD browser profile. A busy login/usage poll yields
/// no observation. No browser process or route is shared with the user's ordinary tabs.
actor DesktopThreadPoller {
    enum Provider: String { case amp, gemini }
    private let provider: Provider
    private var lastAttempt = Date.distantPast
    private var busy = false
    private var observed: [String: (report: DesktopThreadReport, date: Date)] = [:]
    private var attempted: [String: Date] = [:]

    init(_ provider: Provider) { self.provider = provider }

    func sample(_ request: [String: String], now: Date) -> [String: DesktopThreadReport] {
        observed = observed.filter { key, value in
            guard let turn = request[key], now.timeIntervalSince(value.date) < 75 else { return false }
            return provider == .amp || turn == value.report.turn
        }
        attempted = attempted.filter { request[$0.key] != nil }
        if !busy, !request.isEmpty, now.timeIntervalSince(lastAttempt) >= 20 {
            let ordered = request.keys.sorted {
                (attempted[$0] ?? .distantPast, $0) < (attempted[$1] ?? .distantPast, $1)
            }
            let batch = Dictionary(uniqueKeysWithValues: ordered.prefix(provider == .amp ? 300 : 3).map { ($0, request[$0]!) })
            for id in batch.keys { attempted[id] = now }
            lastAttempt = now
            busy = true
            Task {
                let provider = self.provider
                let replies = await Task.detached(priority: .utility) { Self.read(provider, batch) }.value
                defer { busy = false }
                guard let replies else { return }
                for id in batch.keys {
                    if let reply = replies[id], provider == .amp || reply.turn == batch[id] {
                        observed[id] = (reply, Date())
                    } else { observed[id] = nil }
                }
            }
        }
        return observed.mapValues(\.report)
    }

    private static func read(_ provider: Provider, _ request: [String: String]) -> [String: DesktopThreadReport]? {
        let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentHud/" + (provider == .amp ? "AmpUsageProfile" : "GeminiTitleProfile"))
        guard FileManager.default.fileExists(atPath: profile.path), profile.resolvingSymlinksInPath().path == profile.path,
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let executable = Bundle(url: chrome)?.executableURL,
              let script = Bundle.module.url(forResource: "desktop_thread_status", withExtension: "rb"),
              let data = try? JSONEncoder().encode(request) else { return nil }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["--disable-gems", script.path, provider.rawValue, executable.path, profile.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            return nil
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, result.count < 131072 else { return nil }
        return try? JSONDecoder().decode([String: DesktopThreadReport].self, from: result)
    }
}
