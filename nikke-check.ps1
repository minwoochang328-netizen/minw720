#Requires -Version 5.0
<#
.SYNOPSIS
    NIKKE PC 런처 공급망 공격(2026년 9~11월) 감염 흔적 점검 스크립트. 읽기 전용.

.DESCRIPTION
    2026-09-27부터 2026-11-03까지 Level Infinite CDN의 공식 JavaScript 파일 4개가 변조되어
    NIKKE PC 런처가 insightjs.com 의 악성 스크립트를 불러왔고, 10월 24일 이후 일부 실행에서
    원격 제어 에이전트(insight.bundle, LuaJIT 바이트코드)를 내려받아 런처 안에서 실행했습니다.
    이 스크립트는 공개된 감염 지표(IOC)를 바탕으로 이 PC에 남은 흔적을 찾습니다.

    - 파일을 삭제하거나 수정하지 않습니다. 레지스트리와 hosts 파일을 바꾸지 않습니다.
    - 네트워크에 접속하지 않습니다. (DNS 캐시 조회는 PC 안의 캐시만 읽습니다.)
    - 결과 보고서를 바탕화면에 텍스트 파일로 저장합니다. (-NoReportFile 로 생략 가능)

    출처
      https://gist.github.com/MotherSphere/d6c049a09ba8ac3085c51ee9df24a4e5
      https://github.com/MotherSphere/NIKKE-Launcher-Check
      https://github.com/Sheisback/nikke_malware_scanner

.PARAMETER NikkePath
    NIKKE 설치 폴더(예: D:\NIKKE) 또는 그 안의 Launcher 폴더를 직접 지정합니다.
    여러 개는 쉼표로 구분합니다 (예: -NikkePath "D:\NIKKE,E:\Games\NIKKE").
    지정하지 않으면 레지스트리와 고정 드라이브에서 자동으로 찾습니다.
.PARAMETER Pause
    끝나고 Enter 를 누를 때까지 창을 유지합니다. 탐색기에서 "PowerShell에서 실행"으로 띄운 경우에는 자동으로 적용됩니다.
.PARAMETER DeepScan
    고정 드라이브 전체를 끝까지 훑어 NIKKE 설치 폴더를 찾습니다. 느립니다.
    기본값은 각 드라이브에서 3단계 깊이까지만 찾습니다.
.PARAMETER ReportPath
    보고서 저장 경로. 기본값은 바탕화면\NIKKE_점검결과_yyyyMMdd_HHmmss.txt 입니다.
.PARAMETER NoReportFile
    보고서 파일을 저장하지 않고 화면에만 출력합니다.
.PARAMETER NoSystemChecks
    레지스트리, 실행 중인 프로세스, DNS 캐시, 네트워크 연결 점검을 생략합니다. (테스트용)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\nikke-check.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\nikke-check.ps1 -NikkePath "D:\Games\NIKKE"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\nikke-check.ps1 -DeepScan

.NOTES
    종료 코드: 0 흔적 없음 / 1 노출 / 2 감염 흔적 확인 / 3 NIKKE 미발견
    이 도구가 아무것도 찾지 못했다고 해서 PC가 깨끗하다는 뜻은 아닙니다.
#>
[CmdletBinding()]
param(
    [string[]]$NikkePath = @(),
    [switch]$DeepScan,
    [string]$ReportPath,
    [switch]$NoReportFile,
    [switch]$NoSystemChecks,
    [switch]$Pause,
    # ---- 아래는 테스트용 경로 재지정 옵션입니다. 일반 사용자는 쓰지 않습니다. ----
    [string]$AppDataOverride,
    [string]$LocalAppDataOverride,
    [string]$TempOverride,
    [string]$UsersRootOverride,
    [string]$HostsOverride,
    [switch]$SkipDriveScan
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$ScriptVersion = '1.1.0'
$StartedAt = Get-Date
# powershell -File 로 넘어온 "A,B" 형태의 경로 목록을 나누고, 따옴표 안 끝 역슬래시 때문에 남는 큰따옴표를 제거합니다.
$NikkePath = @($NikkePath | ForEach-Object { ([string]$_) -split '\s*[,;]\s*' } | ForEach-Object { ([string]$_).Trim().TrimEnd('"').Trim() } | Where-Object { $_ })
$onWindows = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSVersion.Major -lt 6)
$doSystemChecks = $onWindows -and (-not $NoSystemChecks)

# ------------------------------------------------------------------ 감염 지표 (IOC)
$IOC = @{
    Domains = @('insightjs.com', 'www.insightjs.com', 'analytics.insightjs.com', 'insightjs.org')
    IPs     = @('89.127.233.127', '89.126.250.172')
    Clsid   = '{E77CC89B-7401-4C04-8CED-149DB35ADD04}'
    DllName = 'platform_experience_helper.dll'
    # 런처 내장 브라우저의 V8 코드 캐시 항목 이름. 모든 PC에서 같은 이름이 보고됨.
    LoaderCacheNames = @{
        'dd65fa4d61079e7e_0' = 'aegis-fix.min.js'
        'ce2fd3f1007a9fe9_0' = 'images.7fec4c32.js'
        '1416c638b3830103_0' = 'FeedList.feb647c9.js'
        'fd520c7c0f65c2d7_0' = 'vue-bucket.min.js'
    }
    # 변조된 공식 파일의 ETag (런처 HTTP 캐시에 남아 있을 수 있음)
    ModifiedEtags = @{
        '50d1861152ea7f6875ffceb7d08445b5' = 'aegis-fix.min.js'
        '481e9b5ab8fb93406bf31980b53e0578' = 'images.7fec4c32.js'
        'b7d842200372ad0d9a84ef4cc8511311' = 'FeedList.feb647c9.js'
        'dd06875637a29cddd3bae2ba84142c78' = 'vue-bucket.min.js'
    }
    # Level Infinite 가 2026-11-03 에 교체한 정상 파일의 ETag. 캐시에 있으면 수정 이후에 런처를 켠 것.
    FixedEtags = @{
        '44c576454a5b0b4ed60e1a983aa4e782' = 'aegis-fix.min.js'
        '6e5f79cf9b7c364249f9de83ba7fa59e' = 'images.7fec4c32.js'
        '63bc3a47b35b80a5d200dc5624d7126e' = 'vue-bucket.min.js'
    }
    # 공격 이전 원본과 같은 ETag. 일부 CDN 서버가 공격 기간에도 이 사본을 줬으므로 시점 추정에는 쓸 수 없음.
    PreAttackEtags = @{
        '04ee9800128396ba26f10ca70f170967' = 'FeedList.feb647c9.js'
        '4d0dc9cc23650db9631a2280cfa50186' = 'vue-bucket.min.js'
    }
    # Chromium 계열 브라우저의 User Data 위치 (LocalAppData 기준). 에이전트는 Chrome 을 대상으로 하지만 예방적으로 함께 확인.
    ChromiumUserData = @(
        @('Chrome',        @('Google', 'Chrome', 'User Data')),
        @('Chrome Beta',   @('Google', 'Chrome Beta', 'User Data')),
        @('Chrome Dev',    @('Google', 'Chrome Dev', 'User Data')),
        @('Chrome Canary', @('Google', 'Chrome SxS', 'User Data')),
        @('Chromium',      @('Chromium', 'User Data')),
        @('Edge',          @('Microsoft', 'Edge', 'User Data')),
        @('Brave',         @('BraveSoftware', 'Brave-Browser', 'User Data')),
        @('Vivaldi',       @('Vivaldi', 'User Data')),
        @('Whale',         @('Naver', 'Naver Whale', 'User Data'))
    )
    # 에이전트(insight.bundle) 다운로드 응답의 ETag (nginx: 수정시각-크기). 알려진 빌드 4개.
    PayloadEtags      = @('6ae78037-3214f', '6ae8ccff-3214f', '6ae90538-3214f', '6ae9f628-3214f')
    PayloadSize       = 205135
    LauncherDataNames = @('nikke_launcher', 'nikke_launcher_hmt', 'nikke_launcher_google')
    # 로더 스크립트 주소의 f= 값 -> 변조됐던 공식 파일
    LoaderParams = @{ 'aegis' = 'aegis-fix.min.js'; 'images' = 'images.7fec4c32.js'; 'feedlist' = 'FeedList.feb647c9.js'; 'vue' = 'vue-bucket.min.js' }
}

$MaxFileBytes  = 64MB
$MaxTotalBytes = 3GB
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$Utf8   = New-Object System.Text.UTF8Encoding($false)
$FileShareAll = [System.IO.FileShare]'ReadWrite, Delete'

$script:Findings  = New-Object System.Collections.ArrayList
$script:Locations = New-Object System.Collections.ArrayList
$script:Notes     = New-Object System.Collections.ArrayList
$script:Stats     = @{ Files = 0; Bytes = 0; Dirs = 0; Errors = 0; Skipped = 0; CapHit = $false }
$script:LauncherLastWrite = $null
$script:DebugLogsChecked = 0
$script:InstallsFound = New-Object System.Collections.ArrayList
$script:DataDirsFound = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------ 공용 함수
function Write-Step([string]$Text) { Write-Host $Text -ForegroundColor DarkGray }

function Join-Parts {
    param([string]$Base, [string[]]$Parts)
    if ([string]::IsNullOrWhiteSpace($Base)) { return '' }
    $p = $Base
    foreach ($x in $Parts) { $p = Join-Path -Path $p -ChildPath $x }
    return $p
}

function Test-Dir([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    return (Test-Path -LiteralPath $p -PathType Container)
}

function Test-File([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    return (Test-Path -LiteralPath $p -PathType Leaf)
}

function Add-Finding {
    param(
        [ValidateSet('CRITICAL', 'WARNING', 'INFO')][string]$Severity,
        [string]$Title,
        [string]$Detail,
        [string]$Path = '',
        [string[]]$Evidence = @()
    )
    $ev = New-Object System.Collections.ArrayList
    foreach ($e in $Evidence) {
        if ($null -eq $e) { continue }
        $s = [string]$e
        if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + ' ...' }
        if ($s.Trim().Length -eq 0) { continue }
        if (-not $ev.Contains($s)) { [void]$ev.Add($s) }
        if ($ev.Count -ge 5) { break }
    }
    # 같은 폴더를 두 경로(예: 8.3 짧은 경로)로 두 번 훑었을 때 같은 발견이 두 번 나오지 않게 합니다.
    $evKey = (@($ev) -join "`n")
    foreach ($x in $script:Findings) {
        if ($x.Severity -eq $Severity -and $x.Title -eq $Title -and $x.Path -eq $Path -and ((@($x.Evidence) -join "`n") -eq $evKey)) { return }
    }
    [void]$script:Findings.Add([pscustomobject]@{
        Severity = $Severity
        Title    = $Title
        Detail   = $Detail
        Path     = $Path
        Evidence = @($ev)
    })
}

function Read-Bytes {
    # 파일을 읽기 전용, 공유 모드로 읽습니다. 64MB 초과 또는 실패 시 $null.
    param([string]$Path)
    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if (-not $fi.Exists) { return $null }
        if ($fi.Length -gt $MaxFileBytes) { $script:Stats.Skipped++; return $null }
        if ($script:Stats.Bytes -gt $MaxTotalBytes) { $script:Stats.Skipped++; $script:Stats.CapHit = $true; return $null }
        $len = [int]$fi.Length
        if ($len -eq 0) { $script:Stats.Files++; return , (New-Object byte[] 0) }
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $FileShareAll)
        try {
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            if ($read -lt $len) {
                $small = New-Object byte[] $read
                [Array]::Copy($buf, $small, $read)
                $buf = $small
            }
            $script:Stats.Files++
            $script:Stats.Bytes += $read
            return , $buf
        } finally { $fs.Dispose() }
    } catch {
        $script:Stats.Errors++
        return $null
    }
}

function Scan-DebugLog([string]$Path) {
    # debug.log 를 한 줄씩 스트리밍으로 읽어 에이전트 흔적을 셉니다. 크기 제한 없음. 읽기 실패 시 $null.
    $r = @{
        Lines = 0; K2f = 0; Runs = 0; Ins = 0; FirstTs = ''; LastTs = ''
        AgentLines = (New-Object System.Collections.ArrayList)
        RunTimes   = (New-Object System.Collections.ArrayList)
    }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $FileShareAll)
        try {
            $sr = New-Object System.IO.StreamReader($fs, $Utf8, $true)
            $ci = [System.StringComparison]::OrdinalIgnoreCase
            $lastLine = ''
            # 큰 로그(수십 MB)도 빨리 읽도록 줄마다 함수 호출이나 정규식을 쓰지 않습니다.
            while ($null -ne ($line = $sr.ReadLine())) {
                $r.Lines++
                if ($line.Length -eq 0) { continue }
                if (-not $r.FirstTs) { $r.FirstTs = Get-LogTimestamp $line }
                $lastLine = $line
                $isK2f = ($line.IndexOf('k2f_chan', $ci) -ge 0)
                $isIns = ($line.IndexOf('insightjs', $ci) -ge 0)
                $isCtx = $false
                if (-not $isK2f) {
                    $isCtx = ($line.IndexOf('"adopted ', $ci) -ge 0) -or ($line.IndexOf('agent started as', $ci) -ge 0) -or ($line.IndexOf('lua downloaded to', $ci) -ge 0) -or ($line.IndexOf('"resuming', $ci) -ge 0)
                }
                if (-not ($isK2f -or $isIns -or $isCtx)) { continue }
                if ($isK2f) {
                    $r.K2f++
                    if ($line.IndexOf('k2f_chan registered', $ci) -ge 0) {
                        $r.Runs++
                        $ts = Get-LogTimestamp $line
                        if ($ts) { [void]$r.RunTimes.Add($ts) }
                    }
                }
                if ($isIns) { $r.Ins++ }
                if ($r.AgentLines.Count -lt 60) { [void]$r.AgentLines.Add($line) }
            }
            if ($lastLine) { $r.LastTs = Get-LogTimestamp $lastLine }
            $script:Stats.Files++
            $script:Stats.Bytes += $fs.Length
        } finally { $fs.Dispose() }
    } catch { $script:Stats.Errors++; return $null }
    return $r
}

function Test-Contains([string]$Text, [string]$Needle) {
    if ($null -eq $Text) { return $false }
    return ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-Snippets {
    # 텍스트에서 바늘 문자열이 있는 줄(최대 240자)을 뽑습니다. 비인쇄 문자는 '.' 으로 바꿉니다.
    param([string]$Text, [string[]]$Needles, [int]$Max = 5)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Text) { return @() }
    foreach ($n in $Needles) {
        $pos = 0
        while ($out.Count -lt $Max) {
            $i = $Text.IndexOf($n, $pos, [System.StringComparison]::OrdinalIgnoreCase)
            if ($i -lt 0) { break }
            $start = $i
            $lim = [Math]::Max(0, $i - 400)
            while ($start -gt $lim) {
                $c = $Text[$start - 1]
                if ($c -eq "`n" -or $c -eq "`r" -or $c -eq [char]0) { break }
                $start--
            }
            $end = $i + $n.Length
            $lim2 = [Math]::Min($Text.Length, $i + $n.Length + 400)
            while ($end -lt $lim2) {
                $c = $Text[$end]
                if ($c -eq "`n" -or $c -eq "`r" -or $c -eq [char]0) { break }
                $end++
            }
            $snip = $Text.Substring($start, $end - $start)
            if ($snip.Length -gt 240) {
                # 긴 줄은 바늘 문자열이 보이도록 그 주변 240자만 남깁니다.
                $ws = [Math]::Max($start, $i - 100)
                if (($ws + 240) -gt $end) { $ws = [Math]::Max($start, $end - 240) }
                $snip = $Text.Substring($ws, [Math]::Min(240, $end - $ws))
                if ($ws -gt $start) { $snip = '...' + $snip }
            }
            $snip = [regex]::Replace($snip, '[^\x20-\x7E]', '.')
            $snip = $snip.Trim()
            if ($snip.Length -gt 0 -and -not $out.Contains($snip)) { [void]$out.Add($snip) }
            $pos = $i + $n.Length
        }
    }
    return @($out)
}

function Get-FilesUnder {
    # 하위 파일 목록(깊이 제한). 심볼릭 링크/정션은 따라가지 않습니다.
    param([string]$Root, [int]$MaxDepth = 12)
    $result = New-Object System.Collections.ArrayList
    if (-not (Test-Dir $Root)) { return $result }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $item  = $queue.Dequeue()
        $dir   = [string]$item[0]
        $depth = [int]$item[1]
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            $script:Stats.Dirs++
            foreach ($f in $di.GetFiles()) {
                if (($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                [void]$result.Add($f)
            }
            if ($depth -lt $MaxDepth) {
                foreach ($d in $di.GetDirectories()) {
                    if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $queue.Enqueue(@($d.FullName, $depth + 1))
                }
            }
        } catch { $script:Stats.Errors++ }
    }
    return $result
}

function Get-LogTimestamp([string]$Line) {
    # Chromium 로그 접두어 [MMDD/HHMMSS.mmm:...] -> "MM-DD HH:MM:SS"
    $m = [regex]::Match($Line, '^\[(\d{2})(\d{2})/(\d{2})(\d{2})(\d{2})')
    if ($m.Success) {
        return ('{0}-{1} {2}:{3}:{4}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value, $m.Groups[5].Value)
    }
    return ''
}

function Get-InstallFromExePath([string]$Value) {
    # 'C:\...\Launcher\nikke_launcher.exe' (따옴표/인자 포함 가능) -> 설치 폴더
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $s = $Value.Trim().Replace('\\', '\')
    $i = $s.ToLowerInvariant().IndexOf('\launcher\nikke_launcher.exe')
    if ($i -lt 0) { return $null }
    $head = $s.Substring(0, $i)
    $q = $head.LastIndexOf('"')
    if ($q -ge 0) { $head = $head.Substring($q + 1) }
    return $head.Trim()
}

function Resolve-Install([string]$p) {
    # 설치 폴더 또는 Launcher 폴더를 받아 설치 폴더(Launcher 의 상위)를 돌려줍니다.
    if (-not (Test-Dir $p)) { return $null }
    $cands = @()
    $leaf = Split-Path -Path $p -Leaf
    if ($leaf -ieq 'Launcher') {
        $parent = Split-Path -Path $p -Parent
        if ($parent) { $cands += $parent }
    }
    $cands += $p
    foreach ($c in $cands) {
        $l = Join-Path $c 'Launcher'
        if ((Test-File (Join-Path $l 'nikke_launcher.exe')) -or (Test-File (Join-Parts $l @('intl_service', 'debug.log')))) {
            try { return (Get-Item -LiteralPath $c).FullName } catch { return $c }
        }
    }
    return $null
}

function Add-Install([string]$p) {
    $r = Resolve-Install $p
    if ($null -eq $r) { return }
    foreach ($e in $script:InstallsFound) { if ($e -ieq $r) { return } }
    [void]$script:InstallsFound.Add($r)
}

function Get-RegValue([string]$KeyPath, [string]$Name) {
    try {
        if (-not (Test-Path -LiteralPath $KeyPath)) { return $null }
        $k = Get-Item -LiteralPath $KeyPath -ErrorAction Stop
        $v = $k.GetValue($Name, $null)
        if ($null -eq $v) { return $null }
        return [string]$v
    } catch { return $null }
}

# ------------------------------------------------------------------ 1. NIKKE 설치 폴더 찾기
function Find-Installs {
    Write-Step '[2/8] NIKKE 설치 폴더를 찾는 중...'
    foreach ($p in $NikkePath) {
        $r = Resolve-Install $p
        if ($null -eq $r) {
            Add-Finding -Severity INFO -Title '지정한 경로에서 NIKKE 런처를 찾지 못함' `
                -Detail 'Launcher\nikke_launcher.exe 또는 Launcher\intl_service\debug.log 가 있는 폴더를 지정하세요.' -Path $p
        } else { Add-Install $r }
    }

    if ($doSystemChecks) {
        # 런처가 기록하는 설치 경로
        $uninst = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
        foreach ($root in @('HKCU:\', 'HKLM:\', 'HKLM:\SOFTWARE\WOW6432Node\')) {
            $base = if ($root -eq 'HKLM:\SOFTWARE\WOW6432Node\') { 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' } else { Join-Path $root $uninst }
            foreach ($name in @('GameInstallPath', 'InstallLocation')) {
                $v = Get-RegValue (Join-Path $base 'nikke_launcher') $name
                if ($v) { Add-Install $v }
            }
            $v = Get-RegValue (Join-Path $base 'nikke_launcher') 'DisplayIcon'
            if ($v) { $d = Get-InstallFromExePath $v; if ($d) { Add-Install $d } }
            # DisplayName 에 NIKKE 가 들어간 모든 제거 항목
            try {
                foreach ($sub in (Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
                    $dn = Get-RegValue $sub.PSPath 'DisplayName'
                    if ($dn -and ($dn -match '(?i)nikke|goddess of victory|승리의 여신')) {
                        foreach ($name in @('InstallLocation', 'GameInstallPath')) {
                            $v = Get-RegValue $sub.PSPath $name
                            if ($v) { Add-Install $v }
                        }
                        $v = Get-RegValue $sub.PSPath 'DisplayIcon'
                        if ($v) { $d = Get-InstallFromExePath $v; if ($d) { Add-Install $d } }
                    }
                }
            } catch { }
        }
        foreach ($k in @('HKCU:\Software\Classes\nikkelauncher\DefaultIcon', 'HKCU:\Software\Classes\nikkelauncher\shell\open\command')) {
            $v = Get-RegValue $k ''
            if ($v) { $d = Get-InstallFromExePath $v; if ($d) { Add-Install $d } }
        }
        $v = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\nikke_launcher.exe' ''
        if ($v) { $d = Get-InstallFromExePath $v; if ($d) { Add-Install $d } }
    }

    # 런처 데이터 폴더의 url_protocol.reg
    foreach ($dd in $script:DataDirsFound) {
        $reg = Join-Path $dd.Path 'url_protocol.reg'
        if (Test-File $reg) {
            try {
                foreach ($line in (Get-Content -LiteralPath $reg -ErrorAction Stop)) {
                    if ($line -match '(?i)nikke_launcher\.exe') {
                        $d = Get-InstallFromExePath $line
                        if ($d) { Add-Install $d }
                    }
                }
            } catch { }
        }
    }

    # 고정 드라이브 탐색
    if (-not $SkipDriveScan) {
        $drives = @()
        if ($onWindows) {
            $all = @()
            try { $all = @([System.IO.DriveInfo]::GetDrives()) } catch { }
            foreach ($dv in $all) {
                try {
                    if (-not $dv.IsReady) { continue }
                    if ($dv.DriveType -eq 'Fixed' -or $dv.DriveType -eq 'Removable') { $drives += $dv.RootDirectory.FullName }
                } catch { }
            }
        }
        $commonSubs = @('NIKKE', 'Games\NIKKE', 'Game\NIKKE', 'Program Files\NIKKE', 'Program Files (x86)\NIKKE',
                        'Level Infinite\NIKKE', 'Games\Level Infinite\NIKKE', 'Program Files\Level Infinite\NIKKE', 'Program Files (x86)\Level Infinite\NIKKE',
                        'SteamLibrary\NIKKE', 'SteamLibrary\steamapps\common\NIKKE', 'Steam\steamapps\common\NIKKE', 'Program Files (x86)\Steam\steamapps\common\NIKKE')
        foreach ($root in $drives) {
            foreach ($sub in $commonSubs) { Add-Install (Join-Path $root $sub) }
            $maxDepth = 4
            if ($DeepScan) { $maxDepth = 64 }
            $skipNames = @('Windows', '$Recycle.Bin', 'System Volume Information', 'Windows.old', 'ProgramData', '$WinREAgent')
            $queue = New-Object System.Collections.Queue
            $queue.Enqueue(@($root, 0))
            $visited = 0
            while ($queue.Count -gt 0) {
                $item = $queue.Dequeue()
                $dir = [string]$item[0]; $depth = [int]$item[1]
                $visited++
                if (($visited % 3000) -eq 0) { Write-Step ("      ... {0:N0} 폴더 확인 ({1})" -f $visited, $dir) }
                $l = Join-Path $dir 'Launcher'
                if ((Test-File (Join-Path $l 'nikke_launcher.exe')) -or (Test-File (Join-Parts $l @('intl_service', 'debug.log')))) { Add-Install $dir; continue }
                if ($depth -ge $maxDepth) { continue }
                try {
                    $di = New-Object System.IO.DirectoryInfo($dir)
                    foreach ($d in $di.GetDirectories()) {
                        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        if ($depth -eq 0 -and ($skipNames -contains $d.Name)) { continue }
                        if ($d.Name -in @('node_modules', '.git', 'Windows', 'WinSxS')) { continue }
                        $queue.Enqueue(@($d.FullName, $depth + 1))
                    }
                } catch { $script:Stats.Errors++ }
            }
        }
        # 사용자 프로필 폴더(바탕 화면, 다운로드, Games 등)는 3단계 더 들어가 봅니다. AppData 는 제외.
        if ($onWindows -and (Test-Dir $UsersRoot)) {
            try {
                foreach ($prof in (Get-ChildItem -LiteralPath $UsersRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                    if ($prof.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
                    if (($prof.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $queue = New-Object System.Collections.Queue
                    $queue.Enqueue(@($prof.FullName, 0))
                    while ($queue.Count -gt 0) {
                        $item = $queue.Dequeue()
                        $dir = [string]$item[0]; $depth = [int]$item[1]
                        $l = Join-Path $dir 'Launcher'
                        if ((Test-File (Join-Path $l 'nikke_launcher.exe')) -or (Test-File (Join-Parts $l @('intl_service', 'debug.log')))) { Add-Install $dir; continue }
                        if ($depth -ge 3) { continue }
                        try {
                            $di = New-Object System.IO.DirectoryInfo($dir)
                            foreach ($d in $di.GetDirectories()) {
                                if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                                if ($d.Name -in @('AppData', 'node_modules', '.git')) { continue }
                                $queue.Enqueue(@($d.FullName, $depth + 1))
                            }
                        } catch { }
                    }
                }
            } catch { }
        }
    }
}

# ------------------------------------------------------------------ 2. 런처 데이터 폴더 찾기
function Find-DataDirs {
    param([string]$AppData, [string]$Owner)
    if (-not (Test-Dir $AppData)) { return }
    try {
        foreach ($d in (Get-ChildItem -LiteralPath $AppData -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -match '^(?i)nikke_launcher') {
                $full = $d.FullName
                $dup = $false
                foreach ($e in $script:DataDirsFound) { if ($e.Path -ieq $full) { $dup = $true } }
                if (-not $dup) { [void]$script:DataDirsFound.Add(@{ Path = $full; Owner = $Owner }) }
            }
        }
    } catch { }
}

# ------------------------------------------------------------------ 3. 설치 폴더 점검 (debug.log, log\)
function Check-Install([string]$InstallDir) {
    [void]$script:Locations.Add("[NIKKE 설치] $InstallDir")
    $launcher = Join-Path $InstallDir 'Launcher'
    $dbg = Join-Parts $launcher @('intl_service', 'debug.log')

    if (Test-File $dbg) {
        $fi = Get-Item -LiteralPath $dbg
        if ($fi.LastWriteTime -gt $script:LauncherLastWrite) { $script:LauncherLastWrite = $fi.LastWriteTime }
        $scan = Scan-DebugLog $dbg
        if ($null -eq $scan) {
            Add-Finding -Severity INFO -Title 'debug.log 를 읽을 수 없어 확인하지 못함' `
                -Detail '파일이 잠겨 있거나 읽기 권한이 없습니다. 런처를 완전히 종료한 뒤, 관리자 권한 PowerShell 에서 다시 실행하세요. 이 파일을 확인하지 못하면 판정이 불완전합니다.' -Path $dbg
        } else {
            $script:DebugLogsChecked++
            if ($scan.K2f -gt 0) {
                $timesText = ''
                if ($scan.RunTimes.Count -gt 0) { $timesText = ' 에이전트 시작 시각(월-일 시:분:초, 연도는 로그에 없음): ' + (($scan.RunTimes | Select-Object -Unique | Select-Object -First 10) -join ', ') }
                Add-Finding -Severity CRITICAL -Title '원격 제어 에이전트가 이 PC에서 실행된 기록 (debug.log 에 k2f_chan)' `
                    -Detail ("debug.log 에 'k2f_chan registered' 가 {0}회 기록되어 있습니다. 런처가 켜져 있던 동안 공격자는 이 PC에서 임의 명령 실행, 파일 열람, 화면 캡처, 브라우저 저장 비밀번호·쿠키·토큰 수집을 할 수 있었습니다.{1}" -f $scan.Runs, $timesText) `
                    -Path $dbg -Evidence @($scan.AgentLines)
            } elseif ($scan.Ins -gt 0) {
                Add-Finding -Severity CRITICAL -Title 'debug.log 에 insightjs (공격자 도메인) 언급' `
                    -Detail '공격자 도메인이 런처 로그에 남아 있습니다.' -Path $dbg -Evidence @($scan.AgentLines)
            } else {
                $period = ''
                if ($scan.FirstTs) { $period = (" 로그 기간: {0} ~ {1} (연도 미기록)." -f $scan.FirstTs, $scan.LastTs) }
                $emptyNote = ''
                if ($scan.Lines -eq 0) { $emptyNote = ' 파일이 비어 있습니다.' }
                Add-Finding -Severity INFO -Title 'debug.log 에 에이전트 실행 흔적 없음' `
                    -Detail ("{0:N0}줄 확인. 마지막 수정: {1}.{2}{3} 런처는 실행마다 이 파일에 덧붙이므로, 파일이 만들어진 뒤의 모든 실행이 들어 있습니다." -f $scan.Lines, $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $period, $emptyNote) `
                    -Path $dbg
            }
        }
    } else {
        Add-Finding -Severity INFO -Title 'debug.log 없음 (에이전트 실행 여부를 가장 잘 보여 주는 로그를 확인하지 못함)' `
            -Detail 'Launcher\intl_service\debug.log 가 없습니다. NIKKE 를 지웠거나 다시 설치했다면 이전 기록은 사라집니다. 런처 데이터 폴더의 k2f.agent.state 점검 결과를 함께 보세요.' -Path $dbg
    }

    # Launcher\log\ 아래 전체 (tinyget 다운로드 로그, 저장된 페이로드)
    $logDir = Join-Path $launcher 'log'
    if (Test-Dir $logDir) {
        $files = Get-FilesUnder -Root $logDir -MaxDepth 8
        foreach ($f in $files) {
            if ($f.Name -match '^(?i)k2f') {
                Add-Finding -Severity CRITICAL -Title '런처 log 폴더에 k2f 파일' -Detail '에이전트가 저장한 파일 이름 패턴입니다. (초기 실행에서는 log\tinyget\k2f.lua 로 저장됨)' -Path $f.FullName -Evidence @("{0} 바이트, 수정 {1}" -f $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
            }
            $bytes = Read-Bytes -Path $f.FullName
            if ($null -eq $bytes) { continue }
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0x1B -and $bytes[1] -eq 0x4C -and $bytes[2] -eq 0x4A) {
                Add-Finding -Severity CRITICAL -Title '런처 log 폴더에 LuaJIT 바이트코드 파일 (내려받은 에이전트 본체)' `
                    -Detail ("런처는 내려받은 에이전트(insight.bundle)를 tinyget 로그 이름으로 저장합니다. 알려진 에이전트 크기는 {0:N0} 바이트입니다." -f $IOC.PayloadSize) `
                    -Path $f.FullName -Evidence @(("LuaJIT 헤더(1B 4C 4A), {0:N0} 바이트, 수정 {1}" -f $bytes.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
                continue
            }
            $text = $Latin1.GetString($bytes)
            $etagHits = @()
            foreach ($pe in $IOC.PayloadEtags) { if (Test-Contains $text $pe) { $etagHits += $pe } }
            if (Test-Contains $text 'insight.bundle') {
                $ev = @(Get-Snippets -Text $text -Needles @('insight.bundle') -Max 3)
                $ev += @(Get-Snippets -Text $text -Needles @('Last-Modified', 'ETag') -Max 2)
                Add-Finding -Severity CRITICAL -Title '런처가 에이전트(insight.bundle)를 내려받은 기록' `
                    -Detail 'analytics.insightjs.com 에서 insight.bundle 을 내려받았습니다. 이 파일이 원격 제어 에이전트입니다. (Last-Modified/ETag 가 있으면 어떤 빌드였는지 알 수 있습니다)' `
                    -Path $f.FullName -Evidence $ev
            } elseif ($etagHits.Count -gt 0) {
                Add-Finding -Severity CRITICAL -Title '런처 다운로드 로그에 에이전트(insight.bundle) 응답 헤더' `
                    -Detail ("알려진 에이전트 빌드의 ETag({0})가 기록되어 있습니다. 런처가 에이전트를 내려받았습니다. (tinyget.mem.log 는 실행마다 처음부터 덮어쓰는 고정 크기 버퍼라 끝부분에 이전 세션의 헤더가 남을 수 있습니다)" -f ($etagHits -join ', ')) `
                    -Path $f.FullName -Evidence @(Get-Snippets -Text $text -Needles @('ETag', 'Last-Modified', 'Content-Length') -Max 4)
            } elseif (Test-Contains $text 'insightjs') {
                Add-Finding -Severity CRITICAL -Title '런처 로그에 insightjs (공격자 도메인) 언급' -Detail '공격자 도메인이 다운로드 로그에 남아 있습니다.' `
                    -Path $f.FullName -Evidence @(Get-Snippets -Text $text -Needles @('insightjs') -Max 5)
            }
        }
    }

    # Launcher 폴더 얕은 깊이에서 k2f* 파일
    foreach ($f in (Get-FilesUnder -Root $launcher -MaxDepth 2)) {
        if ($f.Name -match '^(?i)k2f' -and -not ($f.FullName -match '[\\/]log[\\/]')) {
            Add-Finding -Severity CRITICAL -Title 'Launcher 폴더에 k2f 파일' -Detail '에이전트가 쓰는 파일 이름 패턴입니다.' -Path $f.FullName
        }
    }
}

# ------------------------------------------------------------------ 4. 런처 데이터 폴더 점검 (%APPDATA%\nikke_launcher*)
function Check-LauncherData([string]$DataDir, [string]$Owner) {
    $tag = ''
    if ($Owner) { $tag = " (사용자 $Owner)" }
    [void]$script:Locations.Add("[런처 데이터] $DataDir$tag")
    # 작은 파일(Local Storage, 캐시 키)을 먼저 읽어 총 읽기 한도에 밀려 건너뛰지 않게 합니다.
    $files = @(Get-FilesUnder -Root $DataDir -MaxDepth 12 | Sort-Object -Property Length)
    $skippedBefore = $script:Stats.Skipped
    $hasTbsCache = Test-Dir (Join-Path $DataDir 'tbs_cache')
    $analytics = $false
    $agentHits = New-Object System.Collections.ArrayList
    $cacheHits = New-Object System.Collections.ArrayList
    $netHits   = New-Object System.Collections.ArrayList
    $otherHits = New-Object System.Collections.ArrayList
    $loaders   = New-Object System.Collections.ArrayList
    $modEtag   = New-Object System.Collections.ArrayList
    $fixedEtag = New-Object System.Collections.ArrayList
    $preEtag   = New-Object System.Collections.ArrayList
    $checked = 0
    $netNames = @('Network Persistent State', 'TransportSecurity', 'Reporting and NEL')

    foreach ($f in $files) {
        $bytes = Read-Bytes -Path $f.FullName
        if ($null -eq $bytes) { continue }
        $checked++
        if (($checked % 500) -eq 0) { Write-Step ("      ... {0:N0}개 파일 확인 ({1:N0} MB)" -f $checked, ($script:Stats.Bytes / 1MB)) }
        if ($bytes.Length -eq 0) { continue }
        $text = $Latin1.GetString($bytes)
        $full = $f.FullName
        $inCodeCache = ($full -match '[\\/]Code Cache[\\/]')
        $inHttpCache = ($full -match '[\\/]Cache[\\/]')

        if ((Test-Contains $text 'k2f_chan') -or (Test-Contains $text 'k2f.agent')) {
            $s = @(Get-Snippets -Text $text -Needles @('k2f.agent', 'k2f_chan') -Max 1)
            $line = ''
            if ($s.Count -gt 0) { $line = $s[0] }
            $ap = $line.IndexOf('agent_pass', [System.StringComparison]::OrdinalIgnoreCase)
            if ($ap -ge 0) { $line = $line.Substring(0, $ap) + '[이하 비밀값 생략]' }
            [void]$agentHits.Add("$full : $line")
        }
        if (Test-Contains $text 'insightjs') {
            if (Test-Contains $text 'analytics.insightjs') { $analytics = $true }
            $s = @(Get-Snippets -Text $text -Needles @('insightjs') -Max 1)
            $line = ''
            if ($s.Count -gt 0) { $line = $s[0] }
            if ($f.Name -in $netNames) { [void]$netHits.Add("$full : $line") }
            elseif ($inCodeCache -or $inHttpCache) { [void]$cacheHits.Add("$full : $line") }
            else { [void]$otherHits.Add("$full : $line") }
            # 어떤 변조 파일의 로더가 실행됐는지 (l.js?f=aegis 등)
            foreach ($m in [regex]::Matches($text, '(?i)l\.js\?f=([a-z]+)')) {
                $key = $m.Groups[1].Value.ToLowerInvariant()
                if ($IOC.LoaderParams.ContainsKey($key)) { [void]$loaders.Add(("{0} (f={1})" -f $IOC.LoaderParams[$key], $key)) } else { [void]$loaders.Add("f=$key") }
            }
            if ($inCodeCache -and $IOC.LoaderCacheNames.ContainsKey($f.Name)) { [void]$loaders.Add(("{0} (캐시 항목 {1})" -f $IOC.LoaderCacheNames[$f.Name], $f.Name)) }
        }
        if ($inHttpCache) {
            foreach ($k in $IOC.ModifiedEtags.Keys)  { if (Test-Contains $text $k) { [void]$modEtag.Add(("{0} (ETag {1}) - {2}" -f $IOC.ModifiedEtags[$k], $k, $f.Name)) } }
            foreach ($k in $IOC.FixedEtags.Keys)     { if (Test-Contains $text $k) { [void]$fixedEtag.Add(("{0} (ETag {1}) - {2}" -f $IOC.FixedEtags[$k], $k, $f.Name)) } }
            foreach ($k in $IOC.PreAttackEtags.Keys) { if (Test-Contains $text $k) { [void]$preEtag.Add(("{0} (ETag {1}) - {2}" -f $IOC.PreAttackEtags[$k], $k, $f.Name)) } }
        }
    }
    $skippedHere = $script:Stats.Skipped - $skippedBefore
    $agentNote = ''
    if ($analytics) { $agentNote = ' analytics.insightjs.com 은 에이전트(insight.bundle)를 내려받고 교신하는 호스트이므로, 이 기록은 에이전트 단계까지 갔을 가능성을 뜻합니다.' }

    if ($agentHits.Count -gt 0) {
        Add-Finding -Severity CRITICAL -Title '런처 데이터에 에이전트 상태(k2f.agent.state) 또는 k2f_chan 기록' `
            -Detail ("{0}개 파일. 에이전트는 자신의 ID와 설정을 런처 내장 브라우저의 Local Storage 에 저장합니다. NIKKE 폴더를 지워도 이 흔적은 남습니다. 에이전트가 실행됐다는 뜻입니다." -f $agentHits.Count) `
            -Path $DataDir -Evidence @($agentHits)
    }
    if ($cacheHits.Count -gt 0) {
        $ld = ''
        if ($loaders.Count -gt 0) { $ld = ' 확인된 로더: ' + (($loaders | Select-Object -Unique) -join ', ') + '.' }
        Add-Finding -Severity WARNING -Title '런처 내장 브라우저 캐시에 insightjs.com 로더 주소' `
            -Detail (("변조된 공식 파일이 불러온 악성 스크립트(insightjs.com/l.js)가 런처 안에서 실행됐습니다.{0} 이것만으로 에이전트가 내려받아졌다고 볼 수는 없습니다. 런처를 다시 켜기 전에 tbs_cache 폴더를 지워야 합니다." -f $ld) + $agentNote) `
            -Path $DataDir -Evidence @($cacheHits)
    }
    if ($netHits.Count -gt 0) {
        Add-Finding -Severity WARNING -Title '런처가 insightjs.com 에 접속한 네트워크 상태 기록' `
            -Detail ('런처 내장 브라우저가 공격자 도메인에 연결한 기록입니다.' + $agentNote) -Path $DataDir -Evidence @($netHits)
    }
    if ($otherHits.Count -gt 0) {
        Add-Finding -Severity WARNING -Title '런처 데이터에 insightjs.com 언급' -Detail ('공격자 도메인이 런처 데이터 파일에 남아 있습니다.' + $agentNote) -Path $DataDir -Evidence @($otherHits)
    }
    if ($modEtag.Count -gt 0) {
        Add-Finding -Severity WARNING -Title '런처 HTTP 캐시에 변조된 공식 파일 사본' `
            -Detail '공격자 코드가 든 공식 파일이 캐시에 남아 있습니다. 런처를 다시 켤 때 이 사본이 쓰일 수 있으니 tbs_cache 를 지운 뒤 켜세요.' -Path $DataDir -Evidence @($modEtag | Select-Object -Unique)
    }
    if ($fixedEtag.Count -gt 0) {
        Add-Finding -Severity INFO -Title '런처 HTTP 캐시에 11월 3일 교체된 정상 파일 사본' `
            -Detail 'Level Infinite 가 2026-11-03 에 교체한 정상 파일이 캐시에 있습니다. 수정 이후에 런처를 켠 적이 있다는 뜻입니다.' -Path $DataDir -Evidence @($fixedEtag | Select-Object -Unique)
    }
    if ($preEtag.Count -gt 0) {
        Add-Finding -Severity INFO -Title '런처 HTTP 캐시에 변조되지 않은(공격 이전 원본) 파일 사본' `
            -Detail '변조되지 않은 사본입니다. 다만 일부 CDN 서버는 공격 기간에도 이 사본을 제공했으므로, 이것만으로 언제 런처를 켰는지는 알 수 없습니다.' -Path $DataDir -Evidence @($preEtag | Select-Object -Unique)
    }
    if ($agentHits.Count -eq 0 -and $cacheHits.Count -eq 0 -and $netHits.Count -eq 0 -and $otherHits.Count -eq 0 -and $modEtag.Count -eq 0) {
        if (-not $hasTbsCache) {
            Add-Finding -Severity INFO -Title '런처 데이터에 tbs_cache 폴더가 없어 Local Storage/캐시 흔적은 확인할 수 없음' `
                -Detail ("{0}개 파일 확인. k2f.agent.state 와 로더 캐시는 tbs_cache 안에 저장되므로, 이미 지웠다면 그 흔적도 함께 사라진 것입니다. debug.log 결과를 기준으로 판단하세요." -f $checked) -Path $DataDir
        } elseif ($skippedHere -gt 0) {
            Add-Finding -Severity INFO -Title '런처 데이터에 흔적 없음 (일부 파일은 확인하지 못함)' `
                -Detail ("{0}개 파일 확인, {1}개는 크기(64MB 초과) 또는 총 읽기 한도(3GB) 때문에 건너뜀. 확인한 파일에서는 k2f, insightjs, 변조 파일 ETag 모두 없음." -f $checked, $skippedHere) -Path $DataDir
        } else {
            Add-Finding -Severity INFO -Title '런처 데이터에 흔적 없음' -Detail ("{0}개 파일 확인. k2f, insightjs, 변조 파일 ETag 모두 없음." -f $checked) -Path $DataDir
        }
    } elseif ($skippedHere -gt 0) {
        Add-Finding -Severity INFO -Title '런처 데이터의 일부 파일은 확인하지 못함' -Detail ("{0}개 파일은 크기(64MB 초과) 또는 총 읽기 한도(3GB) 때문에 건너뛰었습니다." -f $skippedHere) -Path $DataDir
    }
}

# ------------------------------------------------------------------ 5. 사용자 프로필 점검 (Chrome 지속성 DLL, Temp)
function Check-ChromeHelper([string]$LocalAppData, [string]$AppData, [string]$Owner) {
    $tag = ''
    if ($Owner) { $tag = " (사용자 $Owner)" }
    # 브라우저 프로필(User Data)마다 PlatformExperienceHelper 폴더를 확인합니다. 에이전트는 Chrome 을 대상으로 하지만 다른 Chromium 계열도 예방적으로 봅니다.
    $roots = @()
    if ($LocalAppData) { foreach ($b in $IOC.ChromiumUserData) { $roots += , @($b[0], (Join-Parts $LocalAppData $b[1])) } }
    if ($AppData) {
        $roots += , @('Opera', (Join-Parts $AppData @('Opera Software', 'Opera Stable')))
        $roots += , @('Opera GX', (Join-Parts $AppData @('Opera Software', 'Opera GX Stable')))
    }
    foreach ($r in $roots) {
        $browser = $r[0]
        $peh = Join-Path $r[1] 'PlatformExperienceHelper'
        if (-not (Test-Dir $peh)) { continue }
        $all = @(Get-ChildItem -LiteralPath $peh -Recurse -Force -Depth 4 -ErrorAction SilentlyContinue)
        $dlls = @($all | Where-Object { -not $_.PSIsContainer -and $_.Name -ieq $IOC.DllName })
        $hexDirs = @(Get-ChildItem -LiteralPath $peh -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-fA-F]{64}$' })
        if ($dlls.Count -gt 0) {
            $ev = @()
            foreach ($d in $dlls) { $ev += ("{0} ({1:N0} 바이트, 수정 {2})" -f $d.FullName, $d.Length, $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) }
            Add-Finding -Severity CRITICAL -Title "$browser 지속성 DLL 발견$tag" `
                -Detail '공격자가 브라우저가 불러오도록 등록한 DLL 입니다. 런처를 꺼도 계속 동작하며 웹페이지에 입력하는 비밀번호와 지갑 복구 문구를 읽는다고 보고됐습니다. 레지스트리 키 삭제 -> 재부팅 -> 이 하위 폴더 삭제 순서로 제거하세요. (Defender 가 탐지하지 못한 사례가 있습니다)' `
                -Path $peh -Evidence $ev
        } elseif ($hexDirs.Count -gt 0) {
            $ev = @()
            foreach ($d in $hexDirs) { $ev += $d.FullName }
            Add-Finding -Severity CRITICAL -Title "$browser PlatformExperienceHelper 아래 64자리 16진수 폴더 (악성 폴더 구조)$tag" `
                -Detail '에이전트는 서버가 준 SHA-256 이름의 하위 폴더에 DLL 을 넣습니다. DLL 은 없지만 폴더가 남아 있어 설치됐다가 제거된 것일 수 있습니다.' -Path $peh -Evidence $ev
        } else {
            $ev = @()
            foreach ($e in ($all | Select-Object -First 5)) { $ev += $e.Name }
            Add-Finding -Severity INFO -Title "$browser PlatformExperienceHelper 폴더는 정상 구성$tag" `
                -Detail 'platform_experience_helper.dll 도, 64자리 16진수 하위 폴더도 없습니다. Chrome 자체가 만드는 폴더(platform_experience_helper.exe, LoadFeatures)입니다.' -Path $peh -Evidence $ev
        }
    }
    # Chrome 설치 폴더 쪽 잔재 (이전 버전 에이전트의 정리 루틴이 지우는 파일 이름)
    $appRoots = @()
    if ($LocalAppData) { $appRoots += (Join-Parts $LocalAppData @('Google', 'Chrome', 'Application')) }
    if (-not $Owner) {
        foreach ($pf in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($pf) { $appRoots += (Join-Parts $pf @('Google', 'Chrome', 'Application')) }
        }
    }
    foreach ($ar in @($appRoots | Select-Object -Unique)) {
        if (-not (Test-Dir $ar)) { continue }
        foreach ($f in (Get-FilesUnder -Root $ar -MaxDepth 3)) {
            if ($f.Directory.Name -ine 'PlatformExperienceHelper') { continue }
            if ($f.Name -ieq $IOC.DllName -or $f.Name -ieq 'platform_experience_helper.dll.old') {
                Add-Finding -Severity CRITICAL -Title "Chrome 설치 폴더의 PlatformExperienceHelper 에 DLL (이전 버전 에이전트의 지속성 파일로 추정)$tag" `
                    -Detail '정상 Chrome 은 이 자리에 .dll 을 두지 않습니다(정상 구성 요소는 .exe 입니다). 에이전트의 정리 루틴이 지우는 파일 이름과 같습니다. 지속성 DLL 과 같은 순서(레지스트리 키 삭제 -> 재부팅 -> 파일 삭제)로 제거하세요.' -Path $f.FullName `
                    -Evidence @(("{0:N0} 바이트, 수정 {1}" -f $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
            } elseif ($f.Name -ieq 'old-clsid.txt' -or $f.Name -ieq 'service_util.dll') {
                Add-Finding -Severity WARNING -Title "Chrome 설치 폴더의 PlatformExperienceHelper 에 의심 파일$tag" `
                    -Detail '에이전트의 정리 루틴이 지우는 파일 이름과 같습니다(이전 버전 잔재로 추정).' -Path $f.FullName
            }
        }
    }
}

function Check-Temp([string]$TempDir, [string]$Owner) {
    if (-not (Test-Dir $TempDir)) { return }
    $tag = ''
    if ($Owner) { $tag = " (사용자 $Owner)" }
    $k2f = @(); $hex = @()
    try {
        $tempFull = (Get-Item -LiteralPath $TempDir).FullName
        foreach ($f in (Get-FilesUnder -Root $TempDir -MaxDepth 1)) {
            if ($f.Name -match '^(?i)k2f') { $k2f += ("{0} ({1} 바이트, {2})" -f $f.FullName, $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) }
            elseif ($f.Name -match '(?i)insight\.bundle') { $k2f += $f.FullName }
            elseif ($f.DirectoryName -ieq $tempFull -and $f.Extension -ieq '.tmp' -and $f.Length -eq 22) {
                $b = Read-Bytes -Path $f.FullName
                if ($null -ne $b) { $t = $Latin1.GetString($b); if ($t -match '^[0-9a-f]{22}$') { $hex += ("{0}: {1} ({2})" -f $f.Name, $t, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) } }
            }
        }
    } catch { $script:Stats.Errors++ }
    if ($k2f.Count -gt 0) {
        Add-Finding -Severity CRITICAL -Title "Temp 폴더에 에이전트 임시 파일$tag" `
            -Detail '에이전트는 수집한 브라우저 자격증명을 k2f-bcreds-*, 화면 캡처를 k2f_screen_*.jpg 로 임시 저장합니다. (보통 사용 직후 지우므로 없다고 안전한 것은 아닙니다)' -Path $TempDir -Evidence $k2f
    }
    if ($hex.Count -gt 0) {
        Add-Finding -Severity INFO -Title "Temp 에 22바이트 16진수 .tmp 파일$tag" `
            -Detail '감염 PC에서 에이전트 다운로드 1초 전에 쓰인 파일과 같은 형태입니다. 다른 Tencent 소프트웨어도 같은 파일을 만들므로 판정에는 쓰지 않습니다.' -Path $TempDir -Evidence $hex
    }
}

# ------------------------------------------------------------------ 6. 레지스트리 (HKCU CLSID 하이재킹)
function Check-Registry {
    Write-Step '[6/8] 레지스트리 지속성 키를 확인하는 중...'
    $hits = 0
    $paths = @(
        "HKCU:\Software\Classes\CLSID\$($IOC.Clsid)",
        "HKCU:\Software\Classes\WOW6432Node\CLSID\$($IOC.Clsid)"
    )
    foreach ($p in $paths) {
        try {
            if (Test-Path -LiteralPath $p) {
                $hits++
                $val = Get-RegValue (Join-Path $p 'InprocServer32') ''
                if ($null -eq $val) { $val = '(InprocServer32 없음 또는 기본값 비어 있음)' }
                Add-Finding -Severity CRITICAL -Title '레지스트리 지속성 발견 (HKCU CLSID 하이재킹)' `
                    -Detail '이 CLSID 는 Windows 자체(HKLM, wpc.dll)에도 있지만 HKCU 아래에 있는 것은 공격자가 만든 것입니다. Chrome 이 이 키를 통해 악성 DLL 을 불러옵니다. 기본값이 비어 있어도 에이전트의 chrome_uninstall 이 남긴 것이니 지우세요. (삭제 -> 재부팅 -> DLL 폴더 삭제)' `
                    -Path $p -Evidence @("InprocServer32 (기본값) = $val")
            }
        } catch { $script:Stats.Errors++ }
    }
    # 다른 사용자 하이브 (로그인된 사용자만 HKU 에 올라옵니다)
    try {
        $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null
        }
        foreach ($k in (Get-ChildItem -Path 'HKU:\' -ErrorAction SilentlyContinue)) {
            $n = $k.PSChildName
            if ($n -eq $mySid -or $n -eq "${mySid}_Classes" -or $n -eq '.DEFAULT') { continue }
            $cands = @()
            if ($n -match '_Classes$') { $cands += "HKU:\$n\CLSID\$($IOC.Clsid)" } else { $cands += "HKU:\$n\Software\Classes\CLSID\$($IOC.Clsid)" }
            foreach ($p in $cands) {
                if (Test-Path -LiteralPath $p) {
                    $hits++
                    $val = Get-RegValue (Join-Path $p 'InprocServer32') ''
                    Add-Finding -Severity CRITICAL -Title '다른 사용자 계정의 레지스트리에 지속성 키' -Detail '다른 Windows 사용자 계정에도 공격자 CLSID 키가 있습니다.' -Path $p -Evidence @("InprocServer32 (기본값) = $val")
                }
            }
        }
    } catch { }
    # 변형 대비: HKCU 의 다른 CLSID 가 브라우저 프로필(User Data) 안의 DLL 이나 PlatformExperienceHelper 를 가리키는지
    try {
        foreach ($clsRoot in @('HKCU:\Software\Classes\CLSID', 'HKCU:\Software\Classes\WOW6432Node\CLSID')) {
            if (-not (Test-Path -LiteralPath $clsRoot)) { continue }
            foreach ($k in (Get-ChildItem -LiteralPath $clsRoot -ErrorAction SilentlyContinue)) {
                if ($k.PSChildName -ieq $IOC.Clsid) { continue }
                $v = Get-RegValue (Join-Path $k.PSPath 'InprocServer32') ''
                if (-not $v) { continue }
                if (($v -match '(?i)\\User Data\\') -or ($v -match '(?i)PlatformExperienceHelper') -or ($v -match '(?i)platform_experience_helper\.dll')) {
                    $hits++
                    Add-Finding -Severity CRITICAL -Title 'HKCU 의 다른 CLSID 가 브라우저 프로필 안의 DLL 을 가리킴 (변형 지속성 의심)' `
                        -Detail '정상적인 COM 등록은 브라우저 User Data 폴더 안의 DLL 을 가리키지 않습니다. 알려진 CLSID 가 아니어도 같은 수법일 수 있으니, 가리키는 DLL 을 확인하고 같은 순서로 제거하세요.' -Path $k.PSPath -Evidence @("InprocServer32 (기본값) = $v")
                }
            }
        }
    } catch { }
    if ($hits -eq 0) {
        Add-Finding -Severity INFO -Title '레지스트리 지속성 키 없음' -Detail ("HKCU\Software\Classes\CLSID\{0} (및 WOW6432Node) 가 없고, 브라우저 프로필 안의 DLL 을 가리키는 다른 HKCU CLSID 도 없습니다." -f $IOC.Clsid)
    }
}

# ------------------------------------------------------------------ 7. 실행 중 프로세스 / 로드된 DLL
function Check-Processes {
    Write-Step '[7/8] 실행 중인 프로세스와 로드된 DLL 을 확인하는 중...'
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(?i)(nikke_launcher|tbs_browser)' })
        if ($procs.Count -gt 0) {
            $ev = @()
            foreach ($p in $procs) {
                $path = ''
                try { $path = $p.Path } catch { }
                $ev += ("{0} (PID {1}) {2}" -f $p.ProcessName, $p.Id, $path)
            }
            Add-Finding -Severity CRITICAL -Title 'NIKKE 런처(또는 내장 브라우저 tbs_browser)가 지금 실행 중' `
                -Detail '지금 바로 종료하세요. 에이전트는 런처(내장 브라우저)가 켜져 있는 동안만 공격자 서버와 통신합니다. 작업 관리자(Ctrl+Shift+Esc)에서 nikke_launcher.exe 를 끝내세요.' -Evidence $ev
        } else {
            Add-Finding -Severity INFO -Title 'NIKKE 런처 실행 중 아님' -Detail 'nikke_launcher / tbs_browser 프로세스가 없습니다.'
        }
    } catch { $script:Stats.Errors++ }

    try {
        $out = @(& tasklist.exe /fi "MODULES eq $($IOC.DllName)" /fo csv /nh 2>$null)
        $rows = @($out | Where-Object { $_ -is [string] -and $_.StartsWith('"') -and $_.Contains('","') })
        if ($rows.Count -gt 0) {
            Add-Finding -Severity CRITICAL -Title '악성 DLL(platform_experience_helper.dll)이 현재 프로세스에 로드됨' `
                -Detail '지속성 DLL 이 지금 동작 중입니다. 인터넷 연결을 끊고 레지스트리 키를 지운 뒤 재부팅하세요.' -Evidence $rows
        }
    } catch { }

    # 에이전트의 제어 채널(k2f_chan)은 명명 파이프로 보고됨. 열려 있으면 지금 동작 중.
    try {
        $pipes = @([System.IO.Directory]::GetFiles('\\.\pipe\'))
        $k2fPipes = @($pipes | Where-Object { $_ -match '(?i)k2f' })
        if ($k2fPipes.Count -gt 0) {
            Add-Finding -Severity CRITICAL -Title '에이전트의 제어 채널(k2f 명명 파이프)이 지금 열려 있음' `
                -Detail '에이전트가 현재 이 PC에서 동작하고 있습니다. 즉시 인터넷 연결을 끊고 런처(nikke_launcher.exe, tbs_browser.exe)를 종료하세요.' -Evidence $k2fPipes
        }
    } catch { }
}

# ------------------------------------------------------------------ 8. DNS 캐시 / 네트워크 연결 / hosts
function Check-Network {
    Write-Step '[8/8] DNS 캐시, 네트워크 연결, hosts 파일을 확인하는 중...'
    # DNS 캐시 (PC 안의 캐시만 읽습니다. 재부팅하면 지워집니다.)
    $dnsHits = @()
    try {
        $cache = @(Get-DnsClientCache -ErrorAction Stop)
        foreach ($e in $cache) {
            $s = ("{0} {1} {2}" -f $e.Entry, $e.Name, $e.Data)
            if ($s -match '(?i)insightjs') { $dnsHits += $s.Trim() }
        }
    } catch {
        try {
            $raw = @(& ipconfig.exe /displaydns 2>$null)
            foreach ($l in $raw) { if ($l -match '(?i)insightjs') { $dnsHits += $l.Trim() } }
        } catch { }
    }
    if ($dnsHits.Count -gt 0) {
        $agentStage = ($dnsHits -join ' ') -match '(?i)analytics\.insightjs'
        $extra = ''
        if ($agentStage) { $extra = ' analytics.insightjs.com 조회는 에이전트 단계(페이로드 다운로드)까지 갔을 가능성이 큽니다.' }
        Add-Finding -Severity WARNING -Title 'DNS 캐시에 공격자 도메인 조회 기록' `
            -Detail ("최근(마지막 재부팅 이후) 이 PC가 insightjs 도메인을 조회했습니다. insightjs.com 조회는 로더 실행, " + $extra + ' 단, 브라우저로 이 도메인을 직접 열어 본 경우에도 기록이 생깁니다.') -Evidence $dnsHits
    }

    # 현재 TCP 연결
    $conns = @(); $tw = @()
    try {
        foreach ($c in @(Get-NetTCPConnection -ErrorAction Stop)) {
            if ($IOC.IPs -contains $c.RemoteAddress) {
                $s = ("{0}:{1} -> {2}:{3} {4} (PID {5})" -f $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $c.State, $c.OwningProcess)
                if ($c.State -eq 'TimeWait') { $tw += $s } else { $conns += $s }
            }
        }
    } catch {
        try {
            foreach ($l in @(& netstat.exe -ano 2>$null)) {
                $hit = $false
                foreach ($ip in $IOC.IPs) { if ($l -match [regex]::Escape($ip)) { $hit = $true } }
                if ($hit) { if ($l -match 'TIME_WAIT') { $tw += $l.Trim() } else { $conns += $l.Trim() } }
            }
        } catch { }
    }
    if ($conns.Count -gt 0) {
        Add-Finding -Severity CRITICAL -Title '공격자 서버 IP 와 현재 연결 중' -Detail '지금 인터넷 연결을 끊고 런처를 종료하세요.' -Evidence $conns
    } elseif ($tw.Count -gt 0) {
        Add-Finding -Severity WARNING -Title '공격자 서버 IP 와 최근 연결 흔적 (TIME_WAIT)' -Detail '몇 분 전까지 연결이 있었습니다.' -Evidence $tw
    }

    # hosts 파일 (보호 상태)
    $hostsPath = $HostsOverride
    if (-not $hostsPath) {
        if ($onWindows) { $hostsPath = Join-Parts $env:SystemRoot @('System32', 'drivers', 'etc', 'hosts') } else { $hostsPath = '/etc/hosts' }
    }
    $blocked = @{}
    foreach ($d in $IOC.Domains) { $blocked[$d] = $false }
    $hostsNote = ''
    if (Test-File $hostsPath) {
        try {
            foreach ($line in (Get-Content -LiteralPath $hostsPath -ErrorAction Stop)) {
                $l = $line
                $h = $l.IndexOf('#')
                if ($h -ge 0) { $l = $l.Substring(0, $h) }
                $parts = @($l -split '\s+' | Where-Object { $_ })
                if ($parts.Count -lt 2) { continue }
                if ($parts[0] -notin @('0.0.0.0', '127.0.0.1', '::1', '::')) { continue }
                for ($i = 1; $i -lt $parts.Count; $i++) {
                    foreach ($d in $IOC.Domains) { if ($parts[$i] -ieq $d) { $blocked[$d] = $true } }
                }
            }
        } catch { $hostsNote = 'hosts 파일을 읽을 수 없어 차단 여부를 알 수 없습니다.' }
    } else { $hostsNote = 'hosts 파일이 없어 아무것도 차단하지 않습니다.' }
    $ev = @()
    $missing = @()
    foreach ($d in $IOC.Domains) {
        if ($blocked[$d]) { $ev += "$d : 차단됨" } else { $ev += "$d : 차단 안 됨"; $missing += "0.0.0.0 $d" }
    }
    $detail = 'hosts 파일로 공격자 도메인을 막아두면 남아 있는 캐시나 아직 교체되지 않은 CDN 서버의 변조 파일이 다시 로더를 불러도 연결이 되지 않습니다. 이 항목은 감염 여부가 아닌 보호 상태입니다.'
    if ($hostsNote) { $detail = $hostsNote + ' ' + $detail }
    if ($missing.Count -gt 0) { $detail += ' 관리자 권한 메모장으로 hosts 파일 끝에 다음 줄을 추가하세요: ' + ($missing -join ' / ') + ' . IP 89.127.233.127 과 89.126.250.172 는 hosts 로 막을 수 없으니 방화벽에서 차단하세요.' }
    Add-Finding -Severity INFO -Title '보호 상태: hosts 파일의 공격자 도메인 차단 여부' -Detail $detail -Path $hostsPath -Evidence $ev
}

# ------------------------------------------------------------------ 9. 참고 정보 (브라우저, 개발자 자격증명 파일 존재 여부)
function Check-Context([string]$UserProfile, [string]$AppData, [string]$LocalAppData) {
    $browsers = @()
    $pairs = @(
        @('Chrome',  (Join-Parts $LocalAppData @('Google', 'Chrome', 'User Data'))),
        @('Edge',    (Join-Parts $LocalAppData @('Microsoft', 'Edge', 'User Data'))),
        @('Brave',   (Join-Parts $LocalAppData @('BraveSoftware', 'Brave-Browser', 'User Data'))),
        @('Vivaldi', (Join-Parts $LocalAppData @('Vivaldi', 'User Data'))),
        @('Opera',   (Join-Parts $AppData @('Opera Software', 'Opera Stable'))),
        @('Firefox', (Join-Parts $AppData @('Mozilla', 'Firefox', 'Profiles'))),
        @('Whale',   (Join-Parts $LocalAppData @('Naver', 'Naver Whale', 'User Data')))
    )
    foreach ($p in $pairs) { if (Test-Dir $p[1]) { $browsers += $p[0] } }
    if ($browsers.Count -gt 0) {
        Add-Finding -Severity INFO -Title ('이 PC의 브라우저 프로필: ' + ($browsers -join ', ')) `
            -Detail '감염이 확인되면 이 브라우저들에 저장된 비밀번호·쿠키는 모두 유출됐다고 보고, 깨끗한 기기에서 비밀번호를 바꾸고 모든 세션에서 로그아웃하세요. (Whale 은 알려진 수집 대상 목록에 없지만 exec 명령으로 어떤 파일이든 읽을 수 있었습니다)'
    }
    $creds = @()
    $credPaths = @(
        @('SSH 키',                 (Join-Path $UserProfile '.ssh')),
        @('Claude Code 자격증명',   (Join-Parts $UserProfile @('.claude', '.credentials.json'))),
        @('Codex CLI 자격증명',     (Join-Parts $UserProfile @('.codex', 'auth.json'))),
        @('GitHub CLI 토큰',        (Join-Parts $AppData @('GitHub CLI', 'hosts.yml'))),
        @('Git 자격증명 저장소',    (Join-Path $UserProfile '.git-credentials')),
        @('AWS 자격증명',           (Join-Parts $UserProfile @('.aws', 'credentials'))),
        @('npm 토큰(.npmrc)',       (Join-Path $UserProfile '.npmrc')),
        @('Docker 로그인',          (Join-Parts $UserProfile @('.docker', 'config.json'))),
        @('Kubernetes 설정',        (Join-Parts $UserProfile @('.kube', 'config'))),
        @('gcloud 자격증명',        (Join-Parts $AppData @('gcloud', 'credentials.db'))),
        @('Azure CLI 토큰',         (Join-Parts $UserProfile @('.azure', 'msal_token_cache.bin'))),
        @('VS Code 상태 DB',        (Join-Parts $AppData @('Code', 'User', 'globalStorage', 'state.vscdb'))),
        @('Cursor 상태 DB',         (Join-Parts $AppData @('Cursor', 'User', 'globalStorage', 'state.vscdb'))),
        @('PowerShell 명령 기록',   (Join-Parts $AppData @('Microsoft', 'Windows', 'PowerShell', 'PSReadLine', 'ConsoleHost_history.txt'))),
        @('FileZilla 사이트 관리자', (Join-Parts $AppData @('FileZilla', 'sitemanager.xml'))),
        @('GnuPG 키',               (Join-Path $AppData 'gnupg'))
    )
    foreach ($c in $credPaths) { if (Test-Path -LiteralPath $c[1]) { $creds += $c[0] } }
    if ($creds.Count -gt 0) {
        Add-Finding -Severity INFO -Title ('에이전트의 수집 대상 목록에 있는 자격증명 파일이 이 PC에 있음: ' + ($creds -join ', ')) `
            -Detail '에이전트(keyscan)는 264개 경로의 토큰·키 파일을 읽어 공격자에게 보냅니다. 감염이 확인되면 이 항목들의 토큰·키를 모두 폐기하고 새로 만드세요. 이 스크립트는 파일 존재 여부만 확인하고 내용은 읽지 않습니다.'
    }
}

# ================================================================== 실행
Write-Host ''
Write-Host ("NIKKE PC 런처 감염 흔적 점검 v{0} (읽기 전용)" -f $ScriptVersion) -ForegroundColor Cyan
Write-Host '파일을 삭제·수정하지 않고, 레지스트리와 hosts 를 바꾸지 않으며, 네트워크에 접속하지 않습니다.' -ForegroundColor DarkGray
Write-Host ''

$AppData      = if ($AppDataOverride)      { $AppDataOverride }      else { $env:APPDATA }
$LocalAppData = if ($LocalAppDataOverride) { $LocalAppDataOverride } else { $env:LOCALAPPDATA }
$TempDir      = if ($TempOverride)         { $TempOverride }         else { $env:TEMP }
$UserProfile  = $env:USERPROFILE
if (-not $UserProfile) { $UserProfile = $HOME }
$UsersRoot    = if ($UsersRootOverride)    { $UsersRootOverride }    elseif ($UserProfile) { Split-Path -Path $UserProfile -Parent } else { '' }
$isAdmin = $false
if ($onWindows) {
    try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
}

# [1/8] 런처 데이터 폴더: 현재 사용자 + 읽을 수 있는 다른 사용자 프로필
Write-Step '[1/8] 런처 데이터 폴더(%APPDATA%\nikke_launcher*)를 찾는 중...'
Find-DataDirs -AppData $AppData -Owner ''
if ($AppDataOverride -and -not $LocalAppDataOverride) { $LocalAppData = Join-Parts (Split-Path -Path $AppDataOverride -Parent) @('Local') }

$otherProfiles = @()
if (Test-Dir $UsersRoot) {
    $skipProfiles = @('Public', 'Default', 'Default User', 'All Users', 'desktop.ini')
    $myProfileFull = ''
    try { if ($UserProfile) { $myProfileFull = (Get-Item -LiteralPath $UserProfile -ErrorAction Stop).FullName } } catch { }
    try {
        foreach ($prof in (Get-ChildItem -LiteralPath $UsersRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($skipProfiles -contains $prof.Name) { continue }
            if ($myProfileFull -and ($prof.FullName -ieq $myProfileFull)) { continue }
            if (($prof.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $roam  = Join-Parts $prof.FullName @('AppData', 'Roaming')
            $local = Join-Parts $prof.FullName @('AppData', 'Local')
            if (-not (Test-Dir $roam) -and -not (Test-Dir $local)) { continue }
            $readable = $false
            foreach ($probe in @($local, $roam)) {
                if (-not (Test-Dir $probe)) { continue }
                try { [void](Get-ChildItem -LiteralPath $probe -Force -ErrorAction Stop | Select-Object -First 1); $readable = $true } catch { }
            }
            if (-not $readable) {
                [void]$script:Notes.Add(("다른 사용자 프로필 {0} 은(는) 읽을 수 없어 점검하지 못했습니다. 관리자 권한 PowerShell 에서 다시 실행하면 확인됩니다." -f $prof.FullName))
                continue
            }
            $otherProfiles += , @{ Name = $prof.Name; Path = $prof.FullName; Roam = $roam; Local = $local }
            Find-DataDirs -AppData $roam -Owner $prof.Name
        }
    } catch { }
}

Find-Installs

if ($script:InstallsFound.Count -eq 0 -and $script:DataDirsFound.Count -eq 0) {
    [void]$script:Notes.Add('NIKKE 설치 폴더와 런처 데이터 폴더를 찾지 못했습니다. 다른 위치에 설치했다면 -NikkePath "경로" 로 지정하거나 -DeepScan 으로 다시 실행하세요.')
} elseif ($script:InstallsFound.Count -eq 0) {
    Add-Finding -Severity INFO -Title 'NIKKE 설치 폴더를 찾지 못해 debug.log 와 다운로드 로그는 확인하지 못함' `
        -Detail '런처 데이터 폴더만 확인했습니다. NIKKE 를 지웠거나 재설치했다면 이전 로그는 사라진 것이고, 다른 위치에 설치했다면 -NikkePath "경로" 로 지정해 다시 실행하세요.'
}

Write-Step '[3/8] NIKKE 설치 폴더의 debug.log 와 다운로드 로그를 확인하는 중...'
foreach ($inst in @($script:InstallsFound)) { Check-Install $inst }

Write-Step '[4/8] 런처 데이터 폴더(캐시, Local Storage)를 확인하는 중...'
foreach ($dd in @($script:DataDirsFound)) { Check-LauncherData -DataDir $dd.Path -Owner $dd.Owner }

Write-Step '[5/8] 사용자 프로필(브라우저 지속성 DLL, Temp)을 확인하는 중...'
[void]$script:Locations.Add("[사용자 프로필] $UserProfile")
Check-ChromeHelper -LocalAppData $LocalAppData -AppData $AppData -Owner ''
Check-Temp -TempDir $TempDir -Owner ''
$localTemp = ''
if ($LocalAppData) { $localTemp = Join-Path $LocalAppData 'Temp' }
if ($TempDir -and $localTemp -and ($localTemp -ine $TempDir)) { Check-Temp -TempDir $localTemp -Owner '' }
Check-Context -UserProfile $UserProfile -AppData $AppData -LocalAppData $LocalAppData
foreach ($op in $otherProfiles) {
    [void]$script:Locations.Add("[사용자 프로필] $($op.Path)")
    Check-ChromeHelper -LocalAppData $op.Local -AppData $op.Roam -Owner $op.Name
    Check-Temp -TempDir (Join-Path $op.Local 'Temp') -Owner $op.Name
}

if ($doSystemChecks) {
    Check-Registry
    Check-Processes
    Check-Network
} else {
    [void]$script:Notes.Add('레지스트리, 프로세스, DNS 캐시, 네트워크 연결 점검은 생략됐습니다.')
    if ($HostsOverride) { Check-Network }
}
if ($script:Stats.Errors -gt 0) {
    [void]$script:Notes.Add(("파일/폴더 {0}개를 열 수 없었습니다. 런처가 실행 중이면 종료한 뒤, 또는 관리자 권한 PowerShell 에서 다시 실행하면 더 많이 확인됩니다." -f $script:Stats.Errors))
}

# ================================================================== 판정
$crit = @($script:Findings | Where-Object { $_.Severity -eq 'CRITICAL' })
$warn = @($script:Findings | Where-Object { $_.Severity -eq 'WARNING' })
$info = @($script:Findings | Where-Object { $_.Severity -eq 'INFO' })
$foundNikke = ($script:InstallsFound.Count -gt 0) -or ($script:DataDirsFound.Count -gt 0)

if ($crit.Count -gt 0) {
    $verdict = 'INFECTED'; $exitCode = 2
    $verdictTitle = '감염 흔적 확인'
    $verdictText  = '에이전트가 내려받아졌거나 실행됐거나, 지속성 흔적이 있거나, 런처가 현재 실행 중입니다. 런처가 켜져 있던 동안 공격자는 이 PC에서 명령을 실행할 수 있었습니다. 이 PC는 침해된 것으로 간주하세요.'
} elseif ($warn.Count -gt 0) {
    $verdict = 'EXPOSED'; $exitCode = 1
    $verdictTitle = '노출 (로더 실행 흔적, 에이전트 실행 흔적은 없음)'
    $verdictText  = '런처가 악성 스크립트를 불러오거나 insightjs.com 에 접속한 흔적은 있지만, 에이전트가 실행된 흔적은 찾지 못했습니다.'
} elseif ($foundNikke) {
    $verdict = 'NO_TRACES'; $exitCode = 0
    $verdictTitle = '흔적 없음'
    if ($script:InstallsFound.Count -gt 0) {
        $verdictText = '찾은 NIKKE 파일에서 악성 스크립트나 에이전트의 흔적을 찾지 못했습니다. 아무것도 없다는 것이 깨끗함을 증명하지는 않습니다.'
    } else {
        $verdictText = '런처 데이터 폴더에서 악성 스크립트나 에이전트의 흔적을 찾지 못했습니다. NIKKE 설치 폴더(debug.log, 다운로드 로그)는 찾지 못해 확인하지 않았습니다. 아무것도 없다는 것이 깨끗함을 증명하지는 않습니다.'
    }
} else {
    $verdict = 'NOT_FOUND'; $exitCode = 3
    $verdictTitle = 'NIKKE 미발견'
    $verdictText  = '점검한 위치에서 NIKKE 설치 폴더와 런처 데이터 폴더를 찾지 못했습니다.'
}

$launchedAfterOct24 = $false
if ($script:LauncherLastWrite -and $script:LauncherLastWrite -ge (Get-Date -Year 2026 -Month 10 -Day 24 -Hour 0 -Minute 0 -Second 0)) { $launchedAfterOct24 = $true }
$debugLogNote = ''
if ($script:DebugLogsChecked -eq 0 -and ($verdict -eq 'NO_TRACES' -or $verdict -eq 'EXPOSED')) {
    $debugLogNote = '주의: 에이전트 실행 여부를 가장 잘 보여 주는 로그(Launcher\intl_service\debug.log)를 하나도 확인하지 못했으므로 이 판정은 불완전합니다. (설치 폴더 미발견, NIKKE 삭제/재설치, 또는 읽기 권한 문제)'
}

# ================================================================== 보고서 작성
$R = New-Object System.Collections.ArrayList
function L([string]$s = '') { [void]$R.Add($s) }

$computerName = $env:COMPUTERNAME
if (-not $computerName) { try { $computerName = [System.Environment]::MachineName } catch { } }
$userName = $env:USERNAME
if (-not $userName) { try { $userName = [System.Environment]::UserName } catch { } }
L ("NIKKE PC 런처 감염 흔적 점검 v{0} (읽기 전용)" -f $ScriptVersion)
L ("실행 시각: {0}   컴퓨터: {1}   사용자: {2}   관리자 권한: {3}" -f $StartedAt.ToString('yyyy-MM-dd HH:mm:ss'), $computerName, $userName, $(if ($isAdmin) { '예' } else { '아니오' }))
L ("PowerShell {0}   OS: {1}" -f $PSVersionTable.PSVersion.ToString(), [System.Environment]::OSVersion.VersionString)
L ''
L ("판정: {0}" -f $verdictTitle)
L $verdictText
if ($debugLogNote) { L $debugLogNote }
if ($launchedAfterOct24 -and $verdict -ne 'INFECTED') { L ("참고: debug.log 마지막 수정이 {0} 이라 2026-10-24 이후에 런처를 실행한 기록이 있습니다. 에이전트는 10월 24일부터 일부 실행에서만 배포됐으므로, 흔적이 없어도 비밀번호 변경을 권합니다." -f $script:LauncherLastWrite.ToString('yyyy-MM-dd HH:mm')) }
L ''
L '확인한 위치:'
if ($script:Locations.Count -eq 0) { L '  (없음)' }
foreach ($loc in $script:Locations) { L ("  {0}" -f $loc) }
foreach ($n in $script:Notes) { L ("  * {0}" -f $n) }
L ''
L ("발견 사항: CRITICAL {0} / WARNING {1} / INFO {2}" -f $crit.Count, $warn.Count, $info.Count)
L '----------------------------------------------------------------------'
foreach ($f in @($crit + $warn + $info)) {
    L ("[{0}] {1}" -f $f.Severity, $f.Title)
    if ($f.Detail) { L ("    {0}" -f $f.Detail) }
    if ($f.Path)   { L ("    경로: {0}" -f $f.Path) }
    foreach ($e in $f.Evidence) { L ("    | {0}" -f $e) }
    L ''
}
L '----------------------------------------------------------------------'
L '해야 할 일'
switch ($verdict) {
    'INFECTED' {
        L ' 1. 지금 NIKKE 런처를 끄고 이 PC의 인터넷 연결을 끊으세요. (작업 관리자에서 nikke_launcher.exe 종료)'
        L ' 2. Level Infinite 가 수정 완료를 공식 발표하기 전까지 런처를 다시 켜지 마세요.'
        L ' 3. 이 보고서 파일을 먼저 보관하세요. tbs_cache 를 지우면 k2f.agent.state 흔적도 함께 사라집니다.'
        L ' 4. 런처를 다시 켜기 전에 %APPDATA%\nikke_launcher\tbs_cache 폴더를 지우세요. (변조 파일이 캐시에 남아 있을 수 있음)'
        L ' 5. hosts 파일에 insightjs.com / www.insightjs.com / analytics.insightjs.com / insightjs.org 를 0.0.0.0 으로 추가하고, 방화벽에서 89.127.233.127 과 89.126.250.172 를 차단하세요.'
        L ' 6. "Chrome 지속성 DLL" 또는 "레지스트리 지속성" 이 발견됐다면: HKCU\Software\Classes\CLSID\{E77CC89B-7401-4C04-8CED-149DB35ADD04} 삭제 -> 재부팅 -> PlatformExperienceHelper 아래 64자리 16진수 폴더 삭제. (HKLM 의 같은 CLSID 는 Windows 정상 항목이니 건드리지 마세요)'
        L ' 7. 가장 확실한 복구는 Windows 재설치입니다. 에이전트는 임의 명령을 실행할 수 있었고, 어떤 명령이 실행됐는지 로그에 남지 않습니다.'
        L ' 8. 깨끗한 기기(스마트폰 등)에서 비밀번호를 바꾸세요: NIKKE/Level Infinite -> 이메일 -> Discord -> 금융 -> 브라우저에 저장된 모든 비밀번호. 2단계 인증을 켜세요.'
        L ' 9. Google, Discord, Steam, GitHub 등 모든 서비스에서 "모든 세션 로그아웃" 을 하세요. 훔친 쿠키는 비밀번호 없이도 쓸 수 있습니다.'
        L '10. 이 PC에 있던 API 토큰·SSH 키·개발 도구 자격증명(GitHub, npm, AWS, OpenAI/Codex, Anthropic/Claude Code 등)을 모두 폐기하고 새로 만드세요.'
        L '11. 암호화폐 지갑이 있다면 깨끗한 기기에서 새 시드 구문의 지갑을 만들어 자금을 옮기세요.'
    }
    'EXPOSED' {
        L ' 1. Level Infinite 가 수정 완료를 공식 발표하기 전까지 런처를 켜지 마세요.'
        L ' 2. 런처를 다시 켜기 전에 %APPDATA%\nikke_launcher\tbs_cache 폴더를 지우세요. (변조 파일이 캐시에 남아 있을 수 있음)'
        L ' 3. hosts 파일에 insightjs.com / www.insightjs.com / analytics.insightjs.com / insightjs.org 를 0.0.0.0 으로 추가하고, 방화벽에서 89.127.233.127 과 89.126.250.172 를 차단하세요.'
        L ' 4. 에이전트는 2026-10-24 부터 일부 실행에서만 배포됐습니다. 그 이후에 런처를 켠 적이 있다면 감염된 것처럼 대응하세요: 깨끗한 기기에서 비밀번호 변경(NIKKE -> 이메일 -> Discord -> 금융 -> 브라우저 저장 비밀번호), 모든 세션 로그아웃, API 토큰·SSH 키 폐기, 암호화폐는 새 지갑으로 이동.'
    }
    'NO_TRACES' {
        L ' 1. Level Infinite 가 수정 완료를 공식 발표하기 전까지 런처를 켜지 마세요.'
        L ' 2. 런처를 다시 켜기 전에 %APPDATA%\nikke_launcher\tbs_cache 폴더를 지우세요.'
        L ' 3. hosts 파일에 insightjs.com / www.insightjs.com / analytics.insightjs.com / insightjs.org 를 0.0.0.0 으로 추가하고, 방화벽에서 89.127.233.127 과 89.126.250.172 를 차단하세요.'
        L ' 4. 2026-10-24 이후에 런처를 켠 적이 있다면 깨끗한 기기에서 NIKKE/Level Infinite 비밀번호는 바꿔 두세요.'
    }
    default {
        L ' 1. NIKKE 를 다른 곳에 설치했다면 -NikkePath "설치폴더" 를 지정하거나 -DeepScan 으로 다시 실행하세요.'
        L ' 2. Level Infinite 가 수정 완료를 공식 발표하기 전까지 런처를 켜지 마세요.'
        L ' 3. hosts 파일에 insightjs.com / www.insightjs.com / analytics.insightjs.com / insightjs.org 를 0.0.0.0 으로 추가하고, 방화벽에서 89.127.233.127 과 89.126.250.172 를 차단하세요.'
    }
}
L ''
L '이 점검의 한계'
L ' - debug.log 와 tinyget 로그는 NIKKE 폴더 안에 있어 NIKKE 를 지우거나 재설치하면 사라집니다. 런처 데이터의 k2f.agent.state 점검은 이와 별개입니다.'
L ' - 아무것도 찾지 못했다는 것이 PC가 깨끗하다는 증명은 아닙니다.'
L ' - 에이전트가 실행한 명령은 로그에 남지 않으므로, 공격자가 무엇을 가져갔는지는 알 수 없습니다.'
L ' - 전체 분석: https://gist.github.com/MotherSphere/d6c049a09ba8ac3085c51ee9df24a4e5'
L ' - 공식 점검 도구(GUI, Windows/Linux/macOS): https://github.com/MotherSphere/NIKKE-Launcher-Check'
L ''
L ("통계: 파일 {0:N0}개 ({1:N1} MB) 확인, 폴더 {2:N0}개, 건너뜀 {3}, 오류 {4}, 소요 {5:N1}초" -f $script:Stats.Files, ($script:Stats.Bytes / 1MB), $script:Stats.Dirs, $script:Stats.Skipped, $script:Stats.Errors, ((Get-Date) - $StartedAt).TotalSeconds)
L '주의: 이 보고서에는 사용자 이름, 컴퓨터 이름, 파일 경로가 들어 있습니다. 공개 게시 전에 확인하세요.'

# ================================================================== 출력
Write-Host ''
foreach ($line in $R) {
    $color = 'Gray'
    if ($line.StartsWith('[CRITICAL]')) { $color = 'Red' }
    elseif ($line.StartsWith('[WARNING]')) { $color = 'Yellow' }
    elseif ($line.StartsWith('[INFO]')) { $color = 'Cyan' }
    elseif ($line.StartsWith('판정:')) {
        $color = 'Green'
        if ($verdict -eq 'INFECTED') { $color = 'Red' } elseif ($verdict -eq 'EXPOSED') { $color = 'Yellow' } elseif ($verdict -eq 'NOT_FOUND') { $color = 'Magenta' }
    }
    elseif ($line.StartsWith('해야 할 일') -or $line.StartsWith('확인한 위치') -or $line.StartsWith('발견 사항') -or $line.StartsWith('이 점검의 한계')) { $color = 'White' }
    Write-Host $line -ForegroundColor $color
}

if (-not $NoReportFile) {
    try {
        if (-not $ReportPath) {
            $desktop = ''
            try { $desktop = [System.Environment]::GetFolderPath('Desktop') } catch { }
            if ((Test-Dir $desktop) -and ($desktop -match '(?i)OneDrive') -and (Test-Dir $UserProfile)) {
                # OneDrive 와 동기화되는 바탕화면이면 개인 정보가 든 보고서가 클라우드에 올라가지 않도록 사용자 폴더에 저장
                $desktop = $UserProfile
                Write-Host '바탕화면이 OneDrive 와 동기화되어 있어 보고서를 사용자 폴더(C:\Users\사용자이름)에 저장합니다.' -ForegroundColor DarkGray
            }
            if (-not (Test-Dir $desktop)) { $desktop = (Get-Location).Path }
            $ReportPath = Join-Path $desktop ("NIKKE_점검결과_{0}.txt" -f $StartedAt.ToString('yyyyMMdd_HHmmss'))
        }
        # 상대 경로는 PowerShell 의 현재 위치 기준으로 풉니다 (.NET 은 프로세스 작업 폴더를 쓰므로 다를 수 있음).
        try { $ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath) } catch { }
        $utf8bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($ReportPath, (($R -join "`r`n") + "`r`n"), $utf8bom)
        Write-Host ''
        Write-Host ("보고서 저장: {0}" -f $ReportPath) -ForegroundColor Green
        Write-Host '이 파일 내용을 그대로 붙여넣으면 결과를 함께 해석할 수 있습니다. (사용자·컴퓨터 이름이 들어 있으니 공개 게시 전에 확인하세요)' -ForegroundColor DarkGray
    } catch {
        Write-Host ("보고서 파일을 저장하지 못했습니다: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# 탐색기에서 "PowerShell에서 실행"으로 띄웠으면 창이 바로 닫히므로 Enter 를 기다립니다.
$pauseNow = [bool]$Pause
if (-not $pauseNow -and $onWindows) {
    try {
        $pp = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
        $pn = (Get-Process -Id $pp -ErrorAction Stop).ProcessName
        if ($pn -ieq 'explorer') { $pauseNow = $true }
    } catch { }
}
if ($pauseNow) {
    Write-Host ''
    try { Read-Host '확인했으면 Enter 키를 누르세요 (창이 닫힙니다)' | Out-Null } catch { }
}

exit $exitCode
