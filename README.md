# dsh-win-tunnel

把家里 Windows 电脑上的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 通过 SSH 反向隧道送到公网服务器,用任意地点的浏览器访问,**同时让 agent 直接操作那台 Windows 的本地文件与软件**。

两边都只主动连出,家里不需要公网 IP,路由器不用做端口映射。

```
你的浏览器 ──HTTPS──> 服务器 nginx (443)
                          │  basic auth 登录墙
                          ▼
                     127.0.0.1:13081
                          ▲  SSH -R 反向隧道(PC 主动连出)
                          │
Windows PC ──> 127.0.0.1:13080  dsh web
                    │
                    └──> 你的本地文件 / 软件
```

## 为什么不是「托盘式」一键方案

DeepSeek Harness 是 **Host 监听 / Peer 连入** 的模型,没有让一个节点主动连回另一个节点的能力。所以「PC 连回服务器」这一层必须由隧道承担。本项目只是把这层隧道 + 认证反代 + 开机自启打包好,不改动 dsh 本身。

## 前置条件

| 位置 | 要求 |
|---|---|
| 服务器 | Linux、公网 IP、`nginx`、`certbot`、`gettext-base`、SSH `AllowTcpForwarding yes` |
| 域名 | 一条 A 记录指向服务器(没有域名见下方「无域名部署」) |
| Windows | Win10/11、Node.js 22 LTS、OpenSSH 客户端(dsh 会以 `npm i -g` 安装) |

## 部署

### 第一步:服务器

```bash
git clone https://github.com/MrLukezy/dsh-win-tunnel.git
cd dsh-win-tunnel/server

cp config.example.env config.env
nano config.env          # 填 DOMAIN / EMAIL,确认 TUNNEL_PORT 不与现有服务冲突

sudo bash install.sh
```

脚本会依次完成:签发 Let's Encrypt 证书 → 写 nginx 站点 → 生成 basic auth 凭据 → 重载 nginx。

结束时它会打印**登录墙账号密码**(只显示一次)以及 Windows 侧要用的命令,记下来。

> `TUNNEL_PORT` 默认 `13081`。如果服务器上自己已经跑了一个 dsh(`13080`),两者不要撞。检查占用:`ss -tlnp | grep 13081`

调试阶段怕消耗 Let's Encrypt 配额,可先加 `--staging` 跑通流程,再正式签一次。

### 第二步:Windows

把 `windows/` 目录整个复制到 PC 上(比如 `C:\dsh-win-tunnel`),然后在该目录打开 PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1 `
  -ServerHost pc.example.com `
  -ServerUser ubuntu `
  -TunnelPort 13081 `
  -PublicUrl https://pc.example.com
```

脚本会:**检查并安装 dsh** → 生成 SSH 密钥 → 把公钥推到服务器(此处输入一次服务器密码)→ 验证免密 → 写配置 → 注册两个开机自启计划任务 → 启动服务并抓取首次登录 token。

成功时末尾会打印一条这样的地址:

```
https://pc.example.com/?token=aBcD1234...
```

### 第三步:首次登录

1. 浏览器打开那条带 `token=` 的地址
2. 先弹 **basic auth** 框 → 输入服务器端打印的账号密码
3. 页面加载后 cookie 已种下,以后直接访问 `https://pc.example.com` 即可

**token 只用于首次建立浏览器会话**。如果弄丢了,到 PC 上看 `logs\dsh-web.log` 里的 `token=` 那一行,重新拼一次即可。

## 日常运维

| 事项 | 做法 |
|---|---|
| 看 dsh 日志 | `C:\dsh-win-tunnel\logs\dsh-web.log` |
| 看隧道日志 | `C:\dsh-win-tunnel\logs\tunnel.log` |
| 健康检查 | `powershell -File check.ps1` |
| 手动重启 | 双击 `run-dsh.bat` / `run-tunnel.bat` |
| 改端口或域名 | 重跑 `setup.ps1`,然后重跑服务器 `install.sh` |
| 卸载 | PC 上 `uninstall.ps1 -PurgeFiles`;服务器上 `sudo bash uninstall.sh` |

隧道是 `:loop` 死循环,断了 5 秒自动重连;`ServerAliveInterval=30` 用来及时发现半开连接。PC 重启后计划任务会在登录 20 秒后自动拉起两条链路。

## 安全说明

这套方案把一台能执行 PowerShell、能读写你全部文件的 agent 暴露到了公网,**请务必确认下列几点**:

- **两层门**:nginx basic auth + dsh 自身的 token cookie。不要把 `auth_basic` 删掉。
- **本机只绑 `127.0.0.1`**。`setup.ps1` 生成的命令固定 `--host 127.0.0.1`,不要改成 `0.0.0.0`——那会把家里的局域网也拖进来。
- **隧道只落 127.0.0.1**。服务器 `GatewayPorts no` 是默认值,反向监听不会对外。
- **强烈建议再加一层**:只放行你自己的出口 IP,或挂 Cloudflare Access / Tailscale。basic auth 只是最低门槛。
- 密码与 token 不要提交进 Git。

## 与已有站点共存(推荐:独立端口 + 复用证书)

DSH 前端使用根绝对路径(`/assets`、`/api`、`/plugins`),所以**一个 origin(协议 + 域名 + 端口)只能承载一个 DSH 实例**。如果你的 443 已经被别的站点占用,**不要**试图把 DSH 挂到子路径下——它的资源请求会和主站的根路径资源冲突,表现为页面加载到别人的 JS、接口打到别人的后端。

正确做法是给它一个**独立端口**,并复用已有证书:

```bash
# config.env
DOMAIN=www.example.com                                    # 已解析、已有证书
LISTEN_PORT=8443                                          # 独立端口
CERT_DIR_OVERRIDE=/etc/letsencrypt/live/www.example.com   # 复用,完全不调用 certbot
```

访问地址即 `https://www.example.com:8443`,证书与域名匹配,浏览器不会告警。记得在云安全组放行该端口。

> 这套配置不会产生 `conflicting server name` 警告,也不会改动 443 上的任何既有站点。

## 无域名部署(IP 直连 + 自签证书)

`config.env` 里的 `DOMAIN` 直接填服务器公网 IP,`install.sh` 会自动切换到 IP 模式:

- 不再调用 certbot,改为在 `/etc/ssl/dsh-tunnel/` 生成 **10 年有效**的自签证书
- 443 站点标记为 `default_server`——浏览器访问 IP 时**不发送 SNI**,只能靠默认站点接住
- 自动省略 80 端口站点,避免与已占用该 IP 的其它站点产生 `conflicting server name`

代价是浏览器首次访问会提示「连接不是私密连接」,点「继续前往」即可。手机上同样可以继续访问。

```bash
# config.env
DOMAIN=203.0.113.10
```

之后如果想换成正式证书,只需要把 `DOMAIN` 改成已解析的域名,重新执行一次 `install.sh`——nginx 站点会被重写,但隧道与 Windows 端配置无需改动。

另一种彻底免端口、免证书的方案是 Cloudflare Tunnel(`cloudflared tunnel`),但需要域名托管在 Cloudflare。

## 已知限制

- **Windows 上没有 bash**。dsh 的 `bash` 工具是硬编码的 `bash -c`,没装 WSL 时只有 PowerShell 那套工具可用。需要 UNIX 工具链请装 WSL。
- **锁屏不影响**,但**休眠会断**。常开机请在电源设置里关掉睡眠。
- **首启动慢**。`dsh web` 第一次会创建 profile 并装插件,几分钟属正常,`setup.ps1` 最多等 300 秒。
- **同一时间只建议一个浏览器会话**。多个标签同时开会让 dsh 的 peer 管理变复杂。
- **Windows 上不要用 cloud-gateway 免 token**。它靠 `journalctl` 读 launch token,Windows 没有 systemd,这一步必然失败,表现为"能登录网关、进去还是 401"。见排错第 11 节。
- **一个 origin 只能挂一个 dsh**。DSH 的静态资源走根绝对路径,第二个实例无法挂在同一域名的子路径下,必须给它独立端口或独立子域名。见排错第 12 节。
- **launch token 可能被日志工具显示成残串**。最可靠的做法是让 dsh 自动打开浏览器,从地址栏复制。见排错第 6 节。

## 排错

见 [docs/troubleshooting.md](docs/troubleshooting.md)。最常见的几个症状:

| 症状 | 原因 |
|---|---|
| 选文件夹报 403 / 特权 RPC 失败 | nginx 用了 `$host` 丢了端口,或还没 token 登录 |
| 登录后白屏、接口全 401 | nginx 改写了 `Host` 头(或丢了端口) |
| 502 / 504 | 隧道断了,或 `TUNNEL_PORT` 两边不一致 |
| 对话卡住不输出 | 反代开了缓冲,需 `proxy_buffering off` |
| 网关登录成功但仍是 401 | 在 Windows 上用了 cloud-gateway,换成 token 登录 |

## License

MIT
