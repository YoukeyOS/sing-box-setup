#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2026-04-06"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup_on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  if [ "$exit_code" -ne 0 ]; then
    printf '[ERROR] 脚本在第 %s 行失败，退出码 %s。\n' "$line_no" "$exit_code" >&2
    printf '[ERROR] 请检查上面的输出；如需重试，修正后可直接再次运行本脚本。\n' >&2
  fi
}
trap 'cleanup_on_error $LINENO' ERR

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die '请使用 root 运行本脚本。'
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die '当前系统没有 apt-get；本脚本面向 Debian/Ubuntu。'
}

check_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu) ;;
      *) warn "检测到系统为 ${PRETTY_NAME:-unknown}。脚本按 Debian/Ubuntu 设计，仍将继续。" ;;
    esac
  fi
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

prompt() {
  local __var_name="$1"
  local __label="$2"
  local __default="${3:-}"
  local __secret="${4:-0}"
  local __reply=""

  if [ -n "$__default" ]; then
    if [ "$__secret" = "1" ]; then
      printf '%s [已设置，直接回车保留]: ' "$__label" >&2
      IFS= read -r -s __reply
      printf '\n' >&2
    else
      printf '%s [%s]: ' "$__label" "$__default" >&2
      IFS= read -r __reply
    fi
  else
    if [ "$__secret" = "1" ]; then
      printf '%s: ' "$__label" >&2
      IFS= read -r -s __reply
      printf '\n' >&2
    else
      printf '%s: ' "$__label" >&2
      IFS= read -r __reply
    fi
  fi

  if [ -z "$__reply" ]; then
    printf -v "$__var_name" '%s' "$__default"
  else
    printf -v "$__var_name" '%s' "$(trim "$__reply")"
  fi
}

confirm() {
  local __label="$1"
  local __default="${2:-Y}"
  local __answer=""
  local __suffix='[Y/n]'

  case "$__default" in
    Y|y) __suffix='[Y/n]' ;;
    N|n) __suffix='[y/N]' ;;
    *) __suffix='[Y/n]' ;;
  esac

  printf '%s %s: ' "$__label" "$__suffix" >&2
  IFS= read -r __answer || true
  __answer="$(trim "$__answer")"
  if [ -z "$__answer" ]; then
    __answer="$__default"
  fi
  case "$__answer" in
    Y|y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

random_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_'
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

validate_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  read -r a b c d <<<"$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$octet" -ge 0 ] 2>/dev/null || return 1
    [ "$octet" -le 255 ] 2>/dev/null || return 1
  done
}

validate_host_basic() {
  local host="$1"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$host" == *.* ]] || return 1
}

auto_detect_public_ipv4() {
  local detected=''
  if command -v curl >/dev/null 2>&1; then
    detected="$(curl -4 -fsS https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -n1 || true)"
  fi
  printf '%s' "$detected"
}

backup_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$file" "${file}.bak.${ts}"
    info "已备份 $file -> ${file}.bak.${ts}"
  fi
}

apt_install() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_base_packages() {
  info '安装基础依赖...'
  apt_install ca-certificates curl gnupg jq openssl certbot python3-certbot-dns-cloudflare
}

install_sing_box_repo() {
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    info "sing-box 已安装：$(sing-box version 2>/dev/null | head -n1 || true)"
    return 0
  fi

  info '安装 sing-box...'
  install_sing_box_repo
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box; then
    warn 'APT 安装 sing-box 失败，回退到官方安装脚本。'
    curl -fsSL https://sing-box.app/install.sh | sh
  fi

  command -v sing-box >/dev/null 2>&1 || die 'sing-box 安装失败。'
}

ensure_sing_box_user_group() {
  getent passwd sing-box >/dev/null 2>&1 || die '未找到 sing-box 用户；请检查 sing-box 安装。'
  getent group sing-box >/dev/null 2>&1 || die '未找到 sing-box 组；请检查 sing-box 安装。'
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local base='https://api.cloudflare.com/client/v4'
  local response=''

  if [ -n "$data" ]; then
    response="$(curl -fsS -X "$method" "$base$endpoint" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H 'Content-Type: application/json' \
      --data "$data")"
  else
    response="$(curl -fsS -X "$method" "$base$endpoint" \
      -H "Authorization: Bearer $CF_TOKEN")"
  fi

  local success
  success="$(printf '%s' "$response" | jq -r '.success // false')"
  if [ "$success" != 'true' ]; then
    printf '%s\n' "$response" >&2
    die "Cloudflare API 调用失败：$method $endpoint"
  fi
  printf '%s' "$response"
}

ensure_cloudflare_a_record() {
  info '通过 Cloudflare API 检查/写入 A 记录（DNS only）...'
  local zone_resp zone_id rec_resp rec_id payload
  zone_resp="$(cf_api GET "/zones?name=${ZONE_DOMAIN}&status=active")"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty')"
  [ -n "$zone_id" ] || die "未找到已激活的 Cloudflare Zone：$ZONE_DOMAIN"

  rec_resp="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${SERVICE_HOST}")"
  rec_id="$(printf '%s' "$rec_resp" | jq -r '.result[0].id // empty')"
  payload="$(jq -nc --arg name "$SERVICE_HOST" --arg content "$SERVER_IPV4" '{type:"A",name:$name,content:$content,ttl:1,proxied:false}')"

  if [ -n "$rec_id" ]; then
    cf_api PUT "/zones/${zone_id}/dns_records/${rec_id}" "$payload" >/dev/null
    info "已更新 Cloudflare A 记录：$SERVICE_HOST -> $SERVER_IPV4（DNS only）"
  else
    cf_api POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
    info "已创建 Cloudflare A 记录：$SERVICE_HOST -> $SERVER_IPV4（DNS only）"
  fi
}

prepare_cloudflare_credentials() {
  local slug
  slug="$(slugify "$ZONE_DOMAIN")"
  CF_CREDENTIALS_FILE="/root/.secrets/certbot/cloudflare-${slug}.ini"
  mkdir -p /root/.secrets/certbot
  chmod 700 /root/.secrets /root/.secrets/certbot || true

  if [ -z "$CF_TOKEN" ] && [ -f "$CF_CREDENTIALS_FILE" ]; then
    info "复用现有 Cloudflare 凭据：$CF_CREDENTIALS_FILE"
  elif [ -n "$CF_TOKEN" ]; then
    cat >"$CF_CREDENTIALS_FILE" <<EOF
# Cloudflare API token used by Certbot
# Keep this file private.
dns_cloudflare_api_token = $CF_TOKEN
EOF
    chmod 600 "$CF_CREDENTIALS_FILE"
    info "已写入 Cloudflare 凭据：$CF_CREDENTIALS_FILE"
  else
    die '缺少 Cloudflare API Token，且没有可复用的本地凭据文件。'
  fi
}

issue_or_reuse_certificate() {
  local cert_dir="/etc/letsencrypt/live/${SERVICE_HOST}"
  local issue_now='no'

  if [ -f "$cert_dir/fullchain.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
    info "发现已有证书：$cert_dir"
    if [ "$FORCE_REISSUE" = 'yes' ]; then
      issue_now='yes'
    else
      issue_now='no'
    fi
  else
    issue_now='yes'
  fi

  if [ "$issue_now" = 'yes' ]; then
    prepare_cloudflare_credentials
    info "申请/更新 Let's Encrypt 证书：$SERVICE_HOST"
    local cmd=(certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDENTIALS_FILE" --dns-cloudflare-propagation-seconds "$CF_PROPAGATION_SECONDS" --agree-tos --non-interactive -d "$SERVICE_HOST")
    if [ -n "$LE_EMAIL" ]; then
      cmd+=(--email "$LE_EMAIL")
    else
      cmd+=(--register-unsafely-without-email)
    fi
    if [ "$FORCE_REISSUE" = 'yes' ]; then
      cmd+=(--force-renewal)
    fi
    "${cmd[@]}"
  else
    info '复用现有证书，不重新签发。'
  fi

  [ -f "$cert_dir/fullchain.pem" ] || die "未找到证书文件：$cert_dir/fullchain.pem"
  [ -f "$cert_dir/privkey.pem" ] || die "未找到私钥文件：$cert_dir/privkey.pem"
}

copy_certificate_for_sing_box() {
  CERT_DST_DIR="/etc/sing-box/certs/${SERVICE_HOST}"
  install -d -m 750 -o root -g sing-box "$CERT_DST_DIR"
  install -m 640 -o root -g sing-box "/etc/letsencrypt/live/${SERVICE_HOST}/fullchain.pem" "$CERT_DST_DIR/fullchain.pem"
  install -m 640 -o root -g sing-box "/etc/letsencrypt/live/${SERVICE_HOST}/privkey.pem" "$CERT_DST_DIR/privkey.pem"
  info "已复制证书到 $CERT_DST_DIR（root:sing-box, 640）"
}

install_cert_deploy_hook() {
  local slug hook_file
  slug="$(slugify "$SERVICE_HOST")"
  hook_file="/etc/letsencrypt/renewal-hooks/deploy/90-sing-box-${slug}.sh"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >"$hook_file" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
install -d -m 750 -o root -g sing-box "$CERT_DST_DIR"
install -m 640 -o root -g sing-box "/etc/letsencrypt/live/${SERVICE_HOST}/fullchain.pem" "$CERT_DST_DIR/fullchain.pem"
install -m 640 -o root -g sing-box "/etc/letsencrypt/live/${SERVICE_HOST}/privkey.pem" "$CERT_DST_DIR/privkey.pem"
systemctl reload-or-restart sing-box >/dev/null 2>&1 || true
EOF
  chmod 750 "$hook_file"
  info "已安装证书续期 hook：$hook_file"
}

write_singbox_config() {
  CONFIG_DIR='/etc/sing-box'
  CONFIG_PATH="${CONFIG_DIR}/config.json"
  mkdir -p "$CONFIG_DIR"
  backup_if_exists "$CONFIG_PATH"

  python3 - "$CONFIG_PATH" "$SERVICE_HOST" "$PORT" "$CLIENT_NAME" "$ANYTLS_PASSWORD" "$CERT_DST_DIR/fullchain.pem" "$CERT_DST_DIR/privkey.pem" <<'PY'
import json
import sys
config_path, host, port, client_name, password, cert_path, key_path = sys.argv[1:]
config = {
    "log": {"level": "info"},
    "inbounds": [
        {
            "type": "anytls",
            "tag": "anytls-in",
            "listen": "::",
            "listen_port": int(port),
            "users": [{"name": client_name, "password": password}],
            "tls": {
                "enabled": True,
                "certificate_path": cert_path,
                "key_path": key_path,
            },
        }
    ],
    "outbounds": [
        {"type": "direct", "tag": "direct"}
    ],
}
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

  chmod 644 "$CONFIG_PATH"
  info "已生成 sing-box 配置：$CONFIG_PATH"
}

stop_legacy_anytls() {
  if [ "$STOP_LEGACY_ANYTLS" != 'yes' ]; then
    return 0
  fi
  info '停止旧 anytls-go 服务（如果存在）...'
  systemctl stop anytls 2>/dev/null || true
  systemctl disable anytls 2>/dev/null || true
  pkill -f anytls-server 2>/dev/null || true
}

ensure_port_ready() {
  local listeners=''
  listeners="$(ss -lntp | awk -v p=":${PORT}" '$4 ~ p"$" {print}')"
  if [ -n "$listeners" ]; then
    if printf '%s\n' "$listeners" | grep -q 'sing-box'; then
      info "端口 $PORT 当前由 sing-box 占用，稍后会重启。"
    else
      printf '%s\n' "$listeners" >&2
      die "端口 $PORT 仍被其他进程占用，请先释放端口再重试。"
    fi
  fi
}

check_singbox_config() {
  sing-box check -c "$CONFIG_PATH"
  info 'sing-box 配置校验通过。'
}

start_services() {
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  if systemctl list-unit-files | grep -q '^certbot\.timer'; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  fi
}

ensure_firewall_rule() {
  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status="$(ufw status 2>/dev/null || true)"
    if printf '%s' "$ufw_status" | grep -q 'Status: active'; then
      ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
      info "已尝试通过 UFW 放行 TCP ${PORT}。"
    fi
  fi
}

save_state_file() {
  local state_dir state_file slug
  slug="$(slugify "$SERVICE_HOST")"
  state_dir='/root/.config/anytls-singbox'
  state_file="${state_dir}/${slug}.env"
  mkdir -p "$state_dir"
  cat >"$state_file" <<EOF
SERVICE_HOST='$SERVICE_HOST'
ZONE_DOMAIN='$ZONE_DOMAIN'
PORT='$PORT'
CLIENT_NAME='$CLIENT_NAME'
ANYTLS_PASSWORD='$ANYTLS_PASSWORD'
CONFIG_PATH='$CONFIG_PATH'
CERT_PATH='$CERT_DST_DIR/fullchain.pem'
KEY_PATH='$CERT_DST_DIR/privkey.pem'
LE_LIVE_DIR='/etc/letsencrypt/live/$SERVICE_HOST'
EOF
  chmod 600 "$state_file"
  info "已保存部署摘要到 $state_file"
}

print_cert_summary() {
  openssl x509 -in "$CERT_DST_DIR/fullchain.pem" -noout -subject -issuer -dates || true
}

print_final_summary() {
  cat <<EOF

============================================================
部署完成。

Shadowrocket 配置：
  类型: AnyTLS
  服务器: $SERVICE_HOST
  端口: $PORT
  密码: $ANYTLS_PASSWORD
  SNI / Server Name: $SERVICE_HOST
  Allow Insecure / 跳过证书验证: 关闭

服务端文件：
  sing-box 配置: $CONFIG_PATH
  证书副本:     $CERT_DST_DIR/fullchain.pem
  私钥副本:     $CERT_DST_DIR/privkey.pem

注意事项：
  1) Cloudflare 上 $SERVICE_HOST 的 A 记录应保持 DNS only（灰云）。
  2) 若你之后续期证书，deploy hook 会自动复制证书并重载 sing-box。
  3) 如需查看日志：journalctl -u sing-box --output cat -f
============================================================
EOF
}

main() {
  require_root
  require_apt
  check_os

  info "AnyTLS on sing-box 一键交互部署脚本 v${SCRIPT_VERSION}"
  info "目标：Debian/Ubuntu + sing-box AnyTLS + Let's Encrypt + Cloudflare DNS API"
  printf '\n' >&2

  local default_host="${ANYTLS_HOST:-${SERVICE_HOST:-}}"
  local default_zone="${ANYTLS_ZONE:-${ZONE_DOMAIN:-}}"
  local default_port="${ANYTLS_PORT:-443}"
  local default_name="${ANYTLS_NAME:-iphone}"
  local default_email="${ANYTLS_EMAIL:-}"
  local default_ip="${ANYTLS_SERVER_IPV4:-}"
  local default_password="${ANYTLS_PASSWORD:-}"
  local default_prop="${ANYTLS_CF_PROPAGATION:-60}"

  if [ -z "$default_ip" ]; then
    default_ip="$(auto_detect_public_ipv4 || true)"
  fi

  prompt SERVICE_HOST '请输入 AnyTLS 使用的完整域名（例如 sg.example.com）' "$default_host"
  validate_host_basic "$SERVICE_HOST" || die '域名格式看起来不正确。'

  prompt ZONE_DOMAIN '请输入 Cloudflare Zone 根域名（例如 example.com）' "$default_zone"
  validate_host_basic "$ZONE_DOMAIN" || die 'Zone 根域名格式看起来不正确。'
  case "$SERVICE_HOST" in
    "$ZONE_DOMAIN"|*".$ZONE_DOMAIN") ;;
    *) die '服务域名必须等于根域名，或属于该根域名的子域名。' ;;
  esac

  prompt LE_EMAIL "请输入 Let's Encrypt 邮箱（可留空）" "$default_email"
  prompt PORT '请输入监听端口' "$default_port"
  validate_port "$PORT" || die '端口必须是 1-65535 的整数。'

  prompt CLIENT_NAME '请输入 AnyTLS 用户名（仅服务端标识，可自定义）' "$default_name"
  [ -n "$CLIENT_NAME" ] || CLIENT_NAME='iphone'

  prompt ANYTLS_PASSWORD '请输入 AnyTLS 密码（留空自动生成）' "$default_password" 1
  if [ -z "$ANYTLS_PASSWORD" ]; then
    ANYTLS_PASSWORD="$(random_password)"
    info '已自动生成 AnyTLS 密码。'
  fi

  prompt CF_PROPAGATION_SECONDS '请输入 DNS 验证等待秒数' "$default_prop"
  validate_port "$CF_PROPAGATION_SECONDS" || die 'DNS 验证等待秒数必须是正整数。'

  if confirm '是否通过 Cloudflare API 自动创建/更新 A 记录为 DNS only？' 'Y'; then
    MANAGE_DNS='yes'
    prompt SERVER_IPV4 '请输入要写入 Cloudflare 的服务器 IPv4' "$default_ip"
    validate_ipv4 "$SERVER_IPV4" || die 'IPv4 格式不正确。'
  else
    MANAGE_DNS='no'
    SERVER_IPV4=''
  fi

  local cf_token_default=''
  if [ -n "${ANYTLS_CF_TOKEN:-}" ]; then
    cf_token_default='preset'
  fi
  prompt CF_TOKEN '请输入 Cloudflare API Token（留空则尝试复用本地凭据）' "$cf_token_default" 1
  if [ "$CF_TOKEN" = 'preset' ]; then
    CF_TOKEN="${ANYTLS_CF_TOKEN:-}"
  fi

  if confirm '发现已有证书时是否强制重新签发？' 'N'; then
    FORCE_REISSUE='yes'
  else
    FORCE_REISSUE='no'
  fi

  if confirm '是否停止并禁用旧 anytls-go 服务（若存在）？' 'Y'; then
    STOP_LEGACY_ANYTLS='yes'
  else
    STOP_LEGACY_ANYTLS='no'
  fi

  printf '\n以下配置将生效：\n' >&2
  printf '  服务域名: %s\n' "$SERVICE_HOST" >&2
  printf '  Zone 根域名: %s\n' "$ZONE_DOMAIN" >&2
  printf '  监听端口: %s\n' "$PORT" >&2
  printf '  用户名: %s\n' "$CLIENT_NAME" >&2
  printf '  自动管理 DNS: %s\n' "$MANAGE_DNS" >&2
  if [ "$MANAGE_DNS" = 'yes' ]; then
    printf '  服务器 IPv4: %s\n' "$SERVER_IPV4" >&2
  fi
  printf '  强制重签证书: %s\n' "$FORCE_REISSUE" >&2
  printf '  停止旧 anytls-go: %s\n' "$STOP_LEGACY_ANYTLS" >&2
  printf '\n' >&2
  confirm '确认继续部署？' 'Y' || die '已取消。'

  install_base_packages
  install_sing_box
  ensure_sing_box_user_group

  if [ "$MANAGE_DNS" = 'yes' ]; then
    [ -n "$CF_TOKEN" ] || die '自动管理 DNS 需要 Cloudflare API Token。'
    ensure_cloudflare_a_record
  else
    warn "请确认 $SERVICE_HOST 的 A 记录已手动指向服务器，且 Proxy status 为 DNS only（灰云）。"
  fi

  issue_or_reuse_certificate
  copy_certificate_for_sing_box
  install_cert_deploy_hook
  write_singbox_config
  check_singbox_config
  stop_legacy_anytls
  ensure_port_ready
  ensure_firewall_rule
  start_services

  systemctl is-active --quiet sing-box || {
    journalctl -u sing-box --output cat -n 100 --no-pager || true
    die 'sing-box 未能成功启动。'
  }

  save_state_file
  print_cert_summary
  print_final_summary
}

main "$@"
