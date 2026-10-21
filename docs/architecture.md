# Agent HUD 내부 구조와 개발 참고사항

사용자용 설치·사용 설명은 [README](../README.md), 기여 절차와 검사 명령은 [CONTRIBUTING](../CONTRIBUTING.md)을 참고하세요. 이 문서는 외부 도구의 내부 형식에 의존하는 구현과 유지보수 정보를 모읍니다.

## 세션 탐색 구조

Agent HUD는 provider → discovery service → thread-safe registry → HUD 순서로 상태를 전달합니다. 파일 변경 알림과 3초 주기의 보정 탐색을 함께 사용합니다.

### Claude Code

- `~/.claude/sessions/*.json`의 PID, session ID, cwd, 상태를 읽고 실제 프로세스 생존 여부와 결합합니다.
- 대화 로그에서 `AskUserQuestion`, background task, 사용량 제한 오류와 토큰 사용량을 해석합니다.
- VS Code가 미리 생성한 대화 없는 idle 프로세스는 숨깁니다.

### Codex

- `~/.codex/sessions/**/rollout-*.jsonl`의 `session_meta`와 최근 이벤트를 읽습니다.
- 변경된 파일의 마지막 256KB만 읽으며 파일 크기와 수정 시각을 캐시합니다. Windows가 열린 파일의 수정 시각을 갱신하지 않는 경우에도 크기 변화로 다시 읽습니다.
- `task_started`는 Working, reasoning은 Thinking, `task_complete`는 Idle, `turn_aborted`는 Stopped으로 해석합니다.
- thread별 PID 연결이 없으므로 최근 이벤트가 설정된 active window 안에 있으면 활성 상태로 추정합니다. 오래 조용한 작업과 실제 대기 세션의 생존 여부는 확정할 수 없습니다.
- 내부 guardian 세션은 사용자 대화가 아니므로 제외합니다.

### OpenCode

Windows provider는 `~/.local/share/opencode/opencode.db`의 최근 세션을 읽습니다. `session`과 `session_v2` 스키마를 지원합니다.

- legacy message는 working, completed, stopped, error를 판정할 수 있습니다.
- legacy 최신 assistant message에 실행 중인 `question` tool part가 있으면 WaitingForInput으로 표시합니다. 완료·오류·pending 상태와 과거 message의 질문은 제외합니다.
- V2 metadata만으로는 실행 중인 turn이나 실시간 질문·승인 상태를 판정할 수 없습니다.

## 질문과 승인 상태

### Codex

- 동기 `request_user_input`은 같은 `call_id`의 output이 기록될 때까지 WaitingForInput입니다.
- `request_user_input_async`는 전달 승인 output이나 `task_complete`로 끝내지 않고, 다음 user message나 abort까지 WaitingForInput으로 유지합니다.
- 명시적인 `sandbox_permissions: "require_escalated"` 호출은 WaitingForApproval로 추론합니다. code-mode `exec`가 실행 셀을 반환하면 뒤따르는 `wait`의 최종 결과까지 추적합니다.
- Codex 앱이 일반 명령에 자체적으로 띄우는 승인은 rollout만으로 정확히 식별할 수 없습니다. 후속 조사는 [Codex 일반 명령 승인 대기 감지 조사](codex-approval-detection.md)에 기록되어 있습니다.

### Claude Code

- metadata의 `waiting`, `waiting_for_input`, `waiting_for_approval` 상태를 매핑합니다.
- 로그의 `AskUserQuestion` tool use를 찾고 같은 ID의 `tool_result`가 기록되면 질문 대기를 해제합니다.
- 질문과 승인은 사용량 제한 표시보다 우선합니다.

## 완료 상태

registry는 working, thinking 또는 waiting-for-approval에서 idle/completed로 바뀌는 순간을 완료로 기록합니다. 읽지 않은 완료는 5분 동안 유지하며, 사용자가 세션을 열면 확인된 것으로 처리합니다. 다시 작업이 시작되면 이전 완료 표시를 지웁니다.

## 사용량과 제한

### Codex

rollout의 `token_count.rate_limits`에서 primary/secondary window를 읽습니다. 사용량 제한 오류의 reset 문구를 우선 사용하고, 파싱할 수 없으면 완전히 소진된 window의 `resets_at`, 마지막으로 1시간 fallback을 사용합니다.

### Claude

서버 제한은 로컬 세션 metadata에 없으므로 다음 소스를 사용합니다.

- **CLI status line link (기본값)**: `~/.claude/settings.json`에 status line script를 등록해 `rate_limits`를 `claude-limits.json`으로 받습니다. 처음 실행할 때 한 번 조용히 연동하고(`ClaudeLimitLink.LinkQuietly`), 그 선택은 `placement.json`의 `ClaudeLinkEnabled`에 저장됩니다. 기존 status line이 있으면 `claude-statusline-inner.txt`에 보존해 이어서 실행(체이닝)하고, 연동을 해제하면 복원합니다. VS Code 확장 안에서는 status line이 실행되지 않으므로 그 경로로만 작업하면 값이 멈춥니다.
- **claude.ai usage API (선택, opt-in)**: WebView2를 통해 5분마다 조회합니다. sessionKey는 Windows DPAPI로 암호화하여 `%LOCALAPPDATA%\AgentHud`에 저장합니다. 비공식 endpoint이므로 변경될 수 있고, `ClaudeApiEnabled`가 꺼져 있으면 저장된 키가 있어도 조회하지 않습니다(WebView2도 생성하지 않음). 주로 status line이 실행되지 않는 VS Code 확장 사용자를 위한 보조 경로입니다.
- **선택 정책**: `ClaudeLimitPolicy.Pick`(`src/AgentHud.Core/ClaudeLimits.cs`)이 두 소스 중 "더 신선하고 유효한" 쪽을 고릅니다. status line은 12시간, API는 30분이 지나면 오래된 것으로 봅니다. status line은 추가로, 기록 이후 Claude 세션이 더 움직였다면(활동 시각이 `UpdatedAt + 15분`보다 뒤) 오래된 것으로 봅니다 — status line이 실행되지 않는 곳(VS Code 확장)에서 작업했다는 뜻이기 때문입니다. 두 소스의 창은 섞지 않고(계정이 다를 수 있음), 창별로 `resets_at`이 이미 지났으면 그 창만 따로 무효화합니다. 동률이면 공식 CLI 값인 status line이 이깁니다.
- 선택된 값이 오래됐으면 마지막으로 알려진 숫자에 `Usage.StaleValue`("42% · Stale")로 표시를 붙이고, 그 창의 `resets_at`마저 지나 숫자가 무의미해졌으면 `Usage.Stale`("Stale")만 보여줍니다. 두 소스 모두 값이 없으면 HUD가 발견한 로그의 input, output, cache creation token 합계를 표시합니다.
- macOS는 같은 `claude-limits.json` 규약을 `~/Library/Application Support/AgentHud`의 `claude-statusline.sh`로 구현합니다(`ClaudeLimitLink.swift`). claude.ai usage API는 opt-in으로 `ClaudeUsageApi.swift`에 포팅했습니다. sessionKey·Organization ID를 붙여 넣는 대신 앱 안의 WKWebView에서 한 번 로그인하고, 세션은 전용 WebKit 데이터 저장소에만 남습니다. 조회는 Cloudflare 때문에 화면 밖 WKWebView로 하며, org는 `/api/organizations`에서 Pro/Max 플랜이 있는 것을 자동으로 고릅니다.

## 자동 재개

reset 1분 뒤 conversation cwd에서 창 없이 다음 명령을 한 번 실행하고, 설정된 메시지를 stdin으로 보냅니다.

| Agent | Command | CLI lookup |
| --- | --- | --- |
| Claude | `claude --resume <id> -p --permission-mode acceptEdits` | PATH, 이후 VS Code 확장의 `claude.exe` |
| Codex | `codex exec resume --skip-git-repo-check -c sandbox_mode=workspace-write <id> -` | PATH, 이후 VS Code 확장의 `codex.exe` |

파일 편집만 자동 승인됩니다. 대화가 이미 열린 VS Code 탭에는 CLI의 진행이 실시간으로 나타나지 않을 수 있습니다. 30분 이상 지난 reset과 subagent는 재개하지 않으며, 실행 기록은 `%LOCALAPPDATA%\AgentHud\auto-resume.log`에 저장합니다.

## VS Code 열기

HUD는 먼저 `code <project>`로 대상 프로젝트 창을 활성화하고, 잠시 뒤 extension URI를 엽니다.

- Claude: `vscode://anthropic.claude-code/open?session=<id>`
- Codex: `vscode://openai.chatgpt/local/<id>`

Claude URI는 editor tab을 대상으로 하며 sidebar 대화를 외부에서 전환할 수 없습니다. 검증 내용은 [HUD 항목 → VS Code 대화 열기 조사 기록](vscode-session-open.md)에 있습니다.

## Windows 가상 데스크톱

MIT 라이선스의 `VirtualDesktopAccessor.dll`로 HUD 창을 모든 데스크톱에 pin하고 5초마다 확인합니다. pin API가 실패하면 Windows `IVirtualDesktopManager`로 현재 foreground window의 데스크톱을 찾아 HUD를 이동합니다. 대상 데스크톱에 foreground window가 없으면 사용자가 창을 활성화할 때까지 이동이 늦어질 수 있습니다.

`src/AgentHud/native/`의 바이너리와 manifest는 직접 수정하지 않습니다. 정기 workflow가 upstream release를 검증하고 자동 PR을 생성합니다.

## CI와 릴리스

Build workflow는 Windows에서 DLL 무결성, Release build, registry/discovery 검사를 실행합니다. macOS job은 Apple Silicon과 Intel runner에서 app bundle을 build하고 검증합니다. `v*` tag는 Windows와 macOS 배포 ZIP을 만든 뒤 모든 build가 성공하면 release를 생성합니다.
