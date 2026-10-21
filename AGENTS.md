# AGENTS.md

Orientation for AI coding agents (Claude Code, Codex, Copilot, Cursor, ...) working in this repository. Human-facing docs: [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md).

## What this is

Agent HUD is a small always-on-top Windows overlay (WPF, .NET 9) that discovers running **Claude Code** and **Codex** sessions by reading their local session files, groups them by project, and shows each session's state (working, waiting for input/approval, completed, rate-limited, ...). Double-clicking a session opens the project and conversation in VS Code. It also shows 5-hour / weekly usage gauges and can auto-resume sessions after a usage limit resets. A separate native macOS port (SwiftUI) lives in `src/AgentHud.macOS/`.

## Layout

```
AgentHud.sln
src/AgentHud.Core/          net9.0 class library — no UI, all parsing/state logic (testable)
  Models/                   AgentSession (record), AgentState, AgentType, LimitWindow
  Discovery/                IAgentProvider, ClaudeCodeProvider, CodexProvider,
                            AgentDiscoveryService, AgentSessionRegistry, RateLimitParser,
                            GitRoot, ProcessSnapshot, SessionFileReader
  AutoResumer.cs            runs `claude --resume` / `codex exec resume` after a limit resets
  UpdateChecker.cs          picks a newer GitHub release + matching zip asset (auto-update)
  RateLimitNotifier.cs      decides which sessions get a "limit reset" notification
  MemoStore.cs              global + per-project notes (memos.json)
  Loc.cs, Strings.tsv       localization table (THIS Strings.tsv is the one loaded at runtime)
src/AgentHud/               net9.0-windows WPF app (WinExe)
  MainWindow.xaml(.cs)      the HUD: session list, minimized dot bar, usage gauges, settings
                            persistence (Placement record), VS Code open (OpenInVsCode)
  SettingsWindow, MemoWindow, NotificationWindow (.xaml/.cs)
  AppUpdater.cs             auto-update: download + SHA-256 + extract, apply-update.ps1 swaps files after exit
  ClaudeUsageApi.cs         claude.ai usage API polling (via WebViewFetcher, DPAPI-stored key)
  WebViewFetcher.cs         off-screen WebView2 used to get past Cloudflare
  ClaudeLimitLink.cs        installs a statusLine script in ~/.claude/settings.json to read rate_limits
  Windows/                  VirtualDesktopPin (PinWindow P/Invoke), VirtualDesktopFollower (fallback)
  native/                   VirtualDesktopAccessor.dll + vda.json (bot-managed, do not hand-edit)
  Strings.tsv               copy of the Core table; keep identical to src/AgentHud.Core/Strings.tsv
src/AgentHud.macOS/         Swift Package (macOS 14+), separate port, also has OpenCode providers
tests/AgentHud.Tests/       console program of Assert(...) checks — Program.cs
scripts/                    update-vda.ps1 (DLL verify/update), build_app.sh (macOS bundle),
                            gen_agent_artwork.py (XAML icon paths → Swift), bench_*.swift
docs/                       vscode-session-open.md (VS Code URI investigation), images/
.github/workflows/          build.yml (CI), release.yml (v* tag → zips), update-vda.yml (weekly)
```

## Data flow

```
~/.claude/sessions/*.json, ~/.claude/projects/**.jsonl   ~/.codex/sessions/**/rollout-*.jsonl
            │                                                        │
   ClaudeCodeProvider                                         CodexProvider        (IAgentProvider.DiscoverAsync)
            └──────────────┬─────────────────────────────────────────┘
               AgentDiscoveryService  — FileSystemWatcher on WatchRoots + 3 s PeriodicTimer
                           │ Replace(all sessions)
               AgentSessionRegistry   — thread-safe; tracks unread completion (5 min), raises Changed
                           │
               MainWindow.UpdateSessions — filters hidden/stale, sounds, AutoResumer.Check,
                                           RateLimitNotifier.TakeDue, UpdateUsage (gauges)
```

## Where to look

| Task | Start here |
| --- | --- |
| Session state is wrong for Claude | `ClaudeCodeProvider.MapState`, `ReadTranscriptAsync` (AskUserQuestion, ScheduleWakeup, background tasks, rate_limit errors, token usage) |
| Session state is wrong for Codex | `CodexProvider.DiscoverAsync` (event → state mapping, `request_user_input`, `ActiveWindow`) |
| Session state is wrong for OpenCode | `OpenCodeProvider` (`MapV2State` over `session_v2` + `session_message` for v2, `MapState` over `session` + `message` + `part` for v1) |
| Green check / completion behavior | `AgentSessionRegistry.TrackCompletion`, `AgentSession.DisplayState` |
| Usage-limit reset time parsing | `RateLimitParser.ParseReset`, `CodexProvider.ExhaustedWindowReset` |
| Claude limit source choice / staleness | `ClaudeLimitPolicy`, `ClaudeLimitSnapshot` (`src/AgentHud.Core/ClaudeLimits.cs`), `ClaudeLimitLink`, `ClaudeUsageApi.Snapshot`/`Enabled` |
| Auto-resume command line / CLI lookup | `AutoResumer.CreateStartInfo`, `FindOnPath`, `NewestExtensionBinary` |
| Usage gauges (5h / weekly, pace marker) | `MainWindow.UpdateUsage`, `UsageRow`, `ClaudeUsageApi`, `ClaudeLimitLink` |
| Double-click → VS Code | `MainWindow.OpenInVsCode`, `ConversationUri`; background in docs/vscode-session-open.md |
| Status colors | `StateBrushConverter` |
| A new setting | property on `MainWindow` + field on the `Placement` record (`SavePlacement`/`RestorePlacement`) + `SettingsWindow.xaml` + strings |
| UI text / translations | `src/AgentHud.Core/Strings.tsv` (copy to `src/AgentHud/Strings.tsv`); XAML uses `{local:Tr Key}`, code uses `Loc.T` / `Loc.F` |
| Supporting a new agent | implement `IAgentProvider`, add a value to `AgentType`, register it in the `MainWindow` constructor |
| Auto-update (release check, install) | `UpdateChecker.Pick` (Core), `AppUpdater`, `MainWindow.CheckForUpdateAsync`/`InstallUpdateAsync`; asset flavor comes from `-p:UpdateAsset=` in release.yml (dev builds have none → disabled) |
| Virtual desktop pinning | `Windows/VirtualDesktopPin.cs`, `Windows/VirtualDesktopFollower.cs` |

Prefer searching by symbol name (`grep -rn "TrackCompletion" src`) over line numbers; files are compact and dense.

## Commands

Windows, PowerShell:

```powershell
dotnet build AgentHud.sln -c Release
dotnet run --project tests/AgentHud.Tests/AgentHud.Tests.csproj -c Release   # all checks; throws on first failure
dotnet run --project src/AgentHud/AgentHud.csproj                            # run the HUD
./scripts/update-vda.ps1 -Verify                                             # DLL integrity (CI step)
```

macOS: `./scripts/build_app.sh` (output `src/AgentHud.macOS/dist/AgentHud.app`).

## Conventions

- C#: file-scoped namespaces, nullable enabled, `record` + `with` for immutable session snapshots, compact one-line members. Match the surrounding density.
- Code comments are mostly Korean; docs/README are English. Commit messages and PR titles: short English imperative (`Fix Codex session state after turn abort`).
- Keep agent-format parsing inside the provider. When relying on an external tool's internal format or URI, note the verified version in a comment or doc.
- Tests: add an `Assert(...)` to `tests/AgentHud.Tests/Program.cs` for behavior changes. Never read the real `~/.claude` / `~/.codex`; create fake session files under a temp dir like existing checks. Use `TimeProvider` injection for time-dependent logic.
- Do not edit `src/AgentHud/native/*` by hand; the Update VirtualDesktopAccessor workflow opens PRs for it.
- macOS code is maintained by @hail-kang; Windows-only maintainers cannot test it.

## Runtime files

`%LOCALAPPDATA%\AgentHud\`: `placement.json` (window position + all settings), `memos.json`, `auto-resume.log`, `claude-statusline.ps1` + `claude-limits.json` + `claude-statusline-inner.txt` (status-line link, default on; chains/restores any existing user status line), `claude-session.bin` (DPAPI-encrypted claude.ai sessionKey, opt-in advanced option), `webview2/` (WebView2 profile), `update/` (downloaded release zip, staged files, `apply-update.ps1`, `update.log`).

macOS: `~/Library/Application Support/AgentHud/` holds the equivalent `claude-statusline.sh` + `claude-limits.json` + `claude-statusline-inner.txt` (see `ClaudeLimitLink.swift`). No sessionKey API is ported to macOS.
