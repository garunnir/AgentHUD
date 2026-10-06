# Agent HUD

When you run Claude Code or Codex across several projects at once, it's easy to lose track of which window has which agent working, and which one has finished and is waiting on you. Agent HUD is a small always-on-top panel that automatically collects the agent sessions running on your PC, groups them by project, and shows their status. There's nothing to register — just leave it running. Double-click a session to jump straight to that project's VS Code window and conversation.

![Agent HUD floating over VS Code (the AGENTS panel on the right)](docs/images/screenshot.png)

| Default panel | Minimized |
| --- | --- |
| ![HUD panel showing each session's agent icon, project, task title and status](docs/images/hud-panel.png) | ![Minimized HUD showing one status dot per session in a row](docs/images/hud-minimized.png) |

Click the `–` button in the header (or double-click the header) to shrink the HUD to a small bar with one status dot per session. Hover a dot to see its project and status, drag the bar to move it, and double-click it to restore the full panel.

![Every state shown in minimized mode: blue dot (working, pulsing), yellow dot or ?/! (waiting for input/approval), green check (just finished), gray dot (idle), orange-red dot (error), purple dot (unknown)](docs/images/hud-mini-states.svg)

The `?`/`!` symbols appear only when **Settings... → Show waiting states as symbols (? / !)** (right-click the HUD) is turned on. When it's off, both waiting states are shown as yellow dots.

## Features

- Reads real Claude `~/.claude/sessions/*.json` metadata (PID, sessionId, cwd, status) and combines it with whether the process is alive
- Reads `session_meta` (session_id, cwd) from real Codex `~/.codex/sessions/**/rollout-*.jsonl` files and combines it with file activity time
- Layered design: provider → discovery service → thread-safe registry → HUD
- Hides Codex's internal guardian sessions and Claude VS Code idle sessions with no conversation history (real conversations and working subagents are kept)
- `FileSystemWatcher` events plus a cheap 3-second reconciliation poll
- Project / Git worktree detection, stable provider session IDs, and brief display of ended sessions
- Borderless, topmost, taskbar-hidden HUD with saved position
- Double-click a session to open its project (Git root, or cwd if none) in VS Code and open the conversation tab through the extension URIs (`anthropic.claude-code/open?session=`, `openai.chatgpt/local/`). Sidebar conversations can't be switched to — see the [investigation notes](docs/vscode-session-open.md)
- Minimized mode (header `–` button or header double-click) showing only status dots in a row, anchored to the right edge; double-click to restore
- Shows the HUD on every Windows virtual desktop via `PinWindow`
- Hover a session and click `×` to hide it from the HUD regardless of state. A hidden session reappears when it newly starts waiting for input/approval or completes; right-click the HUD → **Show hidden sessions** to restore them all at once (hidden state resets on restart)
- Free-form notepad from the header memo button, and per-project memos via right-click on a session → **Project memo...** (projects with a memo show an icon next to their name — click it to open; stored in `%LOCALAPPDATA%\AgentHud\memos.json`)
- Optional sounds on completion and on questions (waiting for input or approval), with a built-in preview and support for custom sound files
- Usage gauges: the bottom of the window shows each detected LLM's remaining 5-hour and weekly usage as bars, with time until reset ([Usage gauges](#usage-gauges))
- Usage-limit detection: when Claude (a `rate_limit` API error in the conversation log) or Codex (`usage_limit_exceeded` in `task_complete`) stops on a usage limit, the session shows a pink dot (`RateLimited`) with a reset-time tooltip, and when the reset time arrives a notification pops up at the bottom right with a sound (click it to open the conversation; can be turned off in Settings). Turn on **Settings... → Resume automatically after a usage limit resets** to have the conversation resumed once via the CLI 1 minute after the reset ([Auto-resume](#auto-resume-after-usage-limits))
- UI localization: strings live in `src/AgentHud/Strings.tsv` (English and Korean included). The HUD follows the system language and uses the fallback language set in Settings for anything missing — add a column to add a language

## Requirements

### Runtime

- **Windows 11**: the bundled `VirtualDesktopAccessor.dll` is the Windows 11 build (`2024-12-16-windows11`). The HUD also works on Windows 10, but pinning to all virtual desktops fails and it falls back to following the active window.
- **.NET 9 SDK** (for building / `dotnet run`). If you only use a prebuilt executable, the **.NET 9 Desktop Runtime** is enough.
- Agents to watch: **Claude Code** (`~/.claude/sessions`) and **Codex** (`~/.codex/sessions`). Either one is fine; if a folder doesn't exist, that provider is simply empty.
- Git does not need to be installed. Projects are identified by looking for the `.git` folder/file directly.

### VS Code integration (session double-click)

To jump to VS Code by double-clicking a session, you need all of the following. None of them affect the HUD display itself.

| Item | Why it's needed | How to check |
| --- | --- | --- |
| **VS Code Stable** | Uses `vscode://` URIs. Insiders (`vscode-insiders://`) and forks such as VSCodium are not supported. | — |
| **`code` command on PATH** | Used to bring the project window to the front first. Without it, the HUD falls back to a `vscode://file/` URI, which is less accurate at switching to an already open window. | `code --version` (the "Add to PATH" install option, or **Shell Command: Install 'code' command in PATH** from the Command Palette) |
| **`vscode://` protocol registered** | Hands the conversation URI to VS Code. Registered automatically by a normal install. | `HKCU\Software\Classes\vscode\shell\open\command` exists |
| **Claude Code extension** (`anthropic.claude-code`) | Opens the Claude conversation tab (`/open?session=`). Verified on 2.1.284. | `code --list-extensions` |
| **Codex extension** (`openai.chatgpt`) | Opens the Codex conversation (`/local/<id>`). Verified on 26.917.62051, but actually switching conversations is untested. | `code --list-extensions` |
| **Claude extension Preferred Location = editor** (recommended) | The extension provides no way to switch the sidebar conversation from outside, so switching only works for editor tabs. With the sidebar, only the window is brought forward. | Setting `claudeCode.preferredLocation` |

If VS Code isn't running, the URI may arrive before the extension is ready and the conversation won't open. Just double-click again. See the [investigation notes](docs/vscode-session-open.md) for details.

### Development (build & debug in VS Code)

- **C# Dev Kit** (`ms-dotnettools.csdevkit`, recommended by the repo): the **C#** extension (`ms-dotnettools.csharp`) installed with it provides the `coreclr` debugger for `F5`. Check the C# Dev Kit license terms (same as Visual Studio Community).
- **.NET 9 SDK**: the `build` / `run registry checks` tasks call `dotnet`.
- **Windows PowerShell 5.1** or later: used by the `verify VirtualDesktopAccessor` task and `scripts/update-vda.ps1`.

## Running

Prebuilt files are available on the [Releases](https://github.com/garunnir/AgentHUD/releases) page. `win-x64.zip` requires the .NET 9 Desktop Runtime; `win-x64-self-contained.zip` includes the runtime. Pushing a `v*` tag makes GitHub Actions build both files and create a release.

To run from source:

```powershell
dotnet run --project src/AgentHud/AgentHud.csproj
```

In VS Code, open the repository folder, press `F5`, and pick the **Agent HUD (Debug)** configuration. `Ctrl+Shift+B` runs a Debug build, and **Tasks: Run Test Task** from the Command Palette runs the registry checks.

The repository currently targets `net9.0-windows` to match the installed SDK. After installing the .NET 10 SDK, change the TargetFramework in both `.csproj` files to `net10.0-windows`.

## Verification

```powershell
dotnet build AgentHud.sln
dotnet run --project tests/AgentHud.Tests/AgentHud.Tests.csproj
```

## How it works

### Codex detection

Codex changes are detected by file size and modification time, and event times and status are read from the last 256 KB of a changed log. Even if Windows doesn't update a file's modification time, growth in size is picked up. `task_started` is shown as Working, reasoning as Thinking, `task_complete` as Idle, and `turn_aborted` as Stopped. Since there's no per-thread PID link yet, a session is assumed active if its latest event falls within the active window (default 5 minutes; change it to 1–1440 minutes via right-click the HUD → **Settings... → Codex active window**). Whether a long-silent task or a waiting session is still alive can't be determined for certain. If Claude's or Codex's internal formats change, only the provider needs updating.

### Virtual desktops

Pinning to all virtual desktops uses the MIT-licensed `VirtualDesktopAccessor.dll`. The window is pinned after it's shown and re-checked every 5 seconds. If the pinning API fails, the HUD uses Windows' `IVirtualDesktopManager` to find the desktop of the current foreground window and moves itself there (every 250 ms). If the desktop you switch to has no foreground window, the move may be delayed until you activate a window.

### CI

GitHub Actions runs a DLL integrity check, a Release build, and the registry checks on every push/PR. Every Monday it checks for the latest stable VirtualDesktopAccessor release and automatically opens a `deps/virtualdesktopaccessor` PR if it changed.

### Status colors

Blue means working/thinking, yellow means it needs your reply or approval, gray means Idle (waiting for the next instruction) or stopped, red means error, a green check (✓) means completed but not yet seen, and purple means Unknown (no status info or unrecognized). While starting, working, or thinking, the blue dot pulses gently.

### Completion

While the HUD is running, a completion notification is shown when a session goes from working/thinking/waiting for approval to Idle or Completed. An unseen completion stays as a green check in both the normal and minimized views, and the session stays in the list for up to 5 minutes after completion is detected even if it disappears. After 5 minutes the completion mark is cleared and the session returns to Idle (inactive sessions are cleaned up by the usual rules). Double-clicking the session to open it marks it as seen. When a new command puts it back into starting/working/thinking, the old completion mark is cleared and the current state is shown; when that task finishes, it gets a green check again. Seen-completion records reset when the HUD exits.

### Questions and approvals

By default, waiting for a question or approval is shown as a yellow dot in both the normal and minimized views. Turn on right-click the HUD → **Settings... → Show waiting states as symbols (? / !)** to show questions as `?` and approvals as `!`. The setting applies immediately and persists across restarts.

- **Codex**: detects calls to the synchronous question tool `request_user_input` and returns to working once a response with the same `call_id` arrives. An asynchronous question (`request_user_input_async`) is assumed to be waiting from the call until the next user message or an abort; it is not cleared by an `accepted` response or a task-complete event. During that time `?` takes priority even if other work is happening. Questions written in ordinary messages are not detected.
- **Claude**: detects the `waiting` / `waiting_for_input` metadata states and `AskUserQuestion` calls in the conversation log. Once a `tool_result` (answer or cancel) matching the question tool ID is recorded, the log-based question state is cleared and the metadata state is shown.

## Usage gauges

![Usage gauges at the bottom: per-LLM icon, remaining 5-hour and weekly percentage inside each bar, a pace marker, and the time until reset on the right](docs/images/hud-usage.png)

When the window isn't minimized, the bottom shows a gauge bar for each detected LLM (distinguished by icon) with the **remaining** 5-hour (`5h`) and weekly usage. The remaining percentage is shown inside the bar and the time until reset on the right. The bar turns yellow at 70% used and red at 90% used.

The white tick on each bar is the **pace marker**: how much you'd have left right now if you spent the limit evenly across the window (the fraction of the window's time still remaining). If the bar ends to the left of the tick, you're using it faster than an even pace; to the right, you have room to spare. Hover the bar to see the exact value.

![Full HUD showing Claude and Codex 5-hour and weekly gauges together](docs/images/hud-usage-full.png)

- **Codex**: automatic, no setup. The session log's `token_count.rate_limits` contains the real limits reported by the server.
- **Claude**: the server-side limits aren't stored locally, so you need one of the methods below. Whichever was updated more recently is used.
  1. **claude.ai usage API (Settings → Claude usage API)**: enter your Organization ID and the `sessionKey` cookie, and usage is fetched every 5 minutes. Works even if you only use the VS Code extension. claude.ai sits behind Cloudflare, which blocks plain HTTP clients, so requests go through an off-screen WebView2 (Chromium) instance (installed by default on Windows 11). The `sessionKey` is encrypted with Windows DPAPI, stored in `%LOCALAPPDATA%\AgentHud`, and set as a cookie only while fetching. This is an unofficial API that may change or be blocked at any time, and you'll need to re-enter the cookie when it expires.
  2. **Link real Claude limits (via status line)**: registers a script as the `statusLine` in `~/.claude/settings.json` to receive `rate_limits`. Only works with the terminal `claude` CLI, not the VS Code extension. Your existing status line keeps running and is restored when you turn this off.
  3. With neither, the HUD shows the total tokens (input + output + cache creation) over the last 5 hours and 7 days, and if you set a token budget in Settings, shows a bar against that budget. The total is an estimate that only adds up sessions the HUD has detected.

## Auto-resume after usage limits

The reset time is read from the error text of the last turn that hit the limit: `try again at 4:34 PM` (local time) for Codex, and text like `resets 3pm (Asia/Seoul)` for Claude. If the text can't be parsed, Codex falls back to `resets_at` of the fully used window in `token_count.rate_limits`; if that's unknown too (or immediately, for Claude), the reset is assumed to be 1 hour after the limit was hit. Claude's limit text hasn't been verified against real logs, so several formats are accepted. Until the reset, the session is shown as `RateLimited`; if a new message is recorded in the meantime, the limit mark is cleared.

With auto-resume on, 1 minute after the reset the HUD runs the following command once per session, in the conversation's cwd with no window, and sends the message configured in Settings via stdin.

| Agent | Command | CLI location |
| --- | --- | --- |
| Claude | `claude --resume <id> -p --permission-mode acceptEdits` | `claude` on PATH, otherwise the VS Code extension's `claude.exe` |
| Codex | `codex exec resume --skip-git-repo-check -c sandbox_mode=workspace-write <id> -` | `codex` on PATH, otherwise the VS Code extension's `codex.exe` |

- Only file edits are auto-approved. Other command execution follows each tool's allowlist settings, and since there's no way to ask for approval, it's denied.
- The resumed progress is appended to the same session log, but it won't appear live in an already open VS Code conversation tab. Before continuing the conversation, double-click the session in the HUD to reopen it. If you type into the open tab as-is, the conversation may fork from the point before the resume.
- The limit-reset notification can be turned on and off separately from auto-resume and is on by default. With its sub-option **Only sessions shown in the HUD** (on by default), sessions hidden with `×` or dropped from the HUD list (such as Claude sessions that ended when VS Code was closed) are not notified. The notification doesn't steal focus and stays until you close or click it.
- Limits that reset more than 30 minutes ago (for example, while the HUD was off) and subagent sessions are not resumed. If a resume hits the limit again, it tries once more at the new reset time.
- Runs are logged to `%LOCALAPPDATA%\AgentHud\auto-resume.log`.

## Contributing

Bug reports and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
