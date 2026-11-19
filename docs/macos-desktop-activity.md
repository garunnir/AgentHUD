# macOS desktop routing and activity

The default conversation target is **Automatic · desktop first**. An existing explicit target preference is preserved. Double-click a HUD row to open it. A running matching desktop app is tried first; VS Code is the fallback if that exact route is unavailable or fails.

| Source | Desktop navigation | Work / completion evidence |
| --- | --- | --- |
| GPT local Codex | `codex://threads/<UUID>` sent specifically to `com.openai.codex`; works even if the project folder was removed | Local rollout events plus trusted metadata hooks |
| Claude desktop Code | Canonical desktop metadata ID; exact app URI and destination URL confirmation | Local transcript state, metadata completed-turn increments, current composer Stop control |
| Amp desktop | Original canonical `ampcode.com/threads/T-…` sidebar AX link, with PID/role/URL validation | Source `Unread Messages` metadata; current visible thread's canonical WebArea URL plus enabled composer `Stop agent` control. No explicit successful-completion signal |
| Gemini desktop | Original sidebar AX row with identity/labels revalidated; never matched by title alone | Current-window `stop_button` only, shown separately from thread rows. Per-thread work/completion/unread unavailable |
| Claude Code log session | Explicit metadata UUID joins desktop record; desktop first, VS Code fallback | Local metadata, pending `AskUserQuestion`, final `end_turn` |
| OpenCode | Original sidebar link whose `oc://renderer/server/.../session/ses_...` ID matches | `session.execution.started/succeeded/failed/interrupted` from the server plugin |

Here GPT means local Codex chats, not the cloud ChatGPT chat list. The native sidebar contract was transferred from the Threaddeck investigation on this Mac (November 2026; OpenCode 2.3.0). Codex/Claude build numbers were not recorded. These private formats can change; an unrecognized row/event remains unknown. Claude desktop Code records and logs are joined only by explicit canonical UUID, never by title. Claude desktop question/approval states are not guessed from the absence of a spinner.

## Presentation and acknowledgement

- Working/thinking/starting renders a spinner. Async questions can remain pending while execution continues: the row shows a question badge as well as the spinner. A halted question uses the waiting state.
- Unseen completion renders a dot. Selection uses only a row background; it means the last successful HUD navigation, not continuous tracking of the source app's current view.
- Completion needs explicit terminal evidence. Idleness, archiving, a missing heartbeat, and a provider failure do not create success.
- Pending completions and acknowledgements are saved to the owner-only `~/Library/Application Support/AgentHud/completion-state.json`. They do not expire after five minutes. Only the revision clicked is acknowledged; a concurrent newer result stays unread.
- The Codex route is acknowledged when macOS accepts the exact-app URI request. This is not visual confirmation of the destination screen. Native routes require app activation and successful exact-element AX selection. Failed navigation, folder-only fallback and VS Code URI requests retain unread status because they cannot confirm the conversation was displayed. Dismissing a row explicitly acknowledges it.
- Claude desktop Code uses persistent canonical IDs from its own metadata, not anonymous AX row identities. Read acknowledgement is tied to the completion revision.
- The session area scrolls beyond twelve rows. Discovery/status polling runs every three seconds; native Amp/Gemini list discovery runs every thirty seconds; cached Claude canonical metadata refreshes every three seconds. Amp/Gemini retain their last list for at most sixty seconds through transient scan failures, checking expiry every poll; navigation always revalidates the original element. Closing the source app or revoking permission clears its list.

## Metadata collectors

AgentHUD reads owner-only, bounded metadata records for already discovered session IDs from both `AgentHud/activity` and `Threaddeck/activity` under Application Support. The newer record wins together with its own source lease. Existing trusted Threaddeck collectors can continue unchanged; **do not register a second collector just to use this build**.

Standalone copies are included in `integrations/`. They write to `AgentHud/activity` and store only IDs, state, sequence, event/producer/turn identifiers, timestamps and leases. They do not persist prompts, tool inputs, responses or credentials. No runtime dependencies or external API keys are required.

For a fresh machine without the existing collectors:

1. GPT: register command hooks for `UserPromptSubmit`, `PreToolUse`, `Stop`, and `Interrupt` using `/usr/bin/ruby /absolute/path/to/AgentHUD/integrations/hooks/status.rb chatGPT` in the app's hooks configuration. Preserve unrelated hooks, quote paths containing spaces, and trust the commands in the app's Hooks settings. `StopFailure` is supported if the installed app emits it. The helper accepts only the GPT contract with session and turn IDs; it does not install Claude hooks.
2. OpenCode 2.3.0: add the absolute `integrations/opencode` directory to the existing `plugins` array in `~/.config/opencode/opencode.json`, preserving other entries. Restart the source server/app to load the plugin. Remove that entry to uninstall.
3. Enable AgentHUD in macOS Accessibility settings for native Claude/OpenCode/Amp/Gemini navigation. AgentHUD's settings button opens that pane. Permission belongs to the specific app/signature; Threaddeck's grant is not AgentHUD's grant.

A GPT running hook lease lasts at most 120 seconds. A long silent operation can therefore become Unknown; this is intentional, not proof that the task stopped. OpenCode requires a heartbeat younger than ten seconds from the exact producer epoch. Disconnect/reconnect rotates the epoch so missed completions cannot leave a stale spinner. Explicit completed/failed/interrupted events survive loss of a heartbeat. Newer terminal/log evidence, rate limits and blocking questions are not hidden by an older running hook. Hooks and logs share a turn-based completion revision when the source supplies a turn ID.

## Verification

All automated tests use generated temporary fixtures; they do not read real source profiles. Run:

```sh
swift test --package-path src/AgentHud.macOS
ruby integrations/hooks/status_test.rb
node --test integrations/opencode/status.test.js
./scripts/build_app.sh
```

`AgentHud --render=full` renders synthetic spinner/question/completion/selection states with no source discovery, saved preferences, account usage fetch or hook installation. This is a layout check, not proof of live cross-app navigation. Live validation on this Mac (2026-11-18) observed GPT and OpenCode lifecycle-driven spinners, completion dots, direct desktop routes, and acknowledgement clearing. Claude was verified against the native running/unread labels, including switching from a blank compose screen to the exact test conversation and clearing unread status. GPT destination content was confirmed by the user because Computer Use blocks direct inspection of that app; the desktop connector independently confirmed the test turn completed. No existing production task was prompted for these checks.

The live check also exposed and fixed three data/UI issues: `NULL` OpenCode titles discarded the entire decoded list; idle native sidebar rows buried active work; historical incomplete Claude transcripts kept a spinner alive. Empty OpenCode query output is valid, missing titles fall back to Untitled, active/attention rows sort before idle rows, and log-derived Claude execution becomes Unknown after 120 seconds without fresh evidence. Claude Code desktop metadata now coalesces with local logs as described below.

The validated bundle is `src/AgentHud.macOS/dist/AgentHud.app`. The previous executable was preserved under `dist/backup-before-desktop-routing/AgentHud.app`. A local development signing identity is recorded in the ignored `.local-signing-identity`; `CODE_SIGN_IDENTITY` overrides it for a build. This keeps the designated identity stable across rebuilds. No certificate/private key is stored in the repository. Validation: 27 Swift fixture tests, 5 Ruby collector tests, 2 Node collector tests, release signing verification, and the live checks above.

## Amp and Gemini limits (2026-11-18)

Verified source builds: Amp 1.0 (`com.ampcode.amp.macos`) and Gemini 1.144.7.1478 (`com.google.GeminiMacOS`). Both desktop sidebars are discovered without CLI integration or API credentials. Only sidebar metadata and bounded control structure are used: Amp locates the editor by role, checks only its immediate composer parent and Stop button, and verifies the canonical WebArea URL again after the control probe. Gemini checks the Stop button identifier, never joins a window title to a chat ID.

Amp unread is an independent blue dot, not a successful-completion claim. It may coexist with a running spinner. Missing or unrecognized observations preserve an existing unread mark; only recognized plain source metadata clears it. Unread rows sort before idle rows and a new unread transition unhides a dismissed row. Background-thread execution, question waiting and successful completion are not inferred from executor connectivity or absence of Stop. Native identities/unread are memory-only and are recovered from the source after restart.

Gemini exposes no reliable per-row running/completion/unread flag in this build. Its current-window response spinner is a separate non-navigable indicator excluded from thread counts. It disappears when the Stop control is no longer observed; this does not create a completed or unread thread. Row selection uses background highlighting only.

Live checks observed Amp's real sleep-test spinner and an unread marker after leaving the conversation for Projects. Double-clicking that unread HUD row returned to the exact canonical test-thread URL and source/HUD unread cleared. Gemini was opened from its blank compose screen via the exact HUD test row; generating a test answer displayed the separate window spinner, and finishing removed it without fabricating a completion. Existing test conversations were used and no production task was prompted. The previous installed build is backed up under `dist/backup-before-amp-gemini/AgentHud.app`.

## Recent lists and subagent families

The full sidebar was previously displayed for the newly added native providers; their first observation timestamp is not a source activity timestamp. Presentation now retains working, input/approval waiting, future rate limits, and unread items independently of age. Ordinary local-file sessions follow the configured activity window (60 minutes by default). The former fixed five-row native fallback and selected-row exception have been removed. Undated idle rows stay hidden; only actual observed work/new unread transitions within the window or current attention evidence can surface them. Reading an existing unread item does not manufacture recent activity. Broad discovery continues so off-list status changes can surface.

Codex `parent_thread_id` / `source.subagent.thread_spawn.parent_thread_id` and OpenCode V2 `parent_id` establish explicit same-app ancestry. Names, folder paths and fork metadata are never used to guess a parent. Subagent rows, disclosure buttons, counts and attention badges are hidden. A validated running/thinking/starting descendant makes the root thread spin in both full and mini mode, including nested descendants through old intermediate ancestors. The aggregate is presentation-only: the root's own completion, unread state, navigation target, sounds and auto-resume inputs remain unchanged. Child waiting/unread/completed states do not produce a spinner or keep an otherwise old root visible. Child completion-only unread records are no longer persisted or restored: those hidden rows have no acknowledgement UI. Discovered child execution state is still available for the root spinner; root completion records are unchanged.

Codex can fetch up to 64 missing ancestors' first `session_meta` records, including parents needed by restored pending completions. OpenCode queries the latest 100 sessions plus explicit retained parents and their ancestors (300 IDs maximum). Ancestor-only context cannot replay lifecycle spools and does not pretend to be recent activity. Missing, conflicting, cross-app, self-referential, cyclic or over-depth parent chains are hidden. Clearly identified subagents with no usable parent are excluded from roots, auto-resume, limit notifications and state sounds. Amp's `Created by Another Thread` metadata identifies generated child entries but exposes no verified parent ID, so these entries are hidden. Claude/Gemini sidebar rows do not expose a verified parent relationship and are not grouped by title.

Validation for this change: 36 Swift fixture tests, including old-parent provider discovery, restored-parent context, stale completion replay prevention, null metadata, native quotas, nested/cyclic/orphan families, child acknowledgement independence and excluded subagent auto-resume/notifications.

Historical verification of the superseded folding UI on 2026-11-18: the installed signed build displayed 22 default rows; expanding the current Codex parent's disclosure added its child immediately below it (23 rows), and collapsing returned to 22 without acknowledging the child's Completed marker. Parent controls displayed descendant/attention counts, and mini mode showed the independent orange descendant marker. The app was restored to its full, collapsed-family view. The previous bundle is preserved at `dist/backup-before-thread-families/AgentHud.app`.

## Source dates (2026-11-18)

Gemini 1.144.7.1478 stores canonical chat IDs and message creation times in `~/Library/Caches/com.google.GeminiMacOS/Gemini/userN/ChatInfo2.store`. The reader selects only chat ID, database UUID and `MAX(ZCHATMESSAGESTOREDMODEL.ZCREATEDTIME)` joined by exact chat ID. It never reads encrypted proto payloads, message text, authentication data, or uses cache-file modification time. Cocoa reference dates are converted to `Date`; invalid/future values are rejected. A chat without cached message dates stays hidden. Opening the existing test conversation left its November 17 message date unchanged; sending the approved date-test message updated that exact ID to November 18 02:14:07 UTC.

The user independently verified `googlegemini://conversation/<chat-id>` opens the exact test conversation in Gemini; browser tooling disallows custom schemes, so that route confirmation was performed by the user in Chrome. Runtime routes target the Gemini bundle explicitly and revalidate the canonical ID and database UUID. The desktop cache encrypts titles. AgentHUD looks up recent titles together on Chrome's signed-in Gemini home page. It matches the web link to the cache's server ID (`ZROBINCONVERSATIONID`) and keeps the local ID (`ZCHATUUID`) for desktop navigation. Automatic lookup never opens a visible tab. Settings offers a one-time Gemini sign-in using a dedicated AgentHUD browser profile. Headless Chrome subsequently reads matching sidebar link titles through an anonymous child-process pipe after checking the Gemini home origin and path. A signed-out or busy profile keeps cached titles. An already open Gemini home page can also supply titles. It caches confirmed titles and retains the date label if the account, page or mapping is unavailable. The window-level spinner remains separate from these rows.

This reader is validated for this Mac's single cached profile. Multiple profile stores disable the history reader, and a replaced database invalidates prior references. A live sidebar is required, but this does not independently prove every possible account-switch/logout state: active-account binding beyond the manually verified single-cache configuration is a known limitation. Cache/decode/schema failures clear history rows instead of restoring stale data. The existing 60-minute activity setting controls which dated rows are shown.

Amp historical dates remain unavailable: the explicitly authorized shared group folder contained no regular data files in a bounded inventory; its other app-container roots denied access. No broader access was granted. Temporary inventory code, folder-permission UI and saved bookmark were removed after the investigation. Amp retains current running/unread evidence and recently observed work, without displaying a fixed five historical rows. Per-message relative timestamps in the current web view were not treated as a complete thread-history index.

Final validation: 39 Swift fixture tests passed; localization copies match, diff checks and release code-signature verification passed. The signed installed build was restarted and its HUD displayed eight eligible roots, including the Gemini test conversation's actual last-message timestamp (2026-11-18 11:14:07 KST) and Amp's source-unread row, with no fixed-five idle fallback. A bounded live-sidebar structure check handles expired AX row references without requiring a full history scan. Independent risk review reported no remaining critical/warning findings. Previous installed bundle: `dist/backup-before-source-dates/AgentHud.app`.

## Recently reviewed Amp threads

A successful HUD-to-Amp native navigation or an observed source unread-to-read transition records a separate `lastViewedAt`. This keeps an otherwise undated Amp row visible for the configured activity window (default 60 minutes). Reading clears only the source's unread marker; no work timestamp or successful completion is invented. Initial plain/selected rows, repeated polls, failed routes, and other apps do not update this clock. The tooltip labels it as last reviewed.

Only a bounded timestamp index (up to 1,024 IDs from the past seven days) persists across restarts; a thread must be rediscovered from the live native source before being displayed. Missing source rows and explicitly hidden rows remain absent. The former subagent fold labels have since been removed in favor of root-only execution indicators.

Root-only regression validation: 44 Swift tests passed, covering nested running descendants, stop/wait/completion transitions, legacy hidden-child IDs, invalid parent chains, unchanged root completion/waiting evidence, and removal of 70 legacy child-only pending completions across restart. Independent risk review found no remaining critical/warning issues. The previous installed bundle is preserved at `dist/backup-before-root-only/AgentHud.app`.

## Verified Claude desktop/local coalescing

Claude's own local metadata maps `local_<UUID>` desktop IDs to `cliSessionId` transcript UUIDs. The desktop provider replaces anonymous Claude AX rows and produces the same canonical `claude:<UUID>` identity as local logs. One explicit pair yields one row, preserving the local project, usage and process ID. Equal titles never establish identity. Duplicate CLI references remain separate canonical desktop IDs instead of guessing a match. Generated non-user forks remain hidden.

Navigation opens `claude://claude.ai/epitaxy/local_<UUID>` in the installed Claude bundle, raises the window with the exact corresponding HTTPS WebArea URL and rechecks that URL. Metadata lookup runs on a utility task. VS Code remains the fallback. Anonymous AX button identities and manual title connections are not needed.

The provider reads one unambiguous cached account/profile, with at most 4,096 records/256 MiB total and one MiB per file, owner/type/path checks, and a stat-keyed decoded-metadata cache. Multiple cached profiles fail closed. Only allowlisted identity, title, project, activity, focus, completion-count and child metadata is decoded; prompts/auth configuration are not exposed. Format and URI were checked against the installed Claude desktop app on 2026-11-18.

An increase in `completedTurns` is explicit successful-result evidence (verified in the installed app); its initial value is only a baseline. A newer activity timestamp cannot replay an old count's completion. A canonical current composer Stop control provides running evidence; disappearance alone does not fabricate completion. Local question/approval/error/rate-limit states are preserved. Live focused canonical windows acknowledge the current result; historical focus acknowledges only a local completion with a known earlier timestamp. Older metadata completion/read evidence cannot consume a newer local result. Completion aliases prevent replay when a source disappears or the HUD restarts.

Validation: 52 Swift tests covering canonical merges, equal-title separation, ambiguous profiles/IDs, cached decoding, successful counter increments, baseline/new-activity behavior, child filtering, desktop-first routing, completion/read source changes and restart persistence. Previous bundle: `dist/backup-before-claude-merge/AgentHud.app`.

Live validation after signed bundle replacement: all 583 local desktop metadata records decoded; the reported transcript UUID mapped to its exact desktop UUID. HUD displayed one row for the verified conversation. Double-click opened Claude desktop at `claude.ai/epitaxy/local_<UUID>`, confirmed by the canonical WebArea URL without reading message bodies. No message was sent. Independent final risk review: critical 0, warning 0.
