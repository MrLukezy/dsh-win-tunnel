#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-win-tunnel · Windows 端一键配置

.DESCRIPTION
    把本机 Windows 上的 DeepSeek Harness 通过 SSH 反向隧道送到公网服务器,
    并注册开机自启的计划任务。全程只做减法:本机 dsh 只监听 127.0.0.1。

.PARAMETER ServerHost
    服务器域名或 IP(与服务器端 config.env 的 DOMAIN 一致)

.PARAMETER ServerUser
    服务器上的登录用户名(用于 SSH)

.PARAMETER SshPort
    服务器 SSH 端口,默认 22

.PARAMETER TunnelPort
    隧道落点端口,必须与服务器端 config.env 的 TUNNEL_PORT 一致

.PARAMETER LocalPort
    本机 dsh web 监听端口,默认 13080

.PARAMETER PublicUrl
    对外访问地址,默认 https://<ServerHost>

.PARAMETER NoStart
    只生成配置和计划任务,不立即启动

.PARAMETER SkipKeySetup
    跳过 SSH 公钥部署(你已经手动配好免密时用)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup.ps1 `
        -ServerHost pc.example.com -ServerUser ubuntu `
        -TunnelPort 13081 -PublicUrl https://pc.example.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerHost,
    [Parameter(Mandatory = $true)][string]$ServerUser,
    [int]$SshPort = 22,
    [int]$TunnelPort = 13081,
    [int]$LocalPort = 13080,
    [string]$PublicUrl = "",
    [switch]$NoStart,
    [switch]$SkipKeySetup,
    [string]$InstallDir = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ── 安装目录兜底 ──
# 不能直接在 param 默认值里用 $PSScriptRoot:PowerShell 5.1 在
# `powershell -File script.ps1` 下求值参数默认值时,它可能还是空值。
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $InstallDir = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $InstallDir = (Get-Location).Path
    }
}
Write-Host "  安装目录: $InstallDir" -ForegroundColor DarkGray

# ─────────────────────────── 输出 ───────────────────────────
function Write-Banner {
    Write-Host ""
    Write-Host "  ┌────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │   dsh-win-tunnel · Windows 端配置          │" -ForegroundColor Green
    Write-Host "  └────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""
}
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  [XX] $Message" -ForegroundColor Red }

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ─────────────────────────── 前置检查 ───────────────────────────
Write-Banner

if ([string]::IsNullOrWhiteSpace($PublicUrl)) {
    $PublicUrl = "https://$ServerHost"
}
$PublicUrl = $PublicUrl.TrimEnd('/')

$uri = $null
if (-not [System.Uri]::TryCreate($PublicUrl, [System.UriKind]::Absolute, [ref]$uri)) {
    Write-Fail "PublicUrl 不是合法 URL: $PublicUrl"
    exit 1
}
$TrustedHost = $uri.Authority

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$LogDir = Join-Path $InstallDir "logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Write-Step "检查运行环境"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Fail "未找到 Node.js。请先安装 Node.js 22 LTS:"
    Write-Host "         winget install OpenJS.NodeJS.LTS" -ForegroundColor Yellow
    Write-Host "         (装完请重开一个 PowerShell 窗口再运行本脚本)"
    exit 1
}
$nodeVersion = (& node --version).Trim()
$majorText = ($nodeVersion -replace '^v', '') -split '\.' | Select-Object -First 1
if ([int]$majorText -lt 20) {
    Write-Warn "Node.js 版本 $nodeVersion 偏低,dsh 建议 22 LTS 及以上"
} else {
    Write-Ok "Node.js $nodeVersion"
}

if (-not (Test-CommandExists 'dsh')) {
    Write-Warn "未找到 dsh,准备全局安装 @deepseek-ai/dsh"
    & npm install -g "@deepseek-ai/dsh"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "dsh 安装失败,请检查 npm 网络后重试"
        exit 1
    }
    Write-Ok "dsh 安装完成"
} else {
    Write-Ok "dsh $(& dsh --version 2>$null | Select-Object -First 1)"
}

# ── 能力检测:老版本 dsh 没有 --trusted-host / --public-url ──
# 这两个参数是浏览器信任校验与公网地址打印的关键,缺了会导致登录后白屏。
$webHelp = (& dsh web --help 2>&1 | Out-String)
if ($webHelp -notmatch 'trusted-host') {
    Write-Fail "当前 dsh 版本过旧,不支持 --trusted-host / --public-url"
    Write-Host "         这两个参数缺失会导致登录后接口全 401(白屏)。" -ForegroundColor Yellow
    Write-Host "         请先升级:" -ForegroundColor Yellow
    Write-Host "           npm i -g @deepseek-ai/dsh@latest" -ForegroundColor Green
    exit 1
}
$HasPublicUrl = ($webHelp -match 'public-url')
if (-not $HasPublicUrl) {
    Write-Warn "当前 dsh 不支持 --public-url,将省略该参数;首次登录地址需从日志自行拼接"
}

if (-not (Test-CommandExists 'ssh')) {
    Write-Fail "未找到 ssh 客户端。请到「设置 → 应用 → 可选功能」添加 OpenSSH 客户端"
    exit 1
}
Write-Ok "OpenSSH 客户端就绪"

# ─────────────────────────── SSH 密钥 ───────────────────────────
$SshDir = Join-Path $env:USERPROFILE ".ssh"
$KeyPath = Join-Path $SshDir "id_ed25519"
if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
}

if (Test-Path $KeyPath) {
    Write-Ok "复用已有 SSH 密钥 $KeyPath"
} else {
    Write-Step "生成 SSH 密钥(用于免密隧道)"
    & ssh-keygen -t ed25519 -N '""' -f $KeyPath -C "dsh-win-tunnel" | Out-Null
    if (-not (Test-Path $KeyPath)) {
        Write-Fail "密钥生成失败"
        exit 1
    }
    Write-Ok "已生成 $KeyPath"
}

# ─────────────────────────── 部署公钥 ───────────────────────────
$sshTarget = "$ServerUser@$ServerHost"

if (-not $SkipKeySetup) {
    Write-Step "部署公钥到服务器(需要输入一次服务器密码)"

    $pubKey = (Get-Content "$KeyPath.pub" -Raw).Trim()
    $remoteCmd = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
                 "grep -qxF '$pubKey' ~/.ssh/authorized_keys || echo '$pubKey' >> ~/.ssh/authorized_keys"

    & ssh -p $SshPort -o StrictHostKeyChecking=accept-new $sshTarget $remoteCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "公钥部署失败。请确认:"
        Write-Host "         - 服务器地址/用户名/端口正确"
        Write-Host "         - 服务器开放了 SSH"
        Write-Host "         - 你输入的是服务器登录密码"
        Write-Host ""
        Write-Host "  也可以手动复制这一行到服务器的 ~/.ssh/authorized_keys:" -ForegroundColor Yellow
        Write-Host "  $pubKey" -ForegroundColor DarkGray
        exit 1
    }
    Write-Ok "公钥已部署"
}

Write-Step "验证免密登录"
& ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new `
       -p $SshPort $sshTarget "echo dsh-tunnel-ok" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "免密登录验证失败。请手动测试:"
    Write-Host "         ssh -p $SshPort $sshTarget `"echo ok`"" -ForegroundColor Yellow
    exit 1
}
Write-Ok "免密登录正常"

# ─────────────────────────── 配置持久化 ───────────────────────────
Write-Step "写入配置"

$Config = [ordered]@{
    serverHost = $ServerHost
    serverUser = $ServerUser
    sshPort    = $SshPort
    tunnelPort = $TunnelPort
    localPort  = $LocalPort
    publicUrl  = $PublicUrl
    trustedHost = $TrustedHost
    sshKeyPath = $KeyPath
    installDir = $InstallDir
}
$ConfigPath = Join-Path $InstallDir "config.json"
# 写无 BOM 的 UTF-8,避免某些工具把 BOM 当成 JSON 内容
$jsonText = $Config | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($ConfigPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "配置已写入 $ConfigPath"

# ─────────────────────────── 生成运行脚本 ───────────────────────────
Write-Step "生成运行脚本"

$DshBat   = Join-Path $InstallDir "run-dsh.bat"
$TunnelBat = Join-Path $InstallDir "run-tunnel.bat"
$DshLog   = Join-Path $LogDir "dsh-web.log"
$TunLog   = Join-Path $LogDir "tunnel.log"

# 老版本 dsh 不认 --public-url,这种情况就不传,避免启动即报错
$PublicUrlArg = if ($HasPublicUrl) { "--public-url $PublicUrl" } else { "" }

$dshBatContent = @"
@echo off
chcp 65001 >nul
title DSH Web ($LocalPort)
cd /d "%~dp0"
echo [%date% %time%] starting dsh web >> "$DshLog"
dsh web --host 127.0.0.1 --port $LocalPort --no-open $PublicUrlArg --trusted-host $TrustedHost >> "$DshLog" 2>&1
echo [%date% %time%] dsh web exited with code %ERRORLEVEL% >> "$DshLog"
"@
Set-Content -Path $DshBat -Value $dshBatContent -Encoding ASCII

$tunnelBatContent = @"
@echo off
chcp 65001 >nul
title DSH Tunnel -> $ServerHost
cd /d "%~dp0"
:loop
echo [%date% %time%] connecting to $sshTarget ... >> "$TunLog"
ssh -N -p $SshPort -i "$KeyPath" ^
    -o ServerAliveInterval=30 ^
    -o ServerAliveCountMax=3 ^
    -o ExitOnForwardFailure=yes ^
    -o StrictHostKeyChecking=accept-new ^
    -o TCPKeepAlive=yes ^
    -R 127.0.0.1:${TunnelPort}:127.0.0.1:${LocalPort} ^
    $sshTarget >> "$TunLog" 2>&1
echo [%date% %time%] tunnel dropped (code %ERRORLEVEL%), retry in 5s >> "$TunLog"
timeout /t 5 /nobreak >nul
goto loop
"@
Set-Content -Path $TunnelBat -Value $tunnelBatContent -Encoding ASCII

Write-Ok "run-dsh.bat / run-tunnel.bat 已生成"

# ─────────────────────────── 计划任务 ───────────────────────────
Write-Step "注册开机自启计划任务"

$TaskDsh = "DshWinTunnel-DshWeb"
$TaskTun = "DshWinTunnel-Tunnel"

foreach ($pair in @(@($TaskDsh, $DshBat), @($TaskTun, $TunnelBat))) {
    $name = $pair[0]
    $path = $pair[1]
    & schtasks /Delete /TN $name /F 2>$null | Out-Null
    & schtasks /Create /TN $name /TR "`"$path`"" /SC ONLOGON /DELAY 0000:20 /F 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "计划任务 $name 已注册(登录后 20 秒启动)"
    } else {
        Write-Warn "计划任务 $name 注册失败(可能需要以管理员身份运行)。可手动双击 $path 启动"
    }
}

# ─────────────────────────── 立即启动并抓取 token ───────────────────────────
if ($NoStart) {
    Write-Step "已按 -NoStart 跳过启动"
} else {
    Write-Step "启动服务并抓取首次登录 token"

    if (Test-Path $DshLog) { Remove-Item $DshLog -Force }
    Start-Process -FilePath $DshBat -WindowStyle Minimized | Out-Null

    $token = $null
    $deadline = (Get-Date).AddSeconds(300)
    Write-Host "     等待 dsh 就绪(首次启动会创建 profile,可能要几分钟)..." -ForegroundColor DarkGray

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path $DshLog) {
            $match = Select-String -Path $DshLog -Pattern 'token=([A-Za-z0-9_\-]+)' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($match) {
                $token = $match.Matches[0].Groups[1].Value
                break
            }
        }
    }

    Start-Process -FilePath $TunnelBat -WindowStyle Minimized | Out-Null
    Start-Sleep -Seconds 4

    Write-Host ""
    if ($token) {
        $loginUrl = "$PublicUrl/?token=$token"
        Write-Ok "首次登录地址(只此一次,打开后会种下 cookie)"
        Write-Host ""
        Write-Host "    $loginUrl" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Warn "5 分钟内没在日志里抓到 token。请打开日志查看:"
        Write-Host "        $DshLog" -ForegroundColor Yellow
        Write-Host "        找到形如 token=xxx 的地址,拼成 $PublicUrl/?token=xxx"
    }
}

# ─────────────────────────── 摘要 ───────────────────────────
Write-Host ""
Write-Host "  ┌────────────────────────────────────────────┐" -ForegroundColor Green
Write-Host "  │   Windows 端配置完成                       │" -ForegroundColor Green
Write-Host "  └────────────────────────────────────────────┘" -ForegroundColor Green
Write-Host ""
Write-Host "  对外地址   : $PublicUrl"
Write-Host "  本机 dsh   : http://127.0.0.1:$LocalPort (仅本机)"
Write-Host "  隧道       : 127.0.0.1:$TunnelPort -> 127.0.0.1:$LocalPort"
Write-Host "  日志       : $LogDir"
Write-Host ""
Write-Host "  首次访问必须用带 token 的完整 URL,之后正常访问即可。" -ForegroundColor Yellow
Write-Host "  服务器端 basic auth 账号密码在安装服务器时已打印。" -ForegroundColor Yellow
Write-Host ""
