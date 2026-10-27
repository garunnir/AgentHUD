using AgentHud.Models;

namespace AgentHud;

// 세션별로 작업(턴)이 시작된 시각을 기억해 완료 때 걸린 시간을 돌려준다.
// 턴 중의 승인·입력 대기는 같은 턴으로 보고, idle·중단·한도 같은 쉬는 상태가 오면 기록을 지운다.
public sealed class TurnTimer(TimeProvider? time = null)
{
    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private readonly Dictionary<string, DateTimeOffset> _since = [];

    // record=false면 새 턴을 기록하지 않는다(앱 시작 직후처럼 실제 시작 시각을 모를 때). 완료로 바뀐 순간에만 값이 있다
    public TimeSpan? Observe(string id, AgentState state, bool record = true)
    {
        if (state is AgentState.Starting or AgentState.Working or AgentState.Thinking or AgentState.WaitingForInput or AgentState.WaitingForApproval)
        {
            if (record) _since.TryAdd(id, _time.GetUtcNow());
            return null;
        }
        if (!_since.Remove(id, out var start)) return null;
        return state == AgentState.Completed ? _time.GetUtcNow() - start : null;
    }

    public void Forget(string id) => _since.Remove(id);
}
