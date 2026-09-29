# Agent HUD

Windows 전체에서 실행되는 Claude Code와 Codex 세션을 자동 발견해 보여 주는 작은 WPF HUD입니다.

## 현재 MVP

- 실제 Claude `~/.claude/sessions/*.json` 메타데이터(PID, sessionId, cwd, status)를 읽고 프로세스 생존 여부와 결합
- 실제 Codex `~/.codex/sessions/**/rollout-*.jsonl`의 `session_meta`(session_id, cwd)를 읽고 파일 활동 시각과 결합
- provider → discovery service → thread-safe registry → HUD 분리
- `FileSystemWatcher` 이벤트 + 3초 저비용 보정 polling
- 프로젝트/Git worktree 식별, 안정적인 provider session ID, 종료 세션의 짧은 표시
- borderless/topmost/taskbar-hidden HUD, 위치 저장, 헤더·빈 영역 더블클릭 확장
- 세션 항목 더블클릭 시 해당 프로젝트(Git 루트, 없으면 cwd)를 VS Code로 열고 확장 URI(`anthropic.claude-code/open?session=`, `openai.chatgpt/local/`)로 대화 탭 열기 (사이드바 대화는 전환 불가, [조사 기록](docs/vscode-session-open.md))
- `PinWindow`으로 HUD 창을 모든 Windows 가상 데스크톱에 표시

## 요구 사항

### 실행 환경

- **Windows 11**: 동봉된 `VirtualDesktopAccessor.dll`은 Windows 11용 빌드(`2024-12-16-windows11`)입니다. Windows 10에서도 HUD는 동작하지만 가상 데스크톱 고정이 실패하고 활성 창 추적 방식으로 대체됩니다.
- **.NET 9 SDK** (빌드·`dotnet run`용). 빌드된 실행 파일만 쓸 때는 **.NET 9 Desktop Runtime**으로 충분합니다.
- 감시 대상 에이전트: **Claude Code**(`~/.claude/sessions`)와 **Codex**(`~/.codex/sessions`). 둘 중 하나만 써도 되며, 폴더가 없으면 해당 provider는 비어 있습니다.
- Git은 설치하지 않아도 됩니다. 프로젝트 식별은 `.git` 폴더/파일을 직접 찾습니다.

### VS Code 연동 (세션 더블클릭)

세션 항목을 더블클릭해 VS Code로 이동하려면 다음이 모두 필요합니다. 없어도 HUD 표시에는 영향이 없습니다.

| 항목 | 필요한 이유 | 확인 방법 |
| --- | --- | --- |
| **VS Code Stable** | `vscode://` URI를 사용합니다. Insiders(`vscode-insiders://`)와 VSCodium 등 포크는 지원하지 않습니다. | — |
| **`code` 명령이 PATH에 등록** | 프로젝트 창을 먼저 앞으로 가져오는 데 사용합니다. 없으면 `vscode://file/` URI로 대체되지만, 이미 열린 창 전환이 덜 정확합니다. | `code --version` (설치 시 "PATH에 추가" 옵션 또는 명령 팔레트 **Shell Command: Install 'code' command in PATH**) |
| **`vscode://` 프로토콜 등록** | 대화 URI를 VS Code로 전달합니다. 일반 설치 시 자동 등록됩니다. | `HKCU\Software\Classes\vscode\shell\open\command` 존재 |
| **Claude Code 확장** (`anthropic.claude-code`) | Claude 세션 대화 탭 열기(`/open?session=`). 2.1.284에서 확인했습니다. | `code --list-extensions` |
| **Codex 확장** (`openai.chatgpt`) | Codex 세션 대화 열기(`/local/<id>`). 26.917.62051에서 확인했으나 실제 대화 전환은 미검증입니다. | `code --list-extensions` |
| **Claude 확장의 Preferred Location = editor** (권장) | 확장이 외부에서 사이드바 대화를 전환하는 방법을 제공하지 않아, 대화 전환은 에디터 탭에서만 됩니다. 사이드바를 쓰면 창 이동만 됩니다. | 설정 `claudeCode.preferredLocation` |

VS Code가 꺼져 있으면 확장이 준비되기 전에 URI가 도착해 대화가 열리지 않을 수 있습니다. 한 번 더 더블클릭하면 됩니다. 자세한 내용은 [조사 기록](docs/vscode-session-open.md)을 참고하세요.

### 개발 환경 (VS Code에서 빌드·디버그)

- **C# Dev Kit** (`ms-dotnettools.csdevkit`, 저장소 권장 확장): 함께 설치되는 **C#** 확장(`ms-dotnettools.csharp`)이 `F5`의 `coreclr` 디버거를 제공합니다. C# Dev Kit 라이선스 조건(Visual Studio Community 조건과 동일)을 확인하세요.
- **.NET 9 SDK**: `build`/`run registry checks` 작업이 `dotnet`을 호출합니다.
- **Windows PowerShell 5.1** 이상: `verify VirtualDesktopAccessor` 작업과 `scripts/update-vda.ps1`에 사용합니다.

## 실행

빌드된 파일은 [Releases](https://github.com/garunnir/AgentHUD/releases)에서 받을 수 있습니다. `win-x64.zip`은 .NET 9 Desktop Runtime이 필요하고, `win-x64-self-contained.zip`은 런타임이 포함되어 있습니다. `v*` 태그를 push하면 GitHub Actions가 두 파일을 빌드해 릴리스를 만듭니다.

소스에서 실행하려면:

```powershell
dotnet run --project src/AgentHud/AgentHud.csproj
```

VS Code에서는 저장소 폴더를 연 뒤 `F5`를 누르고 **Agent HUD (Debug)** 구성을 선택하면 됩니다. `Ctrl+Shift+B`는 Debug 빌드를 실행하며, 명령 팔레트의 **Tasks: Run Test Task**는 Registry 검사를 실행합니다.

현재 저장소는 설치된 SDK에 맞춰 `net9.0-windows`를 사용합니다. .NET 10 SDK 설치 후 두 `.csproj`의 TargetFramework를 `net10.0-windows`로 변경하면 됩니다.

## 검증

```powershell
dotnet build AgentHud.sln
dotnet run --project tests/AgentHud.Tests/AgentHud.Tests.csproj
```

Codex는 파일 크기와 수정 시각으로 변경을 감지하고, 변경된 로그의 마지막 256KB에서 이벤트 시각과 상태를 읽습니다. Windows에서 파일 수정 시각이 갱신되지 않아도 크기가 증가하면 반영됩니다. `task_started`는 Working, reasoning은 Thinking, `task_complete`는 Idle, `turn_aborted`는 Stopped로 표시합니다. 스레드별 PID 연결은 아직 없으므로 최근 5분 이내 이벤트가 있는 세션을 활성으로 추정합니다. 장시간 이벤트가 없는 작업이나 대기 세션의 생존 여부는 확정하지 못합니다. Claude/Codex 내부 포맷이 바뀌면 provider만 수정하면 됩니다.

가상 데스크톱 고정에는 MIT 라이선스의 `VirtualDesktopAccessor.dll`을 사용합니다. 창 표시 후 고정하고 5초마다 재확인합니다. 고정 API가 실패하면 Windows의 `IVirtualDesktopManager`로 현재 활성 창의 데스크톱을 확인해 HUD를 이동합니다(250ms 간격). 전환한 데스크톱에 활성 창이 없으면 창을 활성화할 때까지 이동이 지연될 수 있습니다.

GitHub Actions는 push/PR마다 DLL 무결성 검사와 Release 빌드, Registry 검사를 수행합니다. 매주 월요일에는 VirtualDesktopAccessor의 최신 안정 릴리스를 확인하고 변경이 있으면 `deps/virtualdesktopaccessor` PR을 자동 생성합니다.

상태 색상: 초록은 작업/추론 중, 노랑은 사용자 응답/승인 필요, 회색은 Idle(다음 지시 대기)/완료/중단, 빨강은 오류, 파랑은 상태 미확인입니다.

## 기여

버그 제보와 PR을 환영합니다. [CONTRIBUTING.md](CONTRIBUTING.md)를 참고해 주세요.
