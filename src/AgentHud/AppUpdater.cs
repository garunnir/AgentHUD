using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;

namespace AgentHud;

/// <summary>
/// GitHub 릴리스 자동 업데이트. 릴리스 빌드에만 박히는 UpdateAsset 메타데이터(-p:UpdateAsset=...)로 배포 형태를 알고,
/// 없으면(개발 빌드) 동작하지 않는다. 설치는 zip을 내려받아 SHA-256 확인 후 풀고, HUD가 종료되면
/// PowerShell 스크립트가 설치 폴더에 덮어쓴 뒤 다시 실행한다.
/// </summary>
public sealed class AppUpdater : IDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private readonly string _workDir;
    public string? AssetSuffix { get; } = typeof(AppUpdater).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(x => x.Key == "UpdateAsset")?.Value is { Length: > 0 } a ? "-" + a : null;
    public Version Current { get; } = UpdateChecker.Normalize(typeof(AppUpdater).Assembly.GetName().Version ?? new Version(0, 0));
    public bool Supported => AssetSuffix is not null && InstallDir is not null;
    public static string? InstallDir => Path.GetDirectoryName(Environment.ProcessPath);
    public string CurrentText => $"{Current.Major}.{Current.Minor}.{Current.Build}";

    public AppUpdater(string dataDirectory)
    {
        _workDir = Path.Combine(dataDirectory, "update");
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("AgentHud/" + CurrentText);
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public async Task<UpdateRelease?> CheckAsync(CancellationToken ct = default)
    {
        if (!Supported) return null;
        var json = await _http.GetStringAsync(UpdateChecker.LatestUrl, ct);
        return UpdateChecker.Pick(json, Current, AssetSuffix!);
    }

    // 설치 폴더에 쓸 수 없으면(Program Files 등) false: 호출 측이 릴리스 페이지를 연다
    public static bool CanWriteInstallDir()
    {
        if (InstallDir is not { } dir) return false;
        try { var probe = Path.Combine(dir, ".agenthud-write-test"); File.WriteAllText(probe, ""); File.Delete(probe); return true; }
        catch { return false; }
    }

    /// <summary>내려받아 검증·압축 해제 후 교체 스크립트를 띄운다. 성공하면 호출 측이 곧바로 앱을 종료해야 한다</summary>
    public async Task PrepareAsync(UpdateRelease release, CancellationToken ct = default)
    {
        if (Directory.Exists(_workDir)) Directory.Delete(_workDir, true);
        Directory.CreateDirectory(_workDir);
        var zip = Path.Combine(_workDir, release.AssetName);
        await using (var src = await _http.GetStreamAsync(release.AssetUrl, ct))
        await using (var dst = File.Create(zip)) await src.CopyToAsync(dst, ct);
        if (release.Sha256 is { } expected)
        {
            await using var fs = File.OpenRead(zip);
            var actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(fs, ct));
            if (actual != expected) throw new InvalidDataException("SHA-256 mismatch");
        }
        var staged = Path.Combine(_workDir, "new");
        ZipFile.ExtractToDirectory(zip, staged);
        if (!File.Exists(Path.Combine(staged, "AgentHud.exe"))) throw new InvalidDataException("AgentHud.exe not found in " + release.AssetName);
        var script = Path.Combine(_workDir, "apply-update.ps1");
        await File.WriteAllTextAsync(script, ApplyScript, ct);
        var psi = new ProcessStartInfo("powershell.exe") { CreateNoWindow = true, UseShellExecute = false };
        foreach (var arg in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script, "-ProcessId", Environment.ProcessId.ToString(), "-Source", staged, "-Target", InstallDir!, "-Log", Path.Combine(_workDir, "update.log") })
            psi.ArgumentList.Add(arg);
        Process.Start(psi)?.Dispose();
    }

    // HUD 종료를 기다린 뒤 덮어쓰고 다시 실행. 파일 잠금이 늦게 풀릴 수 있어 몇 번 재시도. PowerShell 5.1이 BOM 없는 파일을 ANSI로 읽으므로 ASCII만 사용
    private const string ApplyScript = """
        param([int]$ProcessId, [string]$Source, [string]$Target, [string]$Log)
        try { Wait-Process -Id $ProcessId -Timeout 30 -ErrorAction Stop } catch { }
        $ok = $false
        for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
          try { Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force -ErrorAction Stop; $ok = $true }
          catch { "$(Get-Date -Format o) $_" | Out-File -FilePath $Log -Append; Start-Sleep -Milliseconds 500 }
        }
        if ($ok) { "$(Get-Date -Format o) updated $Target" | Out-File -FilePath $Log -Append }
        Start-Process -FilePath (Join-Path $Target 'AgentHud.exe') -WorkingDirectory $Target
        if ($ok) { Remove-Item -Path $Source -Recurse -Force -ErrorAction SilentlyContinue }
        """;

    public void Dispose() => _http.Dispose();
}
