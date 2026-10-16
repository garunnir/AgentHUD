# Codex 일반 명령 승인 대기 감지 조사

Agent HUD가 Codex Work/VS Code의 일반 명령 승인 창(`Allow ChatGPT to run this command?`)을 노란색으로 표시할 수 있는지 조사한 기록입니다.

조사 시점: 2026-10-16, Windows, `openai.chatgpt` 26.1007.21434.

## 현재 상태

HUD의 `CodexProvider`는 `~/.codex/sessions/**/rollout-*.jsonl`을 읽습니다. 함수 호출이나 code-mode `exec` 입력에 `sandbox_permissions: "require_escalated"`가 명시된 경우는 `WaitingForApproval`로 감지할 수 있습니다. 호출이 실행 셀을 반환하고 이후 `wait` 호출로 끝나는 경우도 추적합니다.

Codex 앱이 일반 명령에 자체적으로 띄우는 승인 창은 rollout에 승인 요청이라는 사실이 명시되지 않을 수 있습니다. 이때 호출은 실행 중인 명령과 동일하게 보여 HUD가 파란색으로 남습니다.

## 확인한 로컬 신호

실제 승인 사례를 `~/.codex/logs_2.sqlite`에서 확인했습니다. 일반 명령 승인도 사용자가 응답한 뒤에는 다음 기록이 남습니다.

1. `codex_app_server::outgoing_message`: `CommandExecutionRequestApproval` 응답
2. `codex_app_server::outgoing_message`: `serverRequest/resolved`
3. `codex_core::session::handlers`: `ExecApproval { id: "exec-...", turn_id: Some("..."), decision: Approved/Denied }`

세 번째 행의 `thread_id` 열로 HUD 세션과 정확히 연결할 수 있습니다. 구체적인 사용자 데이터와 ID는 문서에 보관하지 않습니다.

승인 창이 열린 시점에는 상세 승인 요청 payload가 DB에 남지 않았습니다. 관찰된 순서는 다음과 같습니다.

```text
ToolCall: exec (thread_id 포함)
→ thread/status/changed
→ item/started
→ 사용자가 승인 또는 거절할 때까지 관련 진행 기록이 멈춤
→ CommandExecutionRequestApproval 응답
→ serverRequest/resolved
→ ExecApproval (thread_id, turn_id, decision 포함)
```

rollout에는 `exec` 호출이 즉시 기록되고 결과는 승인 이후에 추가되지만, 그 사이가 승인 대기인지 실제 명령 실행 중인지는 rollout만으로 구분할 수 없습니다.

## 구현 선택지

### logs_2.sqlite 증분 감지

`logs_2.sqlite`를 읽기 전용으로 0.5~1초 간격 폴링하고, 로그의 증가하는 `id`를 워터마크로 사용합니다.

- `ToolCall: exec thread_id=...`와 직후 app-server 상태 이벤트를 승인 대기 후보로 기록합니다.
- 같은 thread의 `ExecApproval`, rollout의 도구 결과, 턴 완료 또는 중단 이벤트가 나오면 후보를 해제합니다.
- SQLite WAL을 읽기 전용으로 동시에 조회할 수 있었으며, `id` 기반 증분 조회의 비용은 작습니다.

이 방식은 현재 앱 구조를 바꾸지 않고 구현할 수 있습니다. 다만 즉시 실행되는 일반 명령도 시작 흐름이 비슷해 오탐 가능성이 있습니다. 상태 이벤트의 `thread_id`가 `NULL`인 경우가 있어 가까운 시각의 `ToolCall`과 연결하는 추론이 필요합니다. 로그 레벨, 보존 정책, 내부 스키마가 Codex 업데이트로 바뀔 가능성도 있습니다.

### app-server 이벤트 직접 구독

Codex app-server 프로토콜의 승인 요청 이벤트를 받으면 thread, turn, item 단위로 정확하게 처리할 수 있습니다. 설치된 `codex.exe`에는 app-server의 WebSocket listen, proxy, daemon 관련 기능이 있습니다.

현재 VS Code 확장은 app-server와 `stdio`로 직접 연결됩니다. Agent HUD가 이미 연결된 stdio 스트림에 제3자로 붙을 수는 없습니다. 이 방식을 쓰려면 VS Code 확장과 app-server 사이에 프록시를 넣거나, 둘이 공용 daemon/WebSocket endpoint를 사용하도록 연결 구조를 바꿔야 합니다. 정확하지만 침습적이고 확장 업데이트에 취약합니다.

## 확인했지만 사용할 수 없었던 저장소

- `state_5.sqlite`: thread와 rollout 경로, 승인 정책은 있으나 현재 승인 대기 레코드는 없음
- `thread_history_1.sqlite`: turn/item 기록은 있으나 pending approval 상태는 없음
- `queue_1.sqlite`: 승인 상태와 무관
- 프로세스와 열린 포트: 기존 stdio 연결을 공유할 수 있는 신호 없음

## 다음 조사 순서

1. `logs_2.sqlite` 증분 리더를 UI와 분리된 프로토타입으로 작성합니다.
2. 같은 세션에서 승인 없는 짧은 명령, 오래 실행되는 명령, 승인 후 실행, 승인 거절을 각각 여러 번 기록합니다.
3. `ToolCall` 뒤 이벤트 조합과 시간 간격을 비교해 후보 판정 규칙을 정합니다.
4. 오탐과 누락률이 충분히 낮으면 `CodexProvider` 상태에 합칩니다.
5. Codex가 공식적인 기존 app-server 구독 방법을 제공하면 로그 추론을 프로토콜 이벤트로 교체합니다.

검증할 핵심은 승인 요청이 열린 순간을 얼마나 빨리, 정상 실행과 구별하여 찾을 수 있는지입니다. 승인 응답 이후의 식별과 세션 연결은 이미 확인됐습니다.
