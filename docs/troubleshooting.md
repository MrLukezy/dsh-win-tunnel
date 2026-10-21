# 排错手册

按症状查。每一步都给了可直接粘贴的诊断命令。

---

## 1. 选文件夹报 403 / 特权 RPC 失败

**现象**:页面能正常打开、能对话,但一点「选择文件夹」就弹
`transport failure for /api/host.pickDirectory: HTTP 403`;或者设置页加载不出来。

**根因**:这是两个独立的坑,必须分开判断。

### 1.1 nginx 用 `$host` 丢掉了端口

`$host` 变量**不包含端口**。浏览器发出的 `Origin` 是 `https://域名:8443`,
而 dsh 收到的 `Host` 是 `域名` —— 端口一丢就不同源,`isTrustedApiRequest()` 返回 false。

```nginx
# 错误:监听非 443 端口时端口会丢
proxy_set_header Host $host;

# 正确:保留原始 Host 头(含端口)
proxy_set_header Host $http_host;
```

**判断方法**:看 nginx access log 里 `POST /api/host.describe` 的状态码。

| 状态码 | 响应体 | 含义 |
|---|---|---|
| 403 | 9 字节 `forbidden` | 没过 1.1 的 Host 校验 |
| 401 | `unauthorized` | 过了 Host,但还没登录 |
| 200 | JSON | 这一层已通过,若仍报错看 1.2 |

### 1.2 连接被判定为 non-owner peer

`dsh-client-connection` 里 `pickDirectory` 这类方法要求调用者身份是 owner:

```js
if (peer.principal.kind !== "owner")
    return new Response("forbidden", { status: 403 });
```

只有 `browserAuth.isAuthenticated(cookie)` 成立时才返回 owner peer。
也就是说 **必须用 launch token 登录过一次**,让 dsh 种下 `dsh-auth-*` cookie。
未登录时是 non-owner,这类特权方法一律 403。

**解决**:用带 `?token=` 的地址打开一次(见第 6 节)。

### 1.3 PC 端参数是否带上

```powershell
Get-Content C:\dsh-win-tunnel\run-dsh.bat | Select-String "trusted-host"
```

必须能看到 `--trusted-host <域名>:<端口>`。少了它,非 loopback 的 Host 一律被拒。

改完两边都要重启:

```bash
sudo nginx -t && sudo systemctl reload nginx
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

**为什么日志里可能是残串**:dsh 打印的是 `dsh web: http://...?token=xxx` 一整行。
但如果这行经过某些终端、编辑器或日志查看器,会被显示成 `abc…xyz` 的缩写形式,
复制下来是无效的。所以**不要完全依赖日志**。

### 最可靠:从浏览器地址栏拿

1. 停掉 dsh
2. 用**不带** `--no-open` 的命令重新启动:

```powershell
node "$env:APPDATA\npm\node_modules\@deepseek-ai\dsh\lib\bin.js" web `
  --host 127.0.0.1 --port 13080 `
  --public-url https://你的域名:8443 `
  --trusted-host 你的域名:8443
```

3. dsh 会自动打开浏览器。**地址栏里的 `?token=` 后面就是完整值**,地址栏不会缩写
4. 把 token 拼成 `https://你的域名:8443/?token=那一串`,在公网地址上打开一次

之后 cookie 生效,不再需要 token。

### 备选:从日志提取

```powershell
Select-String -Path C:\dsh-win-tunnel\logs\dsh-web.log -Pattern "dsh web:" | Select-Object -Last 1
```

### 几个要点

- token 随 dsh 每次重启变化
- 已种过 cookie 的浏览器不受影响
- 换浏览器或清 cookie 需要重新取
- **token 与访问域名无关** —— 同一个 dsh 进程的 token 可以用在任何 Host 下

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

---

## 11. 不要在 Windows 上依赖 cloud-gateway

**现象**:dsh-cloud-gateway 能登录进它自己的登录页,但进去后 dsh 仍然是 401,
页面一直提示 `dsh web authentication required`。

**根因**:cloud-gateway 换取 dsh 登录态的方式是读 systemd journal:

```js
const authedUrlProvider = () => {
    const out = __execFileSync("journalctl", [ ... ]);
```

**Windows 没有 systemd / journalctl**,这一步直接抛错,拿不到 launch token,
于是它无法把 `dsh-auth-*` cookie 注入到转发请求里。结果就是:登录墙能过,后端永远 401。

**结论**:Windows 端不要指望用 gateway 来免 token。直接用 dsh + launch token 登录。

---

## 12. 为什么不能把第二个 dsh 挂在子路径

**需求**:已经有一个 dsh 挂在 `https://域名/dsh`,想让第二台机器也挂成 `https://域名/dshnuc`。

**结论**:做不到。原因不在 nginx 配置,而在 DSH 前端的资源路径。

DSH 的入口 HTML 里资源全是**根绝对路径**:

```html
<script src="/assets/index-ClqxG24t.js"></script>
<link href="/plugins/@deepseek-ai/...">
```

在同一个 origin(协议 + 域名 + 端口)下,浏览器请求 `/assets/xxx` 时,
nginx 无法区分这个请求是给第一个 dsh 还是第二个的 —— 路径完全一样。

> 已有的 `/dsh` 之所以能工作,是因为它**独占**了这个 origin 的
> `/assets`、`/plugins`、`/api`。它的入口是 `/dsh/`,但资源仍走根路径,
> 所以整个 origin 只容得下它一个。

**可行的做法**:

| 方案 | 地址 | 前提 |
|---|---|---|
| 独立端口 | `https://域名:8443` | 安全组放行该端口 |
| 独立子域名 | `https://dshnuc.域名` | 加一条 DNS A 记录 |

两者本质相同:给第二个实例一个**没人抢的 origin**。

**关于用 `sub_filter` 强行改写资源前缀**:理论上能把 HTML 里的 `/assets/` 改成
`/dshnuc/assets/`,但 DSH 前端运行时还有大量动态请求,这部分改写不完整,
实测会在登录后崩溃。不建议走这条路。
