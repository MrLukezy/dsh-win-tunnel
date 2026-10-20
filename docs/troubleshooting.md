# 排错手册

按症状查。每一步都给了可直接粘贴的诊断命令。

---

## 1. 登录后白屏 / 所有接口 401

**现象**:basic auth 输对了,页面能加载出骨架,但会话列表空、发消息报错,控制台里 `/api/*` 全是 401。

**根因**:dsh 的 `browser-trust fence` 用 `Host` 与 `Origin` 做同源校验。反代一旦改写 `Host`,
校验直接失败。源码位置:`dsh-client-connection` 的 `isTrustedApiRequest()`。

**检查**:

```bash
grep -n "proxy_set_header Host" /etc/nginx/sites-available/dsh-win-tunnel
```

必须是 `proxy_set_header Host $host;`。如果写成了 `127.0.0.1:13081`,改回来。

**同时确认 PC 端参数带上了**:

```powershell
Get-Content C:\dsh-win-tunnel\run-dsh.bat | Select-String "trusted-host"
```

必须能看到 `--trusted-host <你的域名>`。少了它,非 loopback 的 Host 一律被拒。

改完两边都要重启:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

```powershell
# PC 上重跑 setup.ps1,或手动重启 run-dsh.bat
```

---

## 2. 502 Bad Gateway / 504 Gateway Timeout

**含义**:nginx 活着,但连不上隧道落点 `127.0.0.1:<TUNNEL_PORT>`。也就是 PC 那边没把隧道架起来。

**服务器上确认隧道在不在**:

```bash
ss -tlnp | grep 13081
```

没有输出 = 隧道没连上。

**再确认 PC 端隧道进程**:

```powershell
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Select-Object ProcessId, CommandLine
```

**逐项排查**:

1. PC 能不能到服务器:`ssh -p 22 user@host "echo ok"`
2. 两边端口是否一致:`config.env` 的 `TUNNEL_PORT` 对比 `config.json` 的 `tunnelPort`
3. 服务器 sshd 是否允许转发:`sudo sshd -T | grep -i allowtcpforwarding` 应为 `yes`
4. 隧道日志:`C:\dsh-win-tunnel\logs\tunnel.log`

常见报错对照:

| 日志内容 | 含义 |
|---|---|
| `Permission denied (publickey)` | 公钥没部署上,重跑 `setup.ps1` |
| `remote port forwarding failed for listen port` | 服务器上该端口已被别的进程占用 |
| `Connection refused` | 服务器 SSH 端口不对 |
| `Operation timed out` | 网络/防火墙阻断,或域名解析错 |

---

## 3. 对话卡住、回复整段突然蹦出来

**根因**:dsh 用 SSE 推送流式输出。反代默认开启缓冲,把流攒成一整块才发。

**确认配置里有**:

```nginx
proxy_buffering off;
proxy_request_buffering off;
proxy_cache off;
```

**另外检查中间层**:如果你在 nginx 前面还有 CDN / Cloudflare 代理,它们也可能缓冲 SSE。
Cloudflare 需要在规则里对该域名关闭 "Buffering"。

---

## 4. 证书签发失败

certbot 的典型报错是 `Timeout during connect` 或 `DNS problem`。

```bash
# 1. 域名解析对不对
dig +short pc.example.com
#    应该返回你的服务器公网 IP

# 2. 80 端口通不通(Let's Encrypt 从公网访问)
curl -I http://pc.example.com/.well-known/acme-challenge/test

# 3. 云厂商安全组是否放行 80/443
```

**先用测试环境验证流程**,避免反复失败消耗正式配额:

```bash
sudo bash install.sh --staging
```

测试证书签发成功后,再正式跑一次 `sudo bash install.sh`。

如果 80 端口被别的站点占着且不方便让出,certbot 也支持 DNS-01 验证:

```bash
sudo certbot certonly --manual --preferred-challenges dns -d pc.example.com
```

然后把证书路径喂给 `install.sh --skip-cert`(需要先确认 `config.env` 的 `DOMAIN` 一致)。

---

## 5. PC 重启后连不上

计划任务默认在**用户登录后 20 秒**触发。检查:

```powershell
schtasks /Query /TN DshWinTunnel-DshWeb /V /FO LIST
schtasks /Query /TN DshWinTunnel-Tunnel /V /FO LIST
```

**状态列显示 `Ready` 但没运行** = 触发器没到(比如没登录)。

**想开机即跑不登录**:
需要把任务改成 "Run whether user is logged on or not",这会要求保存账户密码。用管理员 PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute "C:\dsh-win-tunnel\run-tunnel.bat"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "DshWinTunnel-Tunnel" -Action $action -Trigger $trigger -Settings $settings -User "$env:USERNAME" -RunLevel Highest
```

---

## 6. 找不到首次登录 token

```powershell
Select-String -Path C:\dsh-win-tunnel\logs\dsh-web.log -Pattern "token=" | Select-Object -Last 3
```

拿到后拼成 `https://你的域名/?token=那串字符`,浏览器打开一次即可。

**注意 token 会随 dsh 重启而变**。已种过 cookie 的浏览器不受影响;换浏览器/清 cookie 时需要重新取。

---

## 7. Windows 上 bash 工具报错

**现象**:agent 调用 shell 命令时报 `spawn bash ENOENT` 或类似。

**根因**:dsh 的 bash 工具是硬编码的 `bash -c`,Windows 没有 bash。

**选项**:

- 装 WSL:`wsl --install`,然后把命令写成 `wsl -e bash -lc "..."`,或让 agent 直接用 PowerShell 工具
- 接受现实,只用 `pwsh` 那套工具

---

## 8. 端口冲突

```bash
# 服务器
sudo ss -tlnp | grep -E ":13080|:13081"

# PC
Get-NetTCPConnection -LocalPort 13080 -ErrorAction SilentlyContinue
```

`TUNNEL_PORT` 只要求**服务器上**空闲,`LOCAL_PORT` 只要求 **PC 上**空闲,两者互不干扰,可以相同。

---

## 9. 一键体检

```powershell
powershell -ExecutionPolicy Bypass -File C:\dsh-win-tunnel\check.ps1
```

会依次验证:本机 dsh 端口 → dsh 进程 → 隧道进程 → 公网入口状态码,并直接告诉你断在哪一环。

服务器侧配套检查:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager -l | head -20
sudo ss -tlnp | grep 13081
sudo journalctl -u nginx -n 30 --no-pager
```

---

## 10. 想看到底哪个请求挂了

nginx 访问日志是排查反代问题最直接的证据:

```bash
sudo tail -f /var/log/nginx/access.log | grep dsh-win-tunnel
```

正常请求应该看到 `200` / `401`(未带 basic auth 时)/ `101`(WebSocket 升级)。
出现 `499` 多半是 PC 端把连接掐了,`502` 是隧道断了。
