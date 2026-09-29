# Agent HUD

Windows 전체에서 실행되는 Claude Code와 Codex 세션을 자동 발견해 보여 주는 작은 WPF HUD입니다.

## 현재 MVP

- 실제 Claude `~/.claude/sessions/*.json` 메타데이터(PID, sessionId, cwd, status)를 읽고 프로세스 생존 여부와 결합
- 실제 Codex `~/.codex/sessions/**/rollout-*.jsonl`의 `session_meta`(session_id, cwd)를 읽고 파일 활동 시각과 결합
- provider → discovery service → thread-safe registry → HUD 분리
- `FileSystemWatcher` 이벤트 + 3초 저비용 보정 polling
- 프로젝트/Git worktree 식별, 안정적인 provider session ID, 종료 세션의 짧은 표시
- borderless/topmost/taskbar-hidden HUD, 위치 저장, 더블클릭 확장
- `PinWindow`으로 HUD 창을 모든 Windows 가상 데스크톱에 표시

## 실행

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

Codex는 현재 로컬 데이터에 process ID나 명시적 완료 상태가 없으므로, 마지막 파일 활동 15초 이내는 Working, 2분 이내는 active/waiting으로 보수적으로 표시합니다. Claude/Codex 내부 포맷이 바뀌면 provider만 수정하면 됩니다.

가상 데스크톱 고정에는 MIT 라이선스의 `VirtualDesktopAccessor.dll`을 사용합니다. 창 표시 후 고정하고 5초마다 재확인합니다. 고정 API가 실패하면 Windows의 `IVirtualDesktopManager`로 현재 활성 창의 데스크톱을 확인해 HUD를 이동합니다(250ms 간격). 전환한 데스크톱에 활성 창이 없으면 창을 활성화할 때까지 이동이 지연될 수 있습니다.

GitHub Actions는 push/PR마다 DLL 무결성 검사와 Release 빌드, Registry 검사를 수행합니다. 매주 월요일에는 VirtualDesktopAccessor의 최신 안정 릴리스를 확인하고 변경이 있으면 `deps/virtualdesktopaccessor` PR을 자동 생성합니다.
