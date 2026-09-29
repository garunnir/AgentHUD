# HUD 항목 → VS Code 대화 열기 조사 기록

HUD 리스트 항목을 더블클릭했을 때 해당 에이전트의 VS Code 대화 화면으로 바로 이동시키려던 시도의 기록입니다. 결론부터 말하면 **프로젝트 창 이동은 되지만, 사이드바에서 쓰는 Claude 대화를 바꾸는 방법은 찾지 못했습니다.**

조사 시점: 2026-09-29, Windows 11, VS Code stable, `anthropic.claude-code` 2.1.284, `openai.chatgpt` 26.917.62051.

## 현재 구현

`MainWindow.OpenInVsCode` ([MainWindow.xaml.cs](../src/AgentHud/MainWindow.xaml.cs))는 두 단계로 동작합니다.

1. `cmd /c code <폴더>`로 세션의 Git 루트(없으면 cwd)를 엽니다. 이미 열린 폴더면 기존 창이 앞으로 옵니다. `code`가 없으면 `vscode://file/<경로>`로 대체합니다.
2. 700ms 뒤 대화 URI를 셸로 엽니다.
   - Claude: `vscode://anthropic.claude-code/open?session=<sessionId>`
   - Codex: `vscode://openai.chatgpt/local/<sessionId>`

1단계가 먼저 필요한 이유는 `vscode://` URI가 **마지막으로 활성화된 VS Code 창**으로 전달되기 때문입니다. 창을 먼저 바꾸지 않으면 다른 프로젝트 창으로 전달됩니다.

## 확인한 사실

### Claude Code 확장

`extension.js`의 `handleUri`가 처리하는 경로는 두 가지입니다.

- `/install-plugin?plugin=&marketplace=`
- `/open?session=<id>&prompt=<text>`: `claude-vscode.primaryEditor.open(session, prompt)`를 실행합니다. `session`은 `/`, `\`, `..`, NUL이 없는 문자열이어야 하며, 조건에 맞지 않으면 아무 반응 없이 무시됩니다.

`primaryEditor.open` → `createPanel` 흐름은 **에디터 탭 전용**입니다.

- 그 세션을 가진 에디터 탭이 있으면 `reveal()`로 앞으로 가져옵니다.
- 기억된 탭이 있으면 되살립니다.
- 둘 다 없으면 새 웹뷰 패널을 만들어 세션을 이어받게 합니다.

사이드바는 다르게 동작합니다.

- `claude-vscode.sidebar.open`은 인자가 없고, `claudeVSCodeSidebarSecondary.focus`로 초점만 옮깁니다.
- 사이드바에 표시할 세션을 밖에서 지정하는 명령이나 URI는 없습니다. 대화 전환은 웹뷰 안의 세션 목록에서만 할 수 있습니다.
- 같은 세션을 다른 화면(사이드바)이 이미 쥐고 있으면 `siblingSurfaceHoldsSession` 검사에 걸립니다.

실제로 사이드바에서 실행 중인 세션 ID로 `/open` URI를 보냈을 때, 창은 이동했지만 대화는 바뀌지 않았습니다. VS Code 로그(`%APPDATA%\Code\logs\...`)에도 URI 처리 기록은 남지 않았습니다.

### 세션 ID

`~/.claude/sessions/<pid>.json`의 `sessionId`는 확장이 사용하는 UUID와 같습니다. 확장에서 시작한 세션은 `"entrypoint": "claude-vscode"`로 표시되므로, 필요하면 터미널 CLI 세션과 구분할 수 있습니다.

### Codex 확장

`handleUri`는 URI 경로를 그대로 웹뷰 라우트로 넘깁니다(`navigateToRoute`). 코드에는 `/local/${conversationId}` 라우트가 여러 곳에 있습니다. **다만 HUD가 읽는 `session_meta`의 ID로 실제 대화가 열리는지는 확인하지 않았습니다.** CLI에서 시작한 대화는 특히 확인이 필요합니다.

### Windows 프로토콜 등록

`HKCU\Software\Classes\vscode\shell\open\command` → `Code.exe --open-url -- "%1"`. 정상적으로 등록되어 있었으므로 전달 경로 문제는 아닙니다.

## 남은 선택지

| 방법 | 결과 | 비고 |
| --- | --- | --- |
| Claude 확장의 Preferred Location을 editor로 사용 | 현재 코드로 해당 대화 탭이 앞으로 옴 | 코드 수정 불필요, 사용 습관을 바꿔야 함 |
| 대화 URI를 보내지 않고 창 이동만 | 사이드바 사용자에게 부작용 없음 | 2단계 제거 |
| HUD 전용 보조 VS Code 확장 | 사이드바를 열 수는 있음 | 사이드바 대화 전환은 Claude 확장이 외부에 열어 두지 않아 불가 |
| 터미널 CLI 세션이면 그 콘솔 창 활성화 | Claude 세션은 PID가 있어 가능성 있음 | 미구현 |

## 다시 시도할 때 확인할 것

- 확장이 업데이트되면 `handleUri`와 `sidebar.open`의 시그니처가 바뀌었는지 먼저 확인하세요. 사이드바 세션 지정이 추가됐는지가 핵심입니다.

  ```bash
  cd ~/.vscode/extensions/anthropic.claude-code-*/
  grep -oE 'handleUri\(_\)\{.{0,900}' extension.js
  grep -oE '"claude-vscode.sidebar.open",async\(.{0,300}' extension.js
  ```

- VS Code가 꺼져 있으면 확장이 준비되기 전에 URI가 도착할 수 있습니다. 700ms 대기로 부족한지도 확인해야 합니다.
