using AgentHud.Models;

namespace AgentHud.Cleanup;

/// <summary>OS에서 수집한 프로세스 한 건. StartedAt은 UTC, WorkingSet은 바이트. 수집은 OS별(Windows: WindowsProcessLister)</summary>
public sealed record ProcessRecord(int Pid, int ParentPid, string Name, DateTime StartedAt, long WorkingSet, string? CommandLine = null, string? ExecutablePath = null)
{
    /// <summary>확장자를 뗀 이름(claude.exe → claude)</summary>
    public string BaseName => Path.GetFileNameWithoutExtension(Name);
}

/// <summary>프로세스 목록 수집기. 구현은 OS별 프로젝트에 두고 판단 로직은 모두 여기(Core)에 둔다</summary>
public interface IProcessLister
{
    IReadOnlyList<ProcessRecord> List();
}

/// <summary>WMI(Win32_Process.CreationDate)의 CIM_DATETIME 파싱: yyyyMMddHHmmss.ffffff±UUU (UUU = UTC로부터의 분)</summary>
public static class CimDateTime
{
    public static DateTime? Parse(string? value)
    {
        // 0-13 날짜시각, 14 '.', 15-20 마이크로초, 21 부호, 22-24 분 단위 시간대
        if (value is null || value.Length < 25 || value[14] != '.' || value[21] is not ('+' or '-')) return null;
        if (!int.TryParse(value.AsSpan(0, 4), out var year) || !int.TryParse(value.AsSpan(4, 2), out var month)
            || !int.TryParse(value.AsSpan(6, 2), out var day) || !int.TryParse(value.AsSpan(8, 2), out var hour)
            || !int.TryParse(value.AsSpan(10, 2), out var minute) || !int.TryParse(value.AsSpan(12, 2), out var second)
            || !int.TryParse(value.AsSpan(15, 6), out var micro) || !int.TryParse(value.AsSpan(22, 3), out var offset)) return null;
        try
        {
            var local = new DateTime(year, month, day, hour, minute, second, DateTimeKind.Utc).AddTicks(micro * 10L);
            return local.AddMinutes(value[21] == '-' ? offset : -offset);
        }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}

/// <summary>에이전트 루트 프로세스 하나와 그 자손 전부. Processes[0]은 항상 루트</summary>
public sealed record AgentProcessTree(AgentType AgentType, ProcessRecord Root, IReadOnlyList<ProcessRecord> Processes)
{
    public int Count => Processes.Count;
    public long WorkingSet => Processes.Sum(x => x.WorkingSet);
    public IEnumerable<int> Pids => Processes.Select(x => x.Pid);
}

/// <summary>종료를 아예 막는 이유. None이 아니면 체크박스를 켤 수 없다</summary>
public enum CleanupGuard
{
    None,
    /// <summary>HUD 자신이나 그 조상이 트리에 들어 있음</summary>
    SelfProcess,
    /// <summary>VS Code(Code.exe)·확장 호스트·셸 등 공용 프로세스가 트리에 들어 있음</summary>
    ProtectedProcess,
    /// <summary>같은 프로세스가 두 트리에 동시에 속함(부모 관계를 신뢰할 수 없음)</summary>
    SharedProcess,
    /// <summary>한 프로세스가 여러 대화를 호스팅함(codex app-server 등)</summary>
    SharedSession
}

/// <summary>정리 창의 한 줄. 트리 + 연결된 HUD 세션(없으면 orphan) + 안전 판단</summary>
public sealed record CleanupRow(AgentProcessTree Tree, AgentSession? Session, int SessionCount, CleanupGuard Guard, bool Ambiguous)
{
    public AgentType AgentType => Tree.AgentType;
    public int Pid => Tree.Root.Pid;
    public DateTime StartedAt => Tree.Root.StartedAt;
    /// <summary>정렬 기준: 세션이 있으면 마지막 활동, orphan이면 프로세스 시작 시각(둘 다 UTC)</summary>
    public DateTime LastActivityAt => Session is { } s ? s.LastActivityAt.ToUniversalTime() : Tree.Root.StartedAt;
    public bool IsActive => Session is { } s && ProcessCleanup.IsBusy(s.State);
    public bool CanTerminate => Guard == CleanupGuard.None;
    public bool IsShared => Guard is CleanupGuard.SharedProcess or CleanupGuard.SharedSession || SessionCount > 1;
    public string GuardText => Guard == CleanupGuard.None
        ? Ambiguous ? Loc.T("Cleanup.Guard.Ambiguous") : ""
        : Loc.T("Cleanup.Guard." + Guard);
}

/// <summary>
/// 오래된 에이전트 프로세스 트리 찾기(순수 로직). 평평한 프로세스 목록 → 루트별 트리 → HUD 세션 연결 → 안전 규칙.
/// 종료 자체는 호출자(Windows의 CleanupWindow)가 하고, 여기서는 무엇을 종료해도 되는지만 결정한다.
/// </summary>
public static class ProcessCleanup
{
    // 이름으로 알아보는 에이전트 CLI. npm 설치(claude.cmd → node.exe)처럼 이름이 다른 경우는
    // 세션이 기록한 PID(AgentSession.ProcessId)로 루트를 알아낸다
    private static readonly Dictionary<string, AgentType> AgentNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["claude"] = AgentType.ClaudeCode,
        ["codex"] = AgentType.Codex
    };
    // 세션이 알려 준 PID로 루트를 정할 때 인정하는 런타임. PID가 재사용되어 엉뚱한 프로그램이
    // 트리의 루트가 되는 일을 막기 위해, 에이전트를 실제로 실행할 수 있는 이름만 받는다
    private static readonly HashSet<string> AgentHosts = new(StringComparer.OrdinalIgnoreCase) { "node", "bun", "deno" };
    // 트리에 섞여 들어오면 그 트리는 절대 종료하지 않는다(부모 관계가 잘못 읽힌 경우의 안전망)
    private static readonly HashSet<string> ProtectedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "code", "code - insiders", "codium", "electron", "devenv", "rider64", "idea64",
        "agenthud", "explorer", "winlogon", "wininit", "csrss", "services", "lsass", "svchost", "system", "smss"
    };
    // Claude 데스크톱 앱도 claude.exe라 이름만으로는 CLI와 구분되지 않는다. 설치 경로(Squirrel: %LOCALAPPDATA%\AnthropicClaude,
    // MSIX: WindowsApps)나 루트와 같은 이름의 Electron 자식(claude.exe --type=renderer 등)이 보이면 데스크톱 앱으로 보고 보호한다.
    // 이름 비교를 하는 이유: 브라우저 MCP(Playwright 등)가 띄운 chrome.exe --type=renderer는 정상적인 자손이다
    private static readonly string[] ProtectedPathParts = [@"\AnthropicClaude\", @"\WindowsApps\"];
    private static bool IsProtected(ProcessRecord p, ProcessRecord root) => ProtectedNames.Contains(p.BaseName)
        || p.ExecutablePath is { } path && ProtectedPathParts.Any(part => path.Contains(part, StringComparison.OrdinalIgnoreCase))
        || p.Pid != root.Pid && string.Equals(p.BaseName, root.BaseName, StringComparison.OrdinalIgnoreCase)
            && p.CommandLine is { } line && line.Contains(" --type=", StringComparison.OrdinalIgnoreCase);
    /// <summary>진행 중이거나 사람을 기다리는 세션. 기본적으로 자동 선택에서 제외</summary>
    public static bool IsBusy(AgentState state) => state is AgentState.Starting or AgentState.Working or AgentState.Thinking
        or AgentState.WaitingForInput or AgentState.WaitingForApproval;

    /// <summary>프로세스 목록 + HUD 세션 → 정리 후보 목록(최근 활동 순)</summary>
    public static IReadOnlyList<CleanupRow> Build(IReadOnlyList<ProcessRecord> processes, IReadOnlyList<AgentSession> sessions, int selfPid)
    {
        var byPid = new Dictionary<int, ProcessRecord>();
        foreach (var p in processes) byPid[p.Pid] = p;
        // 세션이 알려 준 PID도 에이전트 루트 후보. 한 PID에 세션 파일이 둘 남아 있을 수 있어 첫 번째만 쓴다
        var sessionPids = new Dictionary<int, AgentType>();
        foreach (var s in sessions) if (s.ProcessId is int pid && pid > 0) sessionPids.TryAdd(pid, s.AgentType);
        var children = new Dictionary<int, List<ProcessRecord>>();
        foreach (var p in byPid.Values)
        {
            if (!IsChildOf(p, byPid.GetValueOrDefault(p.ParentPid))) continue;
            if (!children.TryGetValue(p.ParentPid, out var list)) children[p.ParentPid] = list = [];
            list.Add(p);
        }
        var selfChain = Ancestors(byPid, selfPid);
        var trees = new List<AgentProcessTree>();
        foreach (var p in byPid.Values.OrderBy(x => x.Pid))
        {
            if (AgentOf(p, sessionPids) is not { } agent) continue;
            // 같은 종류의 에이전트가 부모면 루트가 아니라 그 트리의 일부
            var parent = byPid.GetValueOrDefault(p.ParentPid);
            if (IsChildOf(p, parent) && parent is not null && AgentOf(parent, sessionPids) == agent) continue;
            trees.Add(new(agent, p, Descendants(children, p)));
        }
        // 같은 PID가 두 트리에 있으면(시간 역전·PID 재사용 등) 양쪽 모두 종료 금지
        var treeCount = new Dictionary<int, int>();
        foreach (var pid in trees.SelectMany(t => t.Pids)) treeCount[pid] = treeCount.GetValueOrDefault(pid) + 1;
        var rows = new List<CleanupRow>();
        foreach (var tree in trees)
        {
            var pids = tree.Pids.ToHashSet();
            var matched = Match(tree, sessions);
            var guard =
                pids.Contains(selfPid) || pids.Overlaps(selfChain) ? CleanupGuard.SelfProcess
                : tree.Processes.Any(x => IsProtected(x, tree.Root)) ? CleanupGuard.ProtectedProcess
                : pids.Any(pid => treeCount[pid] > 1) ? CleanupGuard.SharedProcess
                : matched.Count > 1 || IsSharedHost(tree) ? CleanupGuard.SharedSession
                : CleanupGuard.None;
            // Codex는 세션 파일에 PID가 없어 명령줄로만 이을 수 있다 → 못 이은 트리는 "알 수 없음"으로 두고 자동 선택하지 않는다
            var ambiguous = matched.Count == 0 && tree.AgentType == AgentType.Codex;
            rows.Add(new(tree, matched.Count == 1 ? matched[0] : null, matched.Count, guard, ambiguous));
        }
        return rows.OrderByDescending(x => x.LastActivityAt).ThenByDescending(x => x.Pid).ToArray();
    }

    /// <summary>스냅샷을 그대로 쓰지 않고 같은 수집기로 다시 읽어 비교할 때 쓰는 편의 함수</summary>
    public static IReadOnlyList<CleanupRow> Build(IProcessLister lister, IReadOnlyList<AgentSession> sessions, int selfPid)
        => Build(lister.List(), sessions, selfPid);

    /// <summary>
    /// 자동 선택: 세션과 이어진 종료 가능 후보 중 최근 keep개를 빼고 모두.
    /// 세션 없는 트리(orphan·unknown)는 HUD 밖 도구(claude -p 스크립트, SDK 앱 등)일 수 있어 직접 체크할 때만 종료한다
    /// </summary>
    public static IReadOnlyList<CleanupRow> SelectAllButLatest(IReadOnlyList<CleanupRow> rows, int keep, bool includeActive)
        => rows.Where(x => x.CanTerminate && x.Session is not null && (includeActive || !x.IsActive))
            .OrderByDescending(x => x.LastActivityAt).ThenByDescending(x => x.Pid)
            .Skip(Math.Max(0, keep)).ToArray();

    /// <summary>
    /// 종료 직전 PID 재사용 확인. 같은 PID가 다른 프로세스로 바뀌었으면 건너뛴다.
    /// 수집기에 따라 시작 시각의 정밀도가 달라서 2초까지는 같은 프로세스로 본다.
    /// </summary>
    public static bool StillMatches(ProcessRecord snapshot, ProcessRecord? current)
        => current is not null && current.Pid == snapshot.Pid
            && string.Equals(current.BaseName, snapshot.BaseName, StringComparison.OrdinalIgnoreCase)
            && Math.Abs((current.StartedAt - snapshot.StartedAt).TotalSeconds) <= 2;

    public static long TotalWorkingSet(IEnumerable<CleanupRow> rows) => rows.Sum(x => x.Tree.WorkingSet);
    public static int TotalProcesses(IEnumerable<CleanupRow> rows) => rows.Sum(x => x.Tree.Count);

    /// <summary>종료 없이 목록만 보는 dry-run 출력(진단·테스트용)</summary>
    public static string Describe(IReadOnlyList<CleanupRow> rows)
    {
        var lines = rows.Select(r => string.Join(" | ",
            r.AgentType, "pid " + r.Pid,
            r.Session?.DisplayTitle ?? "(orphan)",
            r.Session is { } s ? s.DisplayState.ToString() : "-",
            $"{r.Tree.Count} proc", $"{r.Tree.WorkingSet / 1024 / 1024} MB",
            r.CanTerminate ? r.Ambiguous ? "unknown" : "eligible" : r.Guard.ToString()));
        return string.Join('\n', [$"{rows.Count} tree(s), {TotalProcesses(rows)} process(es), {TotalWorkingSet(rows) / 1024 / 1024} MB", .. lines]);
    }

    // PID 재사용 때문에 부모 PID만으로는 부모-자식을 믿을 수 없다. 자식이 부모보다 먼저 시작했으면 연결하지 않는다
    private static bool IsChildOf(ProcessRecord child, ProcessRecord? parent)
        => parent is not null && parent.Pid != child.Pid && child.ParentPid != 0 && child.StartedAt >= parent.StartedAt;

    private static AgentType? AgentOf(ProcessRecord p, IReadOnlyDictionary<int, AgentType> sessionPids)
        => AgentNames.TryGetValue(p.BaseName, out var byName) ? byName
            : AgentHosts.Contains(p.BaseName) && sessionPids.TryGetValue(p.Pid, out var byPid) ? byPid : null;

    private static IReadOnlyList<ProcessRecord> Descendants(Dictionary<int, List<ProcessRecord>> children, ProcessRecord root)
    {
        var result = new List<ProcessRecord> { root };
        var seen = new HashSet<int> { root.Pid };
        for (var i = 0; i < result.Count; i++)
            foreach (var child in children.GetValueOrDefault(result[i].Pid) ?? [])
                if (seen.Add(child.Pid)) result.Add(child);
        return result;
    }

    private static HashSet<int> Ancestors(IReadOnlyDictionary<int, ProcessRecord> byPid, int pid)
    {
        var chain = new HashSet<int>();
        var current = byPid.GetValueOrDefault(pid);
        while (current is not null && chain.Add(current.Pid))
        {
            var parent = byPid.GetValueOrDefault(current.ParentPid);
            current = IsChildOf(current, parent) ? parent : null;
        }
        return chain;
    }

    // Claude는 세션 메타데이터의 PID로 정확히 잇는다. Codex(2026-10 CLI)는 PID를 남기지 않아
    // 트리의 명령줄에 세션 id가 그대로 보이는 경우(codex exec resume <id> 등)만 이을 수 있다.
    private static List<AgentSession> Match(AgentProcessTree tree, IReadOnlyList<AgentSession> sessions)
    {
        var pids = tree.Pids.ToHashSet();
        if (tree.AgentType != AgentType.Codex)
            return sessions.Where(x => x.AgentType == tree.AgentType && x.ProcessId is { } pid && pids.Contains(pid)).ToList();
        var commandLines = tree.Processes.Select(x => x.CommandLine).OfType<string>().ToArray();
        return sessions.Where(x => x.AgentType == AgentType.Codex && BareId(x.Id) is { Length: > 8 } id
            && commandLines.Any(line => line.Contains(id, StringComparison.OrdinalIgnoreCase))).ToList();
    }
    private static string BareId(string sessionId) => sessionId.IndexOf(':') is var sep && sep >= 0 ? sessionId[(sep + 1)..] : sessionId;

    // VS Code Codex 확장은 `codex app-server` 하나로 여러 대화를 돌린다. 어느 대화가 들어 있는지 알 수 없으므로
    // 보이기만 하고 종료는 막는다(하나를 끄면 열려 있는 탭 전부가 끊긴다)
    private static bool IsSharedHost(AgentProcessTree tree) => tree.AgentType == AgentType.Codex
        && tree.Root.CommandLine is { } line && line.Contains("app-server", StringComparison.OrdinalIgnoreCase);
}
