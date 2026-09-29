[CmdletBinding()]
param(
    [switch] $Verify,
    [string] $Tag = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$native = Join-Path $root 'src/AgentHud/native'
$manifestPath = Join-Path $native 'vda.json'
$dllPath = Join-Path $native 'VirtualDesktopAccessor.dll'
$noticePath = Join-Path $root 'THIRD_PARTY_NOTICES.md'

function Test-VdaFile {
    param([string] $Path, [string] $ExpectedHash)
    if (-not (Test-Path -LiteralPath $Path)) { throw "VDA DLL이 없습니다: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 512 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw '유효한 PE DLL이 아닙니다.' }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x8664) { throw "x64 DLL이 아닙니다 (machine=0x$($machine.ToString('x4')))." }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ExpectedHash -and $actual -ne $ExpectedHash.ToLowerInvariant()) { throw "SHA-256 불일치: expected=$ExpectedHash actual=$actual" }
    return $actual
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Verify) {
    $hash = Test-VdaFile -Path $dllPath -ExpectedHash $manifest.sha256
    Write-Host "VirtualDesktopAccessor $($manifest.tag) 검증 완료: $hash"
    exit 0
}

$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$($manifest.repository)/releases?per_page=30" -Headers $headers
$release = if ($Tag) { $releases | Where-Object tag_name -eq $Tag | Select-Object -First 1 } else { $releases | Where-Object { -not $_.draft -and -not $_.prerelease } | Select-Object -First 1 }
if (-not $release) { throw "릴리스를 찾지 못했습니다: $Tag" }
if (-not $Tag -and $release.tag_name -eq $manifest.tag) {
    Write-Host "이미 최신 버전입니다: $($manifest.tag)"
    if ($env:GITHUB_OUTPUT) { 'updated=false' >> $env:GITHUB_OUTPUT }
    exit 0
}
$asset = $release.assets | Where-Object name -eq $manifest.asset | Select-Object -First 1
if (-not $asset) { throw "릴리스 $($release.tag_name)에 $($manifest.asset) asset이 없습니다." }

$temp = Join-Path ([IO.Path]::GetTempPath()) "AgentHud-vda-$([guid]::NewGuid().ToString('N')).dll"
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $temp
    $hash = Test-VdaFile -Path $temp -ExpectedHash ''
    Copy-Item -LiteralPath $temp -Destination $dllPath -Force
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

$manifest.tag = $release.tag_name
$manifest.sha256 = $hash
$manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$notice = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
$notice = $notice -replace '(?m)^- Release: `[^`]+`$', "- Release: ``$($release.tag_name)``"
$notice = $notice -replace '(?m)^- SHA-256: `[0-9a-fA-F]+`$', "- SHA-256: ``$hash``"
Set-Content -LiteralPath $noticePath -Value $notice -Encoding UTF8

Write-Host "VirtualDesktopAccessor 업데이트: $($manifest.tag) → $($release.tag_name)"
if ($env:GITHUB_OUTPUT) {
    'updated=true' >> $env:GITHUB_OUTPUT
    "tag=$($release.tag_name)" >> $env:GITHUB_OUTPUT
    "release_url=$($release.html_url)" >> $env:GITHUB_OUTPUT
}
