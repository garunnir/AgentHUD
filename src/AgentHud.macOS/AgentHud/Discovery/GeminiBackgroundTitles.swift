import AppKit
import Darwin

/// The visible setup browser exists only after an explicit Settings click. The worker uses its own profile.
@MainActor
final class GeminiBackgroundTitles: ObservableObject {
    static let shared = GeminiBackgroundTitles()
    private let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentHud/GeminiTitleProfile", isDirectory: true)
    @Published private(set) var statusKey = "Settings.GeminiConnectHint"
    @Published private(set) var connecting = false
    @Published private(set) var fetching = false
    private var setup: Process?
    private var worker: Process?
    private var previousIDs = Set<String>()
    private var lastAttempt = Date.distantPast
    private var generation = 0
    private var chrome: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome").flatMap { Bundle(url: $0)?.executableURL }
    }
    private var locked: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path)) != nil
    }

    func connect() {
        if connecting {
            if let setup, setup.isRunning { NSRunningApplication(processIdentifier: setup.processIdentifier)?.terminate() }
            return
        }
        guard !fetching, !locked, let chrome else { statusKey = "Settings.GeminiBusy"; return }
        let process = Process()
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard profile.resolvingSymlinksInPath().path == profile.path else { return }
            let fd = Darwin.open(profile.appendingPathComponent(".hud-title-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, !locked else { statusKey = "Settings.GeminiBusy"; return }
            process.executableURL = chrome
            process.arguments = ["--user-data-dir=" + profile.path, "--no-first-run", "--no-default-browser-check",
                                 "--disable-sync", "--disable-background-mode", "--app=https://gemini.google.com/app"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self, lease] _ in
                try? lease.close()
                Task { @MainActor in
                    self?.setup = nil
                    self?.connecting = false
                    self?.lastAttempt = .distantPast
                    self?.statusKey = "Settings.GeminiCheckPending"
                }
            }
            try process.run()
            generation += 1
            setup = process
            connecting = true
            statusKey = "Settings.GeminiFinishHint"
        } catch { statusKey = "Settings.GeminiUnavailable" }
    }

    func refresh(_ entries: [GeminiHistoryStore.Entry], store: GeminiHistoryStore, now: Date) {
        let grouped = Dictionary(grouping: entries, by: { $0.serverID ?? "" })
        let references = grouped.compactMapValues { $0.count == 1 ? $0[0].reference : nil }
            .filter { $0.key.range(of: #"^c_[0-9a-f]{16}$"#, options: .regularExpression) != nil }
        let ids = Set(references.keys)
        guard !ids.isEmpty, !connecting, !fetching, !locked,
              FileManager.default.fileExists(atPath: profile.path), profile.resolvingSymlinksInPath().path == profile.path,
              let chrome, let script = Bundle.module.url(forResource: "gemini_titles", withExtension: "rb"),
              now.timeIntervalSince(lastAttempt) >= (ids == previousIDs ? 300 : 20) else { return }
        previousIDs = ids
        lastAttempt = now
        let epoch = generation
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["--disable-gems", script.path, chrome.path, profile.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            let request = try JSONEncoder().encode(Array(ids))
            try process.run()
            worker = process
            fetching = true
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
        } catch {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            worker = nil
            fetching = false
            statusKey = "Settings.GeminiUnavailable"
            return
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(38))
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        Task {
            let valid = await Task.detached(priority: .utility) { () -> (String,[String:String]) in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard data.count <= 1_048_576, let result = try? JSONDecoder().decode(Reply.self, from: data) else { return ("unavailable", [:]) }
                let titles = (result.titles ?? [:]).filter { id,title in
                    guard let ref = references[id], !title.isEmpty, title.count <= 512 else { return false }
                    return store.contains(ref, serverID: id)
                }
                return (result.state,titles)
            }.value
            watchdog.cancel()
            worker = nil
            fetching = false
            guard generation == epoch else { return }
            for (id,title) in valid.1 { if let ref = references[id] { GeminiTitles.record(title, for: ref) } }
            switch valid.0 {
            case "ready": statusKey = "Settings.GeminiConnected"
            case "signin": statusKey = "Settings.GeminiSignIn"
            default: statusKey = "Settings.GeminiUnavailable"
            }
        }
    }

    private struct Reply: Decodable {
        let state: String
        let titles: [String:String]?
    }
}
