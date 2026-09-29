# 기여 가이드

Agent HUD에 관심을 가져 주셔서 감사합니다. 버그 제보, 기능 제안, PR 모두 환영합니다.

## 시작하기 전에

- 큰 변경(새 provider, UI 구조 변경, 새 의존성 추가 등)은 먼저 이슈로 방향을 맞춰 주세요.
- 작은 버그 수정이나 문서 개선은 바로 PR을 보내도 됩니다.

## 개발 환경

- **Windows 10/11** (WPF 앱이므로 Windows에서만 빌드·실행됩니다)
- **.NET 9 SDK**
- **Windows PowerShell 5.1** 이상
- 권장: VS Code + C# Dev Kit (`F5`로 디버그, 자세한 내용은 [README](README.md#개발-환경-vs-code에서-빌드디버그))

## 빌드와 검사

PR을 올리기 전에 로컬에서 CI와 같은 검사를 통과하는지 확인해 주세요.

```powershell
./scripts/update-vda.ps1 -Verify
dotnet build AgentHud.sln -c Release
dotnet run --project tests/AgentHud.Tests/AgentHud.Tests.csproj -c Release
```

GitHub Actions의 **Build** 워크플로가 PR마다 같은 단계를 실행합니다. 처음 기여하는 경우 관리자가 워크플로 실행을 승인한 뒤에 돌아갑니다.

## 테스트

- 테스트는 [tests/AgentHud.Tests/Program.cs](tests/AgentHud.Tests/Program.cs)의 단순 `Assert` 기반 콘솔 프로그램입니다.
- 동작을 바꾸거나 버그를 고칠 때는 해당 경우를 확인하는 검사를 함께 추가해 주세요.
- 실제 사용자 홈 폴더(`~/.claude`, `~/.codex`)에 의존하지 말고, 기존 테스트처럼 임시 폴더에 가짜 세션 파일을 만들어 사용하세요.

## 코드 스타일

- 주변 코드의 스타일(네이밍, nullable, 파일 범위 namespace, `record`/`with` 사용 등)을 따라 주세요.
- 새 에이전트 지원은 `IAgentProvider`를 구현하는 provider로 추가하고, 포맷 파싱은 provider 안에 가둬 주세요.
- 외부 프로그램(Claude Code, Codex, VS Code 확장)의 내부 포맷이나 URI에 의존하는 경우, 확인한 버전을 주석이나 문서에 남겨 주세요.

## 네이티브 DLL (`VirtualDesktopAccessor.dll`)

- `src/AgentHud/native/`의 DLL과 `vda.json`은 **직접 수정한 PR을 받지 않습니다.**
- 업데이트는 매주 실행되는 **Update VirtualDesktopAccessor** 워크플로가 upstream 릴리스를 검증한 뒤 자동 PR로 올립니다.
- 특정 버전이 필요하면 이슈로 요청해 주세요.

## PR 규칙

- 한 PR에는 하나의 목적만 담아 주세요.
- 커밋 메시지와 PR 제목은 변경 내용을 짧게 설명하는 영어 명령형을 권장합니다 (예: `Fix Codex session state after turn abort`).
- UI 변경은 전/후 스크린샷을 첨부해 주세요.
- 문서와 UI 문자열은 한국어를 기본으로 합니다.

## 라이선스

기여한 코드는 저장소의 [MIT License](LICENSE)로 배포되는 데 동의한 것으로 간주합니다.
