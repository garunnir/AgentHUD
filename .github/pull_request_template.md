## 변경 내용

<!-- 무엇을, 왜 바꿨는지 설명해 주세요. 관련 이슈가 있으면 연결해 주세요 (예: Closes #12). -->

## 확인 방법

<!-- 리뷰어가 동작을 확인하는 방법. UI 변경이면 전/후 스크린샷을 첨부해 주세요. -->

## 체크리스트

- [ ] `./scripts/update-vda.ps1 -Verify` 통과
- [ ] `dotnet build AgentHud.sln -c Release` 성공
- [ ] `dotnet run --project tests/AgentHud.Tests/AgentHud.Tests.csproj -c Release` 통과
- [ ] 동작 변경 시 테스트 추가 또는 갱신
- [ ] 필요한 경우 README/문서 갱신
- [ ] `src/AgentHud/native/`의 DLL·`vda.json`을 직접 수정하지 않음
