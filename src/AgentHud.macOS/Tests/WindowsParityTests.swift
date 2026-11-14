import Foundation
import XCTest
@testable import AgentHud

/// Checks for the features ported from the Windows app (auto-resume, limit reset notice, memos).
final class WindowsParityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func session(_ id: String, type: AgentType = .claudeCode, project: String?, reset: Date?, parent: String? = nil) -> AgentSession {
        AgentSession(id: id, agentType: type, state: .rateLimited, hasUnreadCompletion: false, completionDetectedAt: nil,
                     processId: nil, projectPath: project, worktreePath: nil, sessionTitle: "t", currentTask: nil,
                     startedAt: Date(), lastActivityAt: Date(), isActive: true, wakeupAt: nil, hasBackgroundTasks: false,
                     parentSessionId: parent, rateLimitResetAt: reset, tokens5h: 0, tokensWeek: 0,
                     primaryLimit: nil, secondaryLimit: nil, limitsUpdatedAt: nil)
    }

    func testAutoResumeRunsOnceAfterResetWithFixedCommandLine() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        var now = reset.addingTimeInterval(30)
        var launches: [(AutoResumer.Launch, String)] = []
        let resumer = AutoResumer(logDirectory: project, now: { now }, locate: { $0 == .claudeCode ? "/bin/claude" : "/bin/codex" },
                                  start: { _, launch, prompt in launches.append((launch, prompt)); return true })
        let id = "4f9c2c1e-1111-2222-3333-444455556666"
        let claude = session("claude:\(id.uppercased())", project: project.path, reset: reset)

        resumer.check([claude], prompt: "go on")
        XCTAssertTrue(launches.isEmpty, "Waits StartDelay after the reset")

        now = reset.addingTimeInterval(AutoResumer.startDelay + 1)
        resumer.check([claude], prompt: "go on")
        resumer.check([claude], prompt: "go on")
        XCTAssertEqual(launches.count, 1, "One attempt per (session, reset)")
        XCTAssertEqual(launches.first?.0, AutoResumer.Launch(executable: "/bin/claude",
                                                             arguments: ["--resume", id, "-p", "--permission-mode", "acceptEdits"],
                                                             workingDirectory: project.path))
        XCTAssertEqual(launches.first?.1, "go on")

        let codex = session("codex:\(id)", type: .codex, project: project.path, reset: reset)
        XCTAssertEqual(resumer.launch(for: codex)?.arguments,
                       ["exec", "resume", "--skip-git-repo-check", "-c", "sandbox_mode=workspace-write", id, "-"])
        XCTAssertNil(resumer.launch(for: session("claude:not-a-uuid", project: project.path, reset: reset)), "Only UUID IDs reach the command line")
        XCTAssertNil(resumer.launch(for: session("opencode:\(id)", type: .openCode, project: project.path, reset: reset)))

        now = reset.addingTimeInterval(CodexProvider.limitGrace + 1)
        XCTAssertFalse(resumer.isDue(session("claude:\(UUID())", project: project.path, reset: reset)), "Old limits are left alone")
        XCTAssertFalse(resumer.isDue(session("claude:\(UUID())", project: project.path, reset: now.addingTimeInterval(-120), parent: "p")), "Subagents are skipped")
    }

    func testLimitResetNotifiedOncePerReset() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        var now = reset.addingTimeInterval(-1)
        let notifier = RateLimitNotifier(now: { now })
        let target = session("claude:a", project: "/tmp", reset: reset)
        XCTAssertTrue(notifier.takeDue([target]).isEmpty)
        now = reset.addingTimeInterval(1)
        XCTAssertEqual(notifier.takeDue([target]).map(\.id), ["claude:a"])
        XCTAssertTrue(notifier.takeDue([target]).isEmpty)
        var again = target
        again.rateLimitResetAt = reset.addingTimeInterval(-10)
        XCTAssertEqual(notifier.takeDue([again]).count, 1, "A new reset time is announced again")
    }

    func testDiscordWebhookValidationAndPayload() async {
        XCTAssertTrue(DiscordNotifier.isValidWebhookURL("https://discord.com/api/webhooks/123456789/abc-DEF_123"))
        XCTAssertTrue(DiscordNotifier.isValidWebhookURL("https://ptb.discord.com/api/webhooks/1/a"))
        XCTAssertFalse(DiscordNotifier.isValidWebhookURL("http://discord.com/api/webhooks/1/a"))
        XCTAssertFalse(DiscordNotifier.isValidWebhookURL("https://evil.example/api/webhooks/1/a"))
        XCTAssertFalse(DiscordNotifier.isValidWebhookURL("https://discord.com.evil.example/api/webhooks/1/a"))
        XCTAssertFalse(DiscordNotifier.isValidWebhookURL(nil))

        var bodies: [String] = []
        var status = 204
        let notifier = DiscordNotifier(localiz: Localiz(locale: Locale(identifier: "en"), language: "en")) { request in
            bodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            return status
        }
        notifier.enabled = true
        notifier.webhookURL = "https://discord.com/api/webhooks/1/token"
        let target = session("claude:d", project: "/tmp/my_proj*", reset: nil)

        notifier.notifyAsk = false
        XCTAssertNil(notifier.line(for: target, state: .waitingForInput), "Switched-off events are skipped")
        XCTAssertNil(notifier.line(for: target, state: .working), "Only completed and waiting states notify")
        let line = notifier.line(for: target, state: .completed)
        XCTAssertEqual(line?.contains("my\\_proj\\*"), true, "Project name is markdown-escaped")
        XCTAssertEqual(line?.contains("/tmp"), false, "Only the folder name is sent, not the path")

        let sent = await notifier.notify([(target, .completed), (target, .completed)])
        XCTAssertTrue(sent)
        XCTAssertEqual(bodies.count, 1, "Events from one scan are one request")
        XCTAssertTrue(bodies[0].contains("allowed_mentions") && bodies[0].contains("\"parse\":[]"), "Mentions are disabled")

        notifier.enabled = false
        let sentWhenDisabled = await notifier.notify([(target, .completed)])
        XCTAssertFalse(sentWhenDisabled)
        XCTAssertEqual(bodies.count, 1)
        notifier.enabled = true
        status = 429
        let rateLimited = await notifier.send("x")
        XCTAssertFalse(rateLimited, "A rate-limited send reports failure")
    }

    func testMemoStorePersistsGlobalAndProjectMemos() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memos.json")
        let store = MemoStore(url: url)
        store.setGlobal("global note")
        store.setProject("/Users/me/project/", "project note")
        let reloaded = MemoStore(url: url)
        XCTAssertEqual(reloaded.global, "global note")
        XCTAssertEqual(reloaded.project("/Users/me/project"), "project note", "Trailing slash is ignored")
        reloaded.setProject("/Users/me/project", "  ")
        XCTAssertFalse(MemoStore(url: url).hasProject("/Users/me/project"), "Blank text removes the memo")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil(json?["Global"], "Same shape as the Windows memos.json")
    }
}
