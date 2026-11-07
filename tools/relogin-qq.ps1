# 大肥鱼掉线自救：小号在线就退出；不在线先重启 NapCat 试快速登录，不行就打开扫码页面等扫码。
# 协议端是 SnowLuma 的（private\protocol.txt 写着 snowluma，或者只有 start-snowluma.cmd）：走下面 SnowLuma 那段，只开桌面 QQ 和 SnowLuma，让他在 QQ 窗口里登。
# finish.ps1 把它拷到 <工作目录>\tools\，桌面快捷方式「大肥鱼掉线-双击扫码」指向同目录的 relogin.cmd。
param([string]$Dir = '', [switch]$Autostart, [switch]$DryRun)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = Split-Path $PSScriptRoot }
$Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
function Get-QQState {
    # WebSocket 连着不等于 QQ 仍登录；与守护程序复用同一个口径。
    $py = Find-AstrPython $Dir
    $watch = Join-Path $Dir 'tools\qq_watch.py'
    if ($py -and (Test-Path -LiteralPath $watch)) {
        try {
            $state = & $py -X utf8 -B $watch --dir $Dir --once --ignore-relogin 2>$null | ConvertFrom-Json -ErrorAction Stop
        } catch { throw '无法确认 QQ 状态，未重新启动任何程序。请先在工作台检查状态。' }
        if ($LASTEXITCODE -ne 0 -or -not $state.state) { throw 'QQ 状态检查失败，未重新启动任何程序。' }
        return $state
    }
    throw '缺少 QQ 状态探测程序，未重新启动任何程序。'
}
function Online {
    $state = Get-QQState
    switch ($state.state) {
        'online' { return $true }
        'brain-off' { return $false }
        'offline' { return $false }
        'kicked' { return $false }
        default { throw 'QQ 状态尚不确定，未重新启动任何程序。请先在工作台检查状态。' }
    }
}
function Get-ReloginPlan {
    $probe = Get-QQState
    $actions = @()
    $restart = $false
    if ($probe.state -eq 'online') { $actions += 'already-online; exit' }
    elseif ($probe.state -eq 'brain-off') { $actions += 'start-brain; recheck-before-any-login' }
    elseif ($probe.state -notin @('offline', 'kicked')) { $actions += 'state-unknown; stop-without-changing-programs' }
    elseif ($Autostart -and $probe.needs_scan) { $actions += 'login-expired; wait-for-person-to-scan; keep-current-NapCat' }
    elseif ($Autostart -and $probe.automatic_retry_wait -gt 0) { $actions += 'automatic-cooldown; keep-current-NapCat' }
    else { $restart = $true; $actions += 'check-brain-and-network'; $actions += 'one-NapCat-restart-only'; $actions += 'wait-for-login-or-person-scan; no-restart-loop' }
    return [pscustomobject]@{
        dry_run = $true; state = $probe.state; mode = $(if ($Autostart) { 'automatic' } else { 'manual' })
        login_info = $probe.login_info; log_found = [bool]$probe.log_found; needs_scan = [bool]$probe.needs_scan
        automatic_retry_wait = $probe.automatic_retry_wait; would_restart = $restart; actions = $actions
    }
}
function Write-AutomaticAttempt {
    $path = Join-Path $Dir 'logs\qq-relogin-attempt.json'
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    try {
        $at = [Math]::Floor(([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds)
        [IO.File]::WriteAllText($tmp, (@{at=$at;automatic=$true} | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function Boot-State([string]$State, [string]$Text) {
    if (-not $Autostart) { return }
    try {
        New-Item -ItemType Directory -Force "$Dir\logs" | Out-Null
        [IO.File]::WriteAllText((Join-Path $Dir 'logs/qq-autostart.json'), (@{state=$State;text=$Text;at=(Get-Date).ToString('o');pid=$PID} | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
function Start-Quiet([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "启动文件不存在：$File" }
    $command = "& '" + $File.Replace("'", "''") + "'; exit `$LASTEXITCODE"
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', ('"' + $command + '"')) -WindowStyle Hidden -ErrorAction Stop
}
function Start-Brain {
    $bs = Get-BackendState $Dir -Fresh
    if ($bs.state -eq 'up') { return }
    if ($bs.state -in @('starting', 'stuck')) {
        Write-Host '大脑进程已在运行，先等它准备好，不重复启动。'
        for ($i = 0; $i -lt 90; $i++) {
            if ((Get-BackendState $Dir -Fresh).state -eq 'up') { return }
            Start-Sleep 2
        }
        throw '大脑进程还没准备好，请在工作台查看状态后再试。'
    }
    if (Test-Path "$Dir\start-astrbot.cmd") {
        Write-Host '她的大脑没开着，先打开，大约半分钟……'
        Start-Quiet "$Dir\start-astrbot.cmd"
        for ($i = 0; $i -lt 90; $i++) {
            if ((Get-BackendState $Dir -Fresh).state -eq 'up') { return }
            Start-Sleep 2
        }
        throw '大脑启动超时，请在工作台查看状态后再试。'
    } else { throw '请先在 AstrBot 启动器里启动这个实例，再重新登录。' }
}
function Wait-Ready {
    # 开机不抢跑。实例可能要人手动点，安静一直等，不超时报错。
    while ($true) {
        if (Online) { return }
        $bs = Get-BackendState $Dir -Fresh
        if ($bs.state -ne 'up' -or -not (Get-NetTCPConnection -LocalPort $bs.ws_port -State Listen -ErrorAction SilentlyContinue)) {
            Boot-State 'waiting-brain' '在等大脑。启动器装的，请在启动器里点实例的「启动」。'
        } elseif (-not (Test-QQNetwork)) {
            Boot-State 'waiting-network' '在等网络，准备好就自己登。'
        } else { return }
        Start-Sleep 10
    }
}
# Read-only rehearsal returns before elevation, mutex acquisition, state/QR writes,
# process changes or notifications. The Python probe also disables bytecode writes.
if ($DryRun) { Get-ReloginPlan | ConvertTo-Json -Compress -Depth 4; exit 0 }
$proto = if (Test-Path "$Dir\private\protocol.txt") { "$(Get-Content -Raw "$Dir\private\protocol.txt")".Trim().ToLowerInvariant() } elseif ((Test-Path "$Dir\start-snowluma.cmd") -and -not (Test-Path "$Dir\start-napcat.cmd")) { 'snowluma' } else { 'napcat' }
if ($proto -eq 'napcat' -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if (Online) { exit 0 }
    if ($Autostart) { Boot-State 'needs-admin' '自动重新登录需要最高权限计划任务，请修复自启任务。'; exit 1 }
    # 手动重登才请求提权；此时尚未持有互斥体，提升后的子进程可正常取得它。
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Dir "' + $Dir + '"'
    try {
        $child = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Error '重新登录未取得管理员权限。'; exit 1 }
}
# 开机、双击重登共用同一条路。同一目录同时只能有一个，避免两份抢号。
$sha = [Security.Cryptography.SHA256]::Create()
try { $tag = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir.ToLowerInvariant()))) -replace '-', '').Substring(0,24) } finally { $sha.Dispose() }
$mutex = New-Object Threading.Mutex($false, "Local\DafeiyuQQ-$tag")
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) { Write-Host '已经在后台等大脑或重新登录了，打开工作台能看进度。'; $mutex.Dispose(); exit 0 }
# 脚本退出/异常都会释放命名锁；不留下锁文件。
try {
if ($Autostart) { Wait-Ready; if (Online) { Boot-State 'online' '小号已经连上大脑。'; exit 0 } }

if ($Autostart -and $proto -eq 'snowluma') {
    # SnowLuma 的反向 WS 会自行重连，不重启桌面 QQ，也不把大号打开。
    $me = @(Get-UserStartupIdentity)[0]
    $running = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.ExecutablePath -like "$Dir\SnowLuma\*" } | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Domain)\$($_.User)" }) -eq $me }
    if (-not $running) { Start-Quiet "$Dir\start-snowluma.cmd" }
    Boot-State 'desktop-qq' 'SnowLuma 已打开。桌面 QQ 需在它自己的设置里开自动启动、自动登录小号。'
    exit 0
}

if ($proto -eq 'snowluma') {
    $sl = "$Dir\SnowLuma"; $me = @(Get-UserStartupIdentity)[0]
    function Mine($p) { (Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Domain)\$($_.User)" }) -eq $me }
    function SlRunning { [bool](Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($sl + '\', [StringComparison]::OrdinalIgnoreCase) -and (Mine $_) }) }
    function MyQQ { @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -notmatch '\\NapCat' -and (Mine $_) }) }
    function Show-QQ {
        # 把 QQ 窗口调到最前面（10-29：退出账号后双击重登，登录窗口压在别的窗口底下，要从任务栏点出来）
        try {
            if (-not ('Dfy.Win' -as [type])) { Add-Type -Namespace Dfy -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);' }
            $w = Get-Process -Id @((MyQQ).ProcessId) -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if (-not $w) { return }
            if ([Dfy.Win]::IsIconic($w.MainWindowHandle)) { [Dfy.Win]::ShowWindow($w.MainWindowHandle, 9) | Out-Null }
            # Windows 不让后台程序抢前台，先按一下 Alt 再切（不按的话只会在任务栏闪一下）
            [Dfy.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Dfy.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
            [Dfy.Win]::SetForegroundWindow($w.MainWindowHandle) | Out-Null
        } catch {}
    }
    function Restart-SnowLuma {
        # 只结束 SnowLuma 文件夹里的程序，QQ 不动
        Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($sl + '\', [StringComparison]::OrdinalIgnoreCase) -and (Mine $_) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep 2
        Start-Quiet "$Dir\start-snowluma.cmd"
    }
    Write-Host ''
    Write-Host '==== 大肥鱼重新登录（SnowLuma）====' -ForegroundColor Cyan
    if (Online) { Write-Host '她现在是在线的，不用登。还是不回话的话，打开桌面的「大肥鱼工作台」点「复制求助信息」，把那句话发我。' -ForegroundColor Green; exit 0 }
    Start-Brain
    if (Online) { Write-Host '好了，她回来了，可以关掉这个窗口了。' -ForegroundColor Green; exit 0 }
    if (-not (SlRunning)) { Write-Host '帮她登 QQ 的 SnowLuma 没开着，先打开……'; Start-Quiet "$Dir\start-snowluma.cmd"; Start-Sleep 8 }
    if (-not (MyQQ).Count) {
        $qqExe = $null
        if (Test-Path "$Dir\start-qq.cmd") { $qqExe = ([regex]::Match((Get-Content -Raw "$Dir\start-qq.cmd"), 'start "" "([^"]+)"')).Groups[1].Value }
        if (-not $qqExe -or -not (Test-Path $qqExe)) { $qqExe = @("$env:ProgramFiles\Tencent\QQNT\QQ.exe", "${env:ProgramFiles(x86)}\Tencent\QQNT\QQ.exe") + @(Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^(腾讯)?QQ$' -and $_.UninstallString } | ForEach-Object { Join-Path (Split-Path ($_.UninstallString -replace '"', '')) 'QQ.exe' }) | Where-Object { Test-Path $_ } | Select-Object -First 1 }
        if (-not $qqExe) { Write-Host '没找到桌面 QQ，打开桌面的「大肥鱼工作台」点「复制求助信息」，把那句话发我。' -ForegroundColor Red; exit 1 }
        Write-Host '桌面 QQ 没开着，帮你打开了。'
        Start-Process $qqExe
    }
    for ($i = 0; $i -lt 30 -and -not (Online); $i++) { Start-Sleep 1 }
    if (Online) { Write-Host '已经自动登上了，可以关掉这个窗口了。' -ForegroundColor Green; exit 0 }
    Write-Host '请在桌面 QQ 的窗口里登小号：有小号头像就点「登录」；是二维码就用登着小号的手机 QQ 扫一扫，再在手机上点「登录」。' -ForegroundColor Yellow
    Show-QQ
    Write-Host '（最多等 10 分钟）'
    $deadline = (Get-Date).AddMinutes(10); $kicked = $false; $t0 = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 3
        if (Online) { Write-Host ''; Write-Host '登录成功，她回来了，可以关掉这个窗口了。' -ForegroundColor Green; exit 0 }
        # QQ 已经登着、SnowLuma 却没连上：重启一次 SnowLuma（它会重新挂到开着的 QQ 上，不动 QQ）
        if (-not $kicked -and ((Get-Date) - $t0).TotalSeconds -gt 60) { $kicked = $true; Write-Host '重启一次 SnowLuma 再试……'; Restart-SnowLuma }
    }
    $log = Get-ChildItem "$sl\logs" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log -and (Select-String -Path $log.FullName -Pattern 'retry exhausted|unsupported|not supported' -Quiet)) {
        Write-Host '10 分钟还没连上。看日志多半是 QQ 自动升级了、SnowLuma 还没跟上新版：打开「大肥鱼工作台」看提醒，或者在工作台点「复制求助信息」，把那句话发我。' -ForegroundColor Red
    } else { Write-Host '10 分钟还没连上。关掉这个窗口重新双击一次；还不行就打开桌面的「大肥鱼工作台」点「复制求助信息」，把那句话发我。' -ForegroundColor Red }
    exit 1
}

function Get-NapCatShell {
    $candidates = @(Get-ChildItem -LiteralPath "$Dir\NapCat" -Directory -Filter 'NapCat.*.Shell' | Where-Object { Test-Path -LiteralPath "$($_.FullName)\NapCatWinBootMain.exe" })
    $startFile = Join-Path $Dir 'start-napcat.cmd'
    if (Test-Path -LiteralPath $startFile) {
        $match = [regex]::Match((Get-Content -LiteralPath $startFile -Raw), '(?im)^\s*cd\s+/d\s+"([^"]+)"')
        if ($match.Success) {
            $selected = @($candidates | Where-Object { $_.FullName.TrimEnd('\').Equals($match.Groups[1].Value.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) })
            if ($selected.Count -eq 1) { return $selected[0] }
        }
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -gt 1) { throw '有多份 NapCat，无法确定启动脚本对应哪份。' }
    return $null
}
$shell = Get-NapCatShell
if (-not $shell) { Write-Host '没找到 NapCat，打开桌面的「大肥鱼工作台」点「复制求助信息」，把那句话发我。' -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force (Join-Path $Dir 'logs') | Out-Null
$qr = Join-Path $Dir 'logs\qq-login.png'
$html = Join-Path $Dir 'logs\qq-login.html'
$script:qrAt = [datetime]::MinValue

function QrTime {
    $latest = Get-ChildItem -LiteralPath "$($shell.FullName)\versions" -Directory | ForEach-Object {
        Get-Item -LiteralPath (Join-Path $_.FullName 'resources\app\napcat\cache\qrcode.png') -ErrorAction SilentlyContinue
    } | Where-Object { $_.Length -gt 0 } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest -and $latest.LastWriteTime -gt $script:qrAt) {
        # 浏览器始终读本次安装的稳定副本；升级到另一版本也不会继续显示旧路径。
        $tmp = $qr + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            Copy-Item -LiteralPath $latest.FullName -Destination $tmp -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $qr -Force -ErrorAction Stop
            $script:qrAt = $latest.LastWriteTime
        } catch { } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $script:qrAt
}
function Write-ScanPage {
    $imageUri = ([uri]$qr).AbsoluteUri
    $imageJson = ConvertTo-Json $imageUri -Compress
    $page = '<!doctype html><html lang="zh"><meta charset="utf-8"><title>QQ 小号扫码登录</title><style>body{font:18px "Microsoft YaHei",sans-serif;text-align:center;padding:3em;background:#f4f1ea}img{width:320px;height:320px}</style><img id="q"><p>用登着小号的手机 QQ 扫码，再在手机上确认登录。</p><script>const url=' + $imageJson + ';const show=()=>document.getElementById("q").src=url+"?"+Date.now();show();setInterval(show,3000);</script></html>'
    [IO.File]::WriteAllText($html, $page, (New-Object Text.UTF8Encoding($false)))
}
function Restart-NapCat {
    if (-not (Test-Path -LiteralPath "$Dir\start-napcat.cmd") -or -not (Test-Path -LiteralPath "$($shell.FullName)\NapCatWinBootMain.exe")) { throw 'NapCat 启动文件不完整，未关闭现有程序。' }
    $probe = Get-QQState
    if ($probe.state -eq 'online') { Boot-State 'online' '小号已经连上大脑。'; return $false }
    if ($probe.state -notin @('offline', 'kicked')) { throw '状态不明或大脑未就绪，未重启 NapCat。' }
    if ($Autostart) {
        if ($probe.needs_scan) {
            QrTime | Out-Null
            Write-ScanPage
            Boot-State 'scan-required' '登录凭据已失效，等待本人扫码，不自动重启。'
            return $false
        }
        if ($script:automaticRestartUsed -or $probe.automatic_retry_wait -gt 0) {
            Boot-State 'cooldown' '自动登录仍在十五分钟冷却中，不重复重启。'
            return $false
        }
        # Persist the actual restart, not merely a scheduled-task trigger. A failed
        # launch also consumes this attempt so failures cannot hammer QQ login.
        Write-AutomaticAttempt
        $script:automaticRestartUsed = $true
    }
    # 路径和 Windows 用户都得对上，不动桌面 QQ 和别人的进程。
    $me = @(Get-UserStartupIdentity)[0]
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($shell.FullName + '\', [StringComparison]::OrdinalIgnoreCase) } |
        Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId -and (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Domain)\$($_.User)" }) -eq $me } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }
    Start-Sleep 3
    Start-Quiet "$Dir\start-napcat.cmd"
    return $true
}

Write-Host ''
Write-Host '==== 大肥鱼重新登录 ====' -ForegroundColor Cyan
if (Online) { Write-Host '她现在是在线的，不用扫码。还是不回话的话，打开桌面的「大肥鱼工作台」点「复制求助信息」，把那句话发我。' -ForegroundColor Green; exit 0 }

Start-Brain
if (Online) { Write-Host '好了，她回来了，可以关掉这个窗口了。' -ForegroundColor Green; exit 0 }

# 每次入口最多一次真实重启；自动入口另有持久化十五分钟冷却。
# 已知登录凭据失效时只等本人扫码，不继续杀进程刷新登录状态。
$readyForScan = $false
$script:automaticRestartUsed = $false
if ($Autostart) { Wait-Ready }
if (Online) { Boot-State 'online' '小号已经连上大脑。'; Write-Host '已经自动登上了。'; exit 0 }
$start = Get-Date
if (-not (Restart-NapCat)) { Write-Host '自动登录已暂停；需要扫码或仍在冷却，未重复重启。'; exit 0 }
Boot-State 'logging-in' '正在尝试一次快速登录。'
Write-Host '正在试一次快速登录……'
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep 2
    $probe = Get-QQState
    if ($probe.state -eq 'online') { Boot-State 'online' '小号已经连上大脑。'; Write-Host '不用扫码，已经自动登上了。'; exit 0 }
    if ((QrTime) -gt $start -and ($probe.needs_scan -or $i -gt 8)) { $readyForScan = $true; break }
}
if (-not $readyForScan) {
    if ($probe.needs_scan) { Boot-State 'scan-required' '登录凭据已失效，等待本人手动扫码，不继续快速登录。' }
    else { Boot-State 'retry-later' '本次快速登录尚未成功，自动重启已停止。请在工作台查看状态。' }
    Write-Host '本次没有可用的新二维码，已停止自动重启。请在工作台查看状态，方便时手动重登。'
    exit 1
}
# 有本轮新二维码时只展示并等待，不再强制重启来刷新二维码。
Write-ScanPage
Start-Process $html
Boot-State 'scan' '自动登录没成功，请用小号手机 QQ 扫打开的二维码。'
Write-Host '请用登着小号的手机 QQ 扫码，再在手机上点「登录」。最多等 10 分钟。'
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    Start-Sleep 3
    if (Online) { Boot-State 'online' '小号已经连上大脑。'; Write-Host '登录成功，可以关掉二维码页面了。'; exit 0 }
    QrTime | Out-Null
}
Boot-State 'scan-timeout' '二维码等了 10 分钟。方便时双击桌面的「大肥鱼掉线-双击扫码」。'
Write-Host '10 分钟还没登上。方便时双击桌面「大肥鱼掉线-双击扫码」，或用工作台复制求助信息。'
exit 1
} catch {
    Boot-State 'failed' $_.Exception.Message
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
