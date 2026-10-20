#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-win-tunnel · Windows 端卸载

.DESCRIPTION
    停止并删除计划任务与运行进程,可选删除生成的文件与日志。
    不会删除你已安装的 dsh 或 SSH 密钥。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = $PSScriptRoot,
    [switch]$PurgeFiles
)

$ErrorActionPreference = 'Continue'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

$TaskDsh = "DshWinTunnel-DshWeb"
$TaskTun = "DshWinTunnel-Tunnel"

Write-Step "删除计划任务"
foreach ($name in @($TaskDsh, $TaskTun)) {
    & schtasks /Delete /TN $name /F 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "$name 已删除" } else { Write-Warn "$name 不存在或删除失败" }
}

Write-Step "停止正在运行的进程"
foreach ($pattern in @('run-tunnel.bat', 'run-dsh.bat')) {
    $procs = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine.Contains($pattern) }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Ok "已结束 $pattern (PID $($p.ProcessId))"
    }
}

# 隧道对应的 ssh 进程
$sshProcs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains('127.0.0.1') -and $_.CommandLine.Contains('-R') }
foreach ($p in $sshProcs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Ok "已结束 ssh 隧道 (PID $($p.ProcessId))"
}

if ($PurgeFiles) {
    Write-Step "清理生成的文件"
    foreach ($f in @('config.json', 'run-dsh.bat', 'run-tunnel.bat')) {
        $path = Join-Path $InstallDir $f
        if (Test-Path $path) { Remove-Item $path -Force; Write-Ok "已删除 $f" }
    }
    $logDir = Join-Path $InstallDir "logs"
    if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force; Write-Ok "已删除 logs/" }
}

Write-Host ""
Write-Ok "卸载完成。SSH 密钥与 dsh 本体未改动。"
