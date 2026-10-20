#!/usr/bin/env bash
# ============================================================
#  dsh-win-tunnel · 服务器端卸载脚本
#  移除 nginx 站点与登录墙文件。默认保留 Let's Encrypt 证书。
# ============================================================
set -euo pipefail

SITE_NAME="dsh-win-tunnel"
NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}"
AUTH_FILE="/etc/nginx/.htpasswd-${SITE_NAME}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''
fi
info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "请用 root 执行: sudo bash uninstall.sh"

PURGE_CERT=0
for arg in "$@"; do
  case "${arg}" in
    --purge-cert) PURGE_CERT=1 ;;
    -h|--help)
      cat <<'EOF'
用法: sudo bash uninstall.sh [--purge-cert]

  --purge-cert   同时删除该域名的 Let's Encrypt 证书
EOF
      exit 0 ;;
    *) die "未知参数: ${arg}" ;;
  esac
done

info "移除 nginx 站点"

if [[ -L "${NGINX_ENABLED}" || -f "${NGINX_ENABLED}" ]]; then
  rm -f "${NGINX_ENABLED}"
  ok "已移除 ${NGINX_ENABLED}"
else
  warn "${NGINX_ENABLED} 不存在,跳过"
fi

if [[ -f "${NGINX_AVAILABLE}" ]]; then
  rm -f "${NGINX_AVAILABLE}"
  ok "已移除 ${NGINX_AVAILABLE}"
fi

if [[ -f "${AUTH_FILE}" ]]; then
  rm -f "${AUTH_FILE}"
  ok "已移除 ${AUTH_FILE}"
fi

# 清理可能残留的临时 ACME 站点
rm -f "/etc/nginx/sites-enabled/${SITE_NAME}.acme-tmp" \
      "/etc/nginx/sites-available/${SITE_NAME}.acme-tmp" 2>/dev/null || true

if command -v nginx >/dev/null 2>&1; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    ok "nginx 已重载"
  else
    warn "nginx 配置当前不通过校验,未执行 reload,请手工检查"
  fi
fi

if [[ "${PURGE_CERT}" -eq 1 ]]; then
  DOMAIN=""
  if [[ -f "$(dirname "${BASH_SOURCE[0]}")/config.env" ]]; then
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/config.env"
    DOMAIN="${DOMAIN:-}"
  fi
  if [[ -n "${DOMAIN}" ]]; then
    info "删除证书 ${DOMAIN}"
    certbot delete --cert-name "${DOMAIN}" --non-interactive || warn "删除证书失败,可手动 certbot delete"
    ok "证书已删除"
  else
    warn "未读到 DOMAIN,跳过证书删除"
  fi
fi

echo
ok "卸载完成。Windows 侧的隧道进程与计划任务请到 PC 上执行 uninstall.ps1 清理。"
