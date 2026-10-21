#!/usr/bin/env bash
# ============================================================
#  dsh-win-tunnel · 服务器端安装脚本
#  作用:在公网服务器上开一个"带登录墙 + HTTPS"的入口,
#        反向代理到 PC 通过 SSH 隧道送来的 DeepSeek Harness。
#
#  用法:
#      cp config.example.env config.env && nano config.env
#      sudo bash install.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
TEMPLATE_FILE="${SCRIPT_DIR}/nginx-dsh-pc.conf.template"

SITE_NAME="dsh-win-tunnel"
NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}"
AUTH_FILE="/etc/nginx/.htpasswd-${SITE_NAME}"
WEBROOT="/var/www/certbot"
CERT_BASE="/etc/letsencrypt/live"
STAGING=0

# ---------- 输出helper ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''
fi
info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()   { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: sudo bash install.sh [选项]

选项:
  -c, --config <文件>   指定配置文件(默认同目录 config.env)
  --staging             使用 Let's Encrypt 测试环境(不消耗正式配额,便于调试)
  --skip-cert           跳过证书签发,直接复用已有证书
  -h, --help            显示本帮助
EOF
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)   CONFIG_FILE="${2:?缺少配置文件路径}"; shift 2 ;;
    --staging)     STAGING=1; shift ;;
    --skip-cert)   SKIP_CERT=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "未知参数: $1(用 --help 查看用法)" ;;
  esac
done
SKIP_CERT="${SKIP_CERT:-0}"

# ---------- 前置检查 ----------
[[ "${EUID}" -eq 0 ]] || die "请用 root 执行: sudo bash install.sh"

info "检查依赖"
command -v nginx    >/dev/null 2>&1 || die "未找到 nginx,请先安装: apt install -y nginx"
command -v openssl  >/dev/null 2>&1 || die "未找到 openssl,请先安装: apt install -y openssl"
command -v envsubst >/dev/null 2>&1 || die "未找到 envsubst,请先安装: apt install -y gettext-base"
command -v certbot  >/dev/null 2>&1 || die "未找到 certbot,请先安装: apt install -y certbot"
ok "nginx / openssl / envsubst / certbot 就绪"

[[ -f "${CONFIG_FILE}" ]] || die "配置文件不存在: ${CONFIG_FILE}
请先执行: cp config.example.env config.env && nano config.env"
[[ -f "${TEMPLATE_FILE}" ]] || die "缺少 nginx 模板: ${TEMPLATE_FILE}"

# ---------- 载入配置 ----------
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${DOMAIN:?config.env 里必须设置 DOMAIN}"
: "${EMAIL:?config.env 里必须设置 EMAIL}"
: "${TUNNEL_PORT:?config.env 里必须设置 TUNNEL_PORT}"
AUTH_USER="${AUTH_USER:-dsh}"
AUTH_PASS="${AUTH_PASS:-}"
CLIENT_MAX_BODY="${CLIENT_MAX_BODY:-50m}"
FORCE_HTTPS="${FORCE_HTTPS:-1}"
LISTEN_PORT="${LISTEN_PORT:-443}"
CERT_DIR_OVERRIDE="${CERT_DIR_OVERRIDE:-}"

# 允许两种模式:合法域名(Let's Encrypt)或 IPv4 直连(自签证书)
IS_IP=0
if [[ "${DOMAIN}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  IS_IP=1
else
  [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "DOMAIN 格式不对: ${DOMAIN}"
fi
[[ "${TUNNEL_PORT}" =~ ^[0-9]+$ ]] && (( TUNNEL_PORT >= 1024 && TUNNEL_PORT <= 65535 )) \
  || die "TUNNEL_PORT 必须是 1024-65535 之间的整数"
[[ "${LISTEN_PORT}" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) \
  || die "LISTEN_PORT 必须是 1-65535 之间的整数"

# 是否需要走 certbot(只有"域名 + 没指定复用证书 + 没跳过"时才需要)
NEED_ACME=0
if [[ "${IS_IP}" -eq 0 && -z "${CERT_DIR_OVERRIDE}" && "${SKIP_CERT}" -eq 0 ]]; then
  NEED_ACME=1
fi

info "目标域名  ${C_BOLD}${DOMAIN}${C_RESET}"
info "监听端口  ${C_BOLD}${LISTEN_PORT}${C_RESET}"
info "隧道端口  ${C_BOLD}127.0.0.1:${TUNNEL_PORT}${C_RESET}"
[[ -n "${CERT_DIR_OVERRIDE}" ]] && info "复用证书  ${C_BOLD}${CERT_DIR_OVERRIDE}${C_RESET}"

# ---------- 隧道端口占用检查 ----------
if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${TUNNEL_PORT}$"; then
  warn "端口 ${TUNNEL_PORT} 当前已被占用。"
  warn "如果是上一次的隧道残留可以忽略;若非隧道进程请改 config.env 里的 TUNNEL_PORT。"
fi

# ---------- 生成登录墙密码 ----------
PASS_GENERATED=0
if [[ -z "${AUTH_PASS}" ]]; then
  if [[ -f "${AUTH_FILE}" ]]; then
    AUTH_PASS="__KEEP_EXISTING__"
    warn "config.env 未指定 AUTH_PASS,沿用已有登录墙密码"
  else
    AUTH_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
    PASS_GENERATED=1
  fi
fi

if [[ "${AUTH_PASS}" != "__KEEP_EXISTING__" ]]; then
  local_hash="$(openssl passwd -apr1 "${AUTH_PASS}")"
  install -m 0644 /dev/null "${AUTH_FILE}"
  printf '%s:%s\n' "${AUTH_USER}" "${local_hash}" > "${AUTH_FILE}"
  chmod 0644 "${AUTH_FILE}"
  ok "已写入登录墙凭据 ${AUTH_FILE}"
fi

# ---------- 证书 ----------
LISTEN_OPTS=""

if [[ -n "${CERT_DIR_OVERRIDE}" ]]; then
  # ── 复用现有证书:适合"独立端口 + 已有域名证书"的复用场景 ──
  [[ -f "${CERT_DIR_OVERRIDE}/fullchain.pem" && -f "${CERT_DIR_OVERRIDE}/privkey.pem" ]] \
    || die "CERT_DIR_OVERRIDE 指向的目录缺少 fullchain.pem / privkey.pem: ${CERT_DIR_OVERRIDE}"
  CERT_DIR="${CERT_DIR_OVERRIDE}"
  ok "复用已有证书 ${CERT_DIR}"
elif [[ "${IS_IP}" -eq 1 ]]; then
  # ── IP 直连:Let's Encrypt 不给 IP 签证书,只能用自签 ──
  # 浏览器会提示"连接不是私密连接",确认继续即可。自己用够用。
  CERT_DIR="/etc/ssl/dsh-tunnel"
  mkdir -p "${CERT_DIR}"
  if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    ok "复用已有自签证书 ${CERT_DIR}"
  else
    info "生成自签证书(有效期 10 年)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "${CERT_DIR}/privkey.pem" -out "${CERT_DIR}/fullchain.pem" \
      -subj "/CN=${DOMAIN}" -addext "subjectAltName=IP:${DOMAIN}" >/dev/null 2>&1 \
      || die "自签证书生成失败"
    chmod 600 "${CERT_DIR}/privkey.pem"
    ok "自签证书已生成 ${CERT_DIR}"
  fi
  # 浏览器访问 IP 时不发 SNI;只有 443 才需要 default_server 接住,
  # 独立端口(如 8443)本身就是该端口唯一站点,不存在这个问题。
  if [[ "${LISTEN_PORT}" -eq 443 ]]; then
    LISTEN_OPTS=" default_server"
  fi
else
  # ── 域名:Let's Encrypt 正式证书 ──
  CERT_DIR="${CERT_BASE}/${DOMAIN}"

if [[ "${SKIP_CERT}" -eq 1 ]]; then
  [[ -f "${CERT_DIR}/fullchain.pem" ]] || die "--skip-cert 指定了,但 ${CERT_DIR} 下没有证书"
  ok "跳过签发,复用 ${CERT_DIR}"
else
  info "签发证书(Let's Encrypt webroot 方式)"

  mkdir -p "${WEBROOT}/.well-known/acme-challenge"
  chown -R www-data:www-data "${WEBROOT}" 2>/dev/null || true
  chmod -R 0755 "${WEBROOT}"

  # 阶段一:临时 80 站点,只服务 ACME 验证
  TMP_SITE="/etc/nginx/sites-available/${SITE_NAME}.acme-tmp"
  cat > "${TMP_SITE}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root ${WEBROOT}; }
    location / { return 404; }
}
EOF
  ln -sfn "${TMP_SITE}" "/etc/nginx/sites-enabled/${SITE_NAME}.acme-tmp"
  nginx -t >/dev/null 2>&1 || { rm -f "/etc/nginx/sites-enabled/${SITE_NAME}.acme-tmp" "${TMP_SITE}"; die "临时 nginx 配置校验失败"; }
  systemctl reload nginx

  CERTBOT_ARGS=(certonly --webroot -w "${WEBROOT}" -d "${DOMAIN}"
                --email "${EMAIL}" --agree-tos --non-interactive
                --keep-until-expiring --expand)
  [[ "${STAGING}" -eq 1 ]] && CERTBOT_ARGS+=(--staging)

  if ! certbot "${CERTBOT_ARGS[@]}"; then
    rm -f "/etc/nginx/sites-enabled/${SITE_NAME}.acme-tmp" "${TMP_SITE}"
    systemctl reload nginx || true
    die "证书签发失败。常见原因:DNS 尚未解析到本机 / 80 端口被墙外阻断 / 域名拼错。
排查:  dig +short ${DOMAIN}
或用测试环境先验证:  sudo bash install.sh --staging"
  fi

  rm -f "/etc/nginx/sites-enabled/${SITE_NAME}.acme-tmp" "${TMP_SITE}"
  ok "证书已签发: ${CERT_DIR}"
fi
fi

# ---------- 渲染并安装正式站点配置 ----------
info "安装 nginx 站点配置"

export DOMAIN TUNNEL_PORT CLIENT_MAX_BODY CERT_DIR AUTH_FILE LISTEN_OPTS LISTEN_PORT
envsubst '${DOMAIN} ${TUNNEL_PORT} ${CLIENT_MAX_BODY} ${CERT_DIR} ${AUTH_FILE} ${LISTEN_OPTS} ${LISTEN_PORT}' \
  < "${TEMPLATE_FILE}" > "${NGINX_AVAILABLE}"

# 不走 certbot 时删掉 80 端口那一段:同一个 IP/域名作为 server_name 往往已被
# 其它站点占用,留着只会让 nginx 报 "conflicting server name ... ignored"。
if [[ "${NEED_ACME}" -eq 0 ]]; then
  sed -i '/# @@HTTP_BLOCK_START@@/,/# @@HTTP_BLOCK_END@@/d' "${NGINX_AVAILABLE}"
  info "无需 ACME 验证:已省略 80 端口站点(避免 server_name 冲突)"
fi

# 非强制 HTTPS 时把 80 段的 301 去掉(保持简单:仅在需要时改)
if [[ "${FORCE_HTTPS}" != "1" ]]; then
  sed -i 's|return 301 https://\$host\$request_uri;|try_files $uri =404;|' "${NGINX_AVAILABLE}"
  warn "FORCE_HTTPS=0:80 端口不再强制跳转"
fi

ln -sfn "${NGINX_AVAILABLE}" "${NGINX_ENABLED}"

if ! nginx -t; then
  # 校验失败立刻回滚,避免把坏配置留在 sites-enabled 里
  rm -f "${NGINX_ENABLED}" "${NGINX_AVAILABLE}"
  die "nginx 配置校验失败,已自动回滚。常见原因:443 上已有别的 default_server,
或 ${TUNNEL_PORT} 与现有站点冲突。"
fi
systemctl reload nginx
ok "nginx 已重载"

# ---------- 续期钩子 ----------
if [[ "${IS_IP}" -eq 0 ]]; then
  info "确认证书自动续期"
  if systemctl list-timers 2>/dev/null | grep -q certbot; then
    ok "certbot 定时续期已启用"
  else
    warn "没检测到 certbot timer,请确认续期任务存在,否则 90 天后会过期"
  fi
else
  info "自签证书有效期 10 年,无需续期"
fi

# ---------- 摘要 ----------
if [[ "${LISTEN_PORT}" -eq 443 ]]; then
  PUBLIC_ADDR="https://${DOMAIN}"
else
  PUBLIC_ADDR="https://${DOMAIN}:${LISTEN_PORT}"
fi
echo
printf '%s┌──────────────────────────────────────────────────────────┐%s\n' "$C_GRN" "$C_RESET"
printf '%s│  服务器端部署完成                                        │%s\n' "$C_GRN" "$C_RESET"
printf '%s└──────────────────────────────────────────────────────────┘%s\n' "$C_GRN" "$C_RESET"
echo
printf '  公网地址      : %s%s%s\n' "$C_BOLD" "${PUBLIC_ADDR}" "$C_RESET"
printf '  登录墙账号    : %s%s%s\n' "$C_BOLD" "${AUTH_USER}" "$C_RESET"
if [[ "${PASS_GENERATED}" -eq 1 ]]; then
  printf '  登录墙密码    : %s%s%s   %s(只显示这一次,请立即保存)%s\n' \
    "$C_BOLD" "${AUTH_PASS}" "$C_RESET" "$C_YEL" "$C_RESET"
elif [[ "${AUTH_PASS}" == "__KEEP_EXISTING__" ]]; then
  printf '  登录墙密码    : %s未改动(沿用原值)%s\n' "$C_YEL" "$C_RESET"
else
  printf '  登录墙密码    : %s(取自 config.env)%s\n' "$C_YEL" "$C_RESET"
fi
printf '  隧道落点      : 127.0.0.1:%s\n' "${TUNNEL_PORT}"
echo
printf '%s  接下来到 Windows 上执行(把 <你的服务器用户> 换成真实用户名):%s\n' "$C_BOLD" "$C_RESET"
echo
printf '    powershell -ExecutionPolicy Bypass -File setup.ps1 `\n'
printf '      -ServerHost %s `\n' "${DOMAIN}"
printf '      -ServerUser <你的服务器用户> `\n'
printf '      -TunnelPort %s `\n' "${TUNNEL_PORT}"
printf '      -PublicUrl %s\n' "${PUBLIC_ADDR}"
echo
printf '%s  首次登录记得带 token:%s token 在 PC 上 dsh web 的启动日志里,\n' "$C_BOLD" "$C_RESET"
printf '  形如 %s/?token=xxxxxxxx\n' "${PUBLIC_ADDR}"
echo
