param(
    [string]$Dir = 'E:\dafeiyu',
    [ValidateRange(1,600)][int]$AstrBotWait = 150,
    [ValidateRange(1,600)][int]$SnowLumaWait = 90,
    [ValidateRange(1,600)][int]$OllamaWait = 60,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\stack_common.ps1"
$Dir = Get-StackRoot $Dir

function Get-StackPluginHealth([string]$Root) {
    $py = Find-StackPython $Root
    $raw = & $py -X utf8 -B (Join-Path $PSScriptRoot 'stack_health.py') --dir $Root 2>$null
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return [pscustomobject]@{ok=$false;reason='health_probe_failed'} }
}

function Invoke-StackStartup([string]$Root, [int]$BrainWait, [int]$BridgeWait, [int]$ModelWait) {
    Write-StackLog $Root 'start' '================ 一键启动 ================' $false
    $failures = New-Object Collections.Generic.List[string]
    $state = Get-StackState $Root
    if ($state.ollama.api_ready) {
        Write-StackLog $Root 'start' 'Ollama：服务已就绪，复用现有服务。' $false
    } elseif ($state.ollama.port_conflict -or $state.ollama.unknown) {
        Write-StackLog $Root 'start' 'Ollama：端口或进程归属不明，未启动第二份。' $false
        $failures.Add('Ollama')
    } else {
        try {
            if (-not $state.ollama.running) { Start-StackOllama $Root }
            $state = Wait-StackState $Root { param($s) $s.ollama.api_ready } $ModelWait
            if (-not $state.ollama.api_ready) { throw 'Ollama API未在时限内就绪。' }
        } catch { Write-StackLog $Root 'start' 'Ollama：服务未确认就绪，记忆功能可能不可用。' $false; $failures.Add('Ollama') }
    }
    $state = Get-StackState $Root
    if (-not $state.ollama.model_available) {
        Write-StackLog $Root 'start' '记忆模型：本机 API 尚未确认 bge-m3 可用。' $false
        if (-not $failures.Contains('Ollama')) { $failures.Add('Ollama模型') }
    }

    try {
        if ($state.backend.ambiguous -or $state.backend.port_conflict) { throw '后台归属或端口有冲突。' }
        if ($state.backend.state -eq 'off' -and @($state.backend.owned).Count -eq 0) {
            if (-not (Start-StackTask 'Dafeiyu-AstrBot' $Root)) { Start-StackCommand (Join-Path $Root 'start-astrbot.cmd') }
        }
        if (-not ($state.backend.state -eq 'up' -and $state.backend.ws_ready)) {
            Write-StackLog $Root 'start' 'AstrBot：等待本实例后台与 WS 就绪，不重复拉起已有进程。' $false
            $state = Wait-StackState $Root { param($s) $s.backend.state -eq 'up' -and $s.backend.ws_ready } $BrainWait
        }
        if (-not ($state.backend.state -eq 'up' -and $state.backend.ws_ready)) { throw '后台或WS未就绪。' }
    } catch { Write-StackLog $Root 'start' 'AstrBot：未确认就绪；未因超时再开第二份。' $false; $failures.Add('AstrBot') }

    if ($state.protocol -eq 'snowluma') {
        try {
            if (-not $state.qq.running) {
                if ($state.qq.unknown) { throw '已有QQ进程归属不明。' }
                $qqExe = @("$env:ProgramFiles\Tencent\QQNT\QQ.exe", "${env:ProgramFiles(x86)}\Tencent\QQNT\QQ.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if (-not $qqExe) { throw '未找到官方桌面QQ。' }
                Start-Process -FilePath $qqExe -ErrorAction Stop | Out-Null
                Write-StackLog $Root 'start' 'QQ：已打开，请在QQ窗口登录机器人小号。' $false
                $state = Wait-StackState $Root { param($s) $s.qq.running } 10
            }
            if (-not $state.qq.running) { throw 'QQ进程尚未确认。' }
        } catch { Write-StackLog $Root 'start' 'QQ：未确认本会话官方QQ已打开，未另起不明客户端。' $false; $failures.Add('QQ') }
        try {
            $state = Get-StackState $Root
            if ($state.snowluma.port_conflict -or $state.snowluma.unknown) { throw 'SnowLuma归属不明。' }
            if (-not $state.snowluma.running) {
                if (-not $state.qq.running) { throw '请先打开QQ。' }
                if ($failures.Contains('AstrBot')) { throw '请先修复后台或WS。' }
                [void](Start-StackSnowLumaGuarded $Root)
            }
            if (-not $state.snowluma.ready) { $state = Wait-StackState $Root { param($s) $s.snowluma.ready } $BridgeWait }
            if (-not $state.snowluma.ready) { throw 'SnowLuma未就绪。' }
        } catch { Write-StackLog $Root 'start' 'SnowLuma：未确认就绪，请检查密码文件、普通权限及桥日志。' $false; $failures.Add('SnowLuma') }
    } else {
        try {
            if (-not $state.backend.online) {
                if ($failures.Contains('AstrBot')) { throw '请先修复后台或WS。' }
                if (-not (Start-StackTask 'Dafeiyu-Relogin' $Root)) { throw '缺少本安装重登任务。' }
            }
        } catch { Write-StackLog $Root 'start' '当前协议使用现有重登入口；未另开SnowLuma或桌面QQ。' $false; $failures.Add('QQ协议桥') }
    }

    try {
        $state = Get-StackState $Root
        if (-not $state.watch.running) {
            if (-not (Start-StackTask 'Dafeiyu-QQWatch' $Root)) { Start-StackCommand (Join-Path $Root 'tools\qq-watch.cmd') }
            $state = Wait-StackState $Root { param($s) $s.watch.running } 10
        }
        if (-not $state.watch.running) { throw '守护未确认运行。' }
    } catch { Write-StackLog $Root 'start' '掉线守护：未确认运行，未按任意pythonw进程冒充成功。' $false; $failures.Add('掉线守护') }

    $state = Wait-StackState $Root { param($s) $s.backend.online } $BridgeWait
    $health = Get-StackPluginHealth $Root
    if (-not $health.ok) { $failures.Add('后台插件验收') }
    if (-not $state.backend.online) { $failures.Add('QQ连接') }
    Write-StackLog $Root 'start' ('Ollama模型可用：' + [bool]$state.ollama.model_available) $false
    Write-StackLog $Root 'start' ('AstrBot本实例后台/WS：' + ($state.backend.state -eq 'up' -and $state.backend.ws_ready)) $false
    Write-StackLog $Root 'start' ('QQ传输连接：' + [bool]$state.backend.online + '；此项不等于真实消息收发验收。') $false
    Write-StackLog $Root 'start' ('插件加载检查：' + [bool]$health.ok) $false
    if (-not $health.ok) {
        if ($health.reason -eq 'dashboard_auth_failed') { Write-StackLog $Root 'start' '后台插件检查无法认证；请核对 private\backend.txt 中的后台登录信息。此项不等于插件崩溃。' $false }
        else { Write-StackLog $Root 'start' '后台插件尚未通过验收，请在本地后台查看加载状态。' $false }
    }
    foreach($name in @('voice','memory','memes')) { Write-StackLog $Root 'start' ($name + ' 插件启用：' + [bool]$health.features.$name) $false }
    if ($null -eq $state.qq.owner_login) { Write-StackLog $Root 'start' 'QQ账号登录态未单独验证；请在QQ窗口确认机器人小号。' $false }
    if ($failures.Count -gt 0) { Write-StackLog $Root 'start' ('尚未就绪：' + (($failures | Select-Object -Unique) -join '、')) $false; return 1 }
    Write-StackLog $Root 'start' '组件与插件已就绪、QQ桥已连接；没有重复启动语音桥。' $false
    return 0
}

if ($DryRun) {
    $state = Get-StackState $Dir
    $health = if($state.backend.state -eq 'up'){Get-StackPluginHealth $Dir}else{[pscustomobject]@{ok=$false;reason='backend_off'}}
    [pscustomobject]@{dry_run=$true;state=$state;plugins=$health} | ConvertTo-Json -Depth 8
    exit 0
}
$mutex = $null
try {
    $mutex = Enter-StackLock $Dir 0
    $code = Invoke-StackStartup $Dir $AstrBotWait $SnowLumaWait $OllamaWait
} catch { Write-StackLog $Dir 'start' $_.Exception.Message $false; $code = 1 }
finally { if($mutex){Exit-StackLock $mutex} }
exit $code
