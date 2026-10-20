#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-win-tunnel · 链路健康检查

.DESCRIPTION
    逐段检查 本机 dsh → 隧道进程 → 公网入口 是否都通,
    定位断在哪一环。部署完或连不上时运行。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'

function Write-Title { param([string]$Message) Write-Host ""; Write-Host "── $Message " -ForegroundColor Cyan -NoNewline; Write-Host ("─" * 40) -ForegroundColor DarkGray }
function Write-Pass  { param([string]$Message) Write-Host "  [PASS] $Message" -ForegroundColor Green }
function Write-Fail  { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }
function Write-Info  { param([string]$Message) Write-Host "  [INFO] $Message" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  dsh-win-tunnel 链路检查" -ForegroundColor White
Write-Host ""

$ConfigPath = Join-Path $InstallDir "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Fail "找不到 $ConfigPath,请先运行 setup.ps1"
    exit 1
}
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$failures = 0

# ── 1. 本机 dsh ──
Write-Title "1. 本机 dsh web"
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $tcp.Connect('127.0.0.1', [int]$cfg.localPort)
    Write-Pass "127.0.0.1:$($cfg.localPort) 可连接"
} catch {
    Write-Fail "127.0.0.1:$($cfg.localPort) 连不上 —— dsh web 没在跑"
    Write-Info "启动: $InstallDir\run-dsh.bat"
    $failures++
} finally {
    $tcp.Close()
}

# ── 2. 本机 dsh 进程 ──
$dshProcs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -and $_.CommandLine -match 'dsh' }
if ($dshProcs) {
    Write-Pass "发现 $($dshProcs.Count) 个 dsh node 进程"
} else {
    Write-Fail "没发现 dsh:node 进程"
    $failures++
}

# ── 3. 隧道进程 ──
Write-Title "2. SSH 隧道"
$sshProcs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains('-R') -and $_.CommandLine.Contains([string]$cfg.tunnelPort) }
if ($sshProcs) {
    foreach ($p in $sshProcs) { Write-Pass "隧道进程 PID $($p.ProcessId)" }
} else {
    Write-Fail "没有运行中的 ssh -R 隧道"
    Write-Info "启动: $InstallDir\run-tunnel.bat"
    $failures++
}

# ── 4. 隧道日志尾部 ──
$tunLog = Join-Path $InstallDir "logs\tunnel.log"
if (Test-Path $tunLog) {
    Write-Title "隧道日志(最后 5 行)"
    Get-Content $tunLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

# ── 5. 公网入口 ──
Write-Title "3. 公网入口"
try {
    $resp = Invoke-WebRequest -Uri $cfg.publicUrl -Method Head -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
    Write-Pass "$($cfg.publicUrl) 返回 HTTP $($resp.StatusCode)"
} catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 401) {
        Write-Pass "$($cfg.publicUrl) 返回 401 —— nginx 登录墙正常工作(浏览器里会弹账号密码框)"
    } elseif ($status -eq 502 -or $status -eq 504) {
        Write-Fail "$($cfg.publicUrl) 返回 $status —— nginx 连不上隧道落点,隧道断了"
        Write-Info "检查服务器: ss -tlnp | grep :$($cfg.tunnelPort)"
        $failures++
    } elseif ($status) {
        Write-Warn "$($cfg.publicUrl) 返回 HTTP $status"
    } else {
        Write-Fail "$($cfg.publicUrl) 无法访问"
        Write-Info "确认 DNS 已解析、服务器 443 可达、nginx 已 reload"
        $failures++
    }
}

# ── 结果 ──
Write-Host ""
if ($failures -eq 0) {
    Write-Host "  全部检查通过。" -ForegroundColor Green
} else {
    Write-Host "  有 $failures 项没通过,按上面提示逐项排查。" -ForegroundColor Red
}
Write-Host ""
