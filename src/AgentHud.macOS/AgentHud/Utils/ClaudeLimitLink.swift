import Foundation

/// Registers a Claude Code statusLine script that drops the official rate_limits into
/// `claude-limits.json`, mirroring `src/AgentHud/ClaudeLimitLink.cs` on Windows. Any
/// existing user statusLine command is chained (saved to `claude-statusline-inner.txt`
/// and re-invoked from the script) and restored when unlinked.
@MainActor
public final class ClaudeLimitLink {
    public static let shared = ClaudeLimitLink()

    private let dir: URL
    private let settingsPath: URL
    private var cached: (size: Int, modified: Date, snapshot: ClaudeLimitSnapshot)?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = support.appendingPathComponent("AgentHud")
        settingsPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    private var scriptPath: URL { dir.appendingPathComponent("claude-statusline.sh") }
    private var innerPath: URL { dir.appendingPathComponent("claude-statusline-inner.txt") }
    private var limitsPath: URL { dir.appendingPathComponent("claude-limits.json") }
    private var command: String { "/bin/sh \"\(scriptPath.path)\"" }

    public var isLinked: Bool {
        (try? readSettings())?["statusLine"].flatMap { ($0 as? [String: Any])?["command"] as? String } == command
    }

    public func link() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var settings = try readSettings()
        if let existing = settings["statusLine"] as? [String: Any],
           let old = existing["command"] as? String, old != command {
            try old.write(to: innerPath, atomically: true, encoding: .utf8)
        } else if settings["statusLine"] == nil, FileManager.default.fileExists(atPath: innerPath.path) {
            try FileManager.default.removeItem(at: innerPath)
        }
        try Self.script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        settings["statusLine"] = ["type": "command", "command": command]
        try writeSettings(settings)
    }

    /// First-run attempt: never surfaces an error dialog; a failure just means we retry next launch.
    @discardableResult
    public func linkQuietly() -> Bool {
        (try? link()) != nil
    }

    public func unlink() throws {
        var settings = try readSettings()
        guard (settings["statusLine"] as? [String: Any])?["command"] as? String == command else { return }
        if FileManager.default.fileExists(atPath: innerPath.path) {
            let old = try String(contentsOf: innerPath, encoding: .utf8)
            settings["statusLine"] = ["type": "command", "command": old]
            try FileManager.default.removeItem(at: innerPath)
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
    }

    public func readSnapshot() -> ClaudeLimitSnapshot {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: limitsPath.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date else { return .none }
        if let c = cached, c.size == size, c.modified == modified { return c.snapshot }
        guard let text = try? String(contentsOf: limitsPath, encoding: .utf8) else { return .none }
        let snapshot = ClaudeLimitSnapshot.parseStatusLine(text, updatedAt: modified)
        cached = (size, modified, snapshot)
        return snapshot
    }

    /// Thrown instead of silently falling back to `[:]` so `link()`/`unlink()` abort
    /// without writing when the existing settings.json cannot be parsed back out —
    /// otherwise a round trip would overwrite the user's whole file with just `statusLine`.
    private enum SettingsError: Error { case unreadable }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return [:] }
        let data = try Data(contentsOf: settingsPath)
        guard let settings = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw SettingsError.unreadable
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsPath, options: .atomic)
    }

    // plutil ships with every macOS and parses JSON from stdin without a python3/jq
    // dependency. This should be verified on real hardware, in particular that
    // `used_percentage` survives as a JSON number; if it misbehaves, fall back to
    // `/usr/bin/python3 -c 'import json,sys;...'` inside the same `case` guard.
    // `exit 0` always, so a failure here never breaks Claude Code's prompt. Atomic
    // write via `.tmp` + `mv -f`, same as Windows.
    private static let script = """
        #!/bin/sh
        # Agent HUD: Claude Code statusLine -> claude-limits.json (+ chain the user's own status line)
        dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        raw=$(cat)
        limits=$(printf '%s' "$raw" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
        case "$limits" in
          '{'*) printf '{"rate_limits":%s}' "$limits" > "$dir/claude-limits.json.tmp" \\
                && mv -f "$dir/claude-limits.json.tmp" "$dir/claude-limits.json" ;;
        esac
        inner="$dir/claude-statusline-inner.txt"
        if [ -f "$inner" ]; then printf '%s' "$raw" | /bin/sh -c "$(cat "$inner")"; fi
        exit 0
        """
}
