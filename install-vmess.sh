#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_PORT='10086'
readonly INSTALLER_COMMIT='e741a4f56d368afbb9e5be3361b40c4552d3710d'
readonly INSTALLER_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${INSTALLER_COMMIT}/install-release.sh"

VMESS_PORT_INPUT="${VMESS_PORT:-}"
VMESS_UUID_INPUT="${VMESS_UUID:-}"
WORK_DIR=''

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-vmess.sh
  sudo bash install-vmess.sh [--port PORT] [--uuid UUID]

Interactive mode prompts for the port and UUID. Press Enter to use port 10086
or to generate a random UUID. VMESS_PORT and VMESS_UUID are also supported for
automated deployment.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --port)
      (($# >= 2)) || die '--port requires a value'
      VMESS_PORT_INPUT=$2
      shift 2
      ;;
    --uuid)
      (($# >= 2)) || die '--uuid requires a value'
      VMESS_UUID_INPUT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'run this installer as root'

if [[ -x /usr/local/x-ui/x-ui ]] || systemctl cat x-ui.service >/dev/null 2>&1; then
  die 'x-ui is installed and manages its own Xray process; refusing to create a conflicting installation'
fi
if [[ -x /usr/local/bin/xray ]] || systemctl cat xray.service >/dev/null 2>&1; then
  die 'Xray is already installed; refusing to overwrite its port or UUID'
fi

if [[ -t 0 ]]; then
  if [[ -z "$VMESS_PORT_INPUT" ]]; then
    read -r -p "VMess port [$DEFAULT_PORT]: " entered_port
    VMESS_PORT_INPUT="${entered_port:-$DEFAULT_PORT}"
  fi
  if [[ -z "$VMESS_UUID_INPUT" ]]; then
    read -r -p 'VMess UUID [press Enter to generate randomly]: ' entered_uuid
    VMESS_UUID_INPUT="$entered_uuid"
  fi
else
  VMESS_PORT_INPUT="${VMESS_PORT_INPUT:-$DEFAULT_PORT}"
fi

[[ "$VMESS_PORT_INPUT" =~ ^[0-9]+$ ]] || die 'port must be a number'
((VMESS_PORT_INPUT >= 1 && VMESS_PORT_INPUT <= 65535)) || die 'port must be between 1 and 65535'

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v base64 >/dev/null 2>&1 || die 'base64 is required'
command -v systemctl >/dev/null 2>&1 || die 'systemd is required'

if [[ -z "$VMESS_UUID_INPUT" ]]; then
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    VMESS_UUID_INPUT=$(< /proc/sys/kernel/random/uuid)
  elif command -v uuidgen >/dev/null 2>&1; then
    VMESS_UUID_INPUT=$(uuidgen)
  else
    die 'cannot generate UUID; install uuid-runtime or provide --uuid'
  fi
fi
VMESS_UUID_INPUT="${VMESS_UUID_INPUT,,}"
[[ "$VMESS_UUID_INPUT" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
  || die 'UUID is not valid'

if command -v ss >/dev/null 2>&1 && ss -H -lnt "sport = :$VMESS_PORT_INPUT" | grep -q .; then
  die "TCP port $VMESS_PORT_INPUT is already in use"
fi

umask 077
WORK_DIR=$(mktemp -d /tmp/vmess-installer.XXXXXX)
readonly WORK_DIR
readonly INSTALLER_SCRIPT="$WORK_DIR/install-release.sh"

printf 'Downloading the reviewed official Xray installer...\n'
curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 \
  --output "$INSTALLER_SCRIPT" "$INSTALLER_URL"
[[ -s "$INSTALLER_SCRIPT" ]] || die 'downloaded installer is empty'
grep -q 'github.com/XTLS/Xray-install' "$INSTALLER_SCRIPT" \
  || die 'downloaded installer did not pass the source sanity check'

printf 'Installing Xray-core...\n'
bash "$INSTALLER_SCRIPT" install

if ! id xray >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/xray --create-home \
    --shell /usr/sbin/nologin xray
fi
install -d -m 755 /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/20-service-user.conf <<'EOF'
[Service]
User=xray
Group=xray
EOF

readonly CONFIG_DIR='/usr/local/etc/xray'
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
install -d -m 755 "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a -- "$CONFIG_FILE" "$CONFIG_FILE.backup-$(date +%Y%m%d%H%M%S)"
fi

cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $VMESS_PORT_INPUT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$VMESS_UUID_INPUT",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF
chown xray:xray "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

/usr/local/bin/xray run -test -config "$CONFIG_FILE"
systemctl daemon-reload
systemctl enable xray >/dev/null
systemctl restart xray
for _ in {1..10}; do
  if systemctl is-active --quiet xray \
    && ss -H -lnt "sport = :$VMESS_PORT_INPUT" | grep -q .; then
    break
  fi
  sleep 1
done
if ! systemctl is-active --quiet xray; then
  journalctl -u xray --no-pager -n 20 >&2 || true
  die 'Xray service is not active'
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${VMESS_PORT_INPUT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "${VMESS_PORT_INPUT}/tcp" >/dev/null
elif command -v iptables >/dev/null 2>&1; then
  if ! iptables -C INPUT -p tcp --dport "$VMESS_PORT_INPUT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p tcp --dport "$VMESS_PORT_INPUT" -j ACCEPT
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null
  fi
fi

ss -H -lnt "sport = :$VMESS_PORT_INPUT" | grep -q . \
  || die "Xray is not listening on TCP port $VMESS_PORT_INPUT"

server_ip=$(curl --fail --silent --show-error --max-time 10 \
  --proto '=https' --tlsv1.2 https://api.ipify.org || true)
[[ -n "$server_ip" ]] || server_ip='<server-public-ip>'

vmess_json=$(printf \
  '{"v":"2","ps":"VMess-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":""}' \
  "$server_ip" "$server_ip" "$VMESS_PORT_INPUT" "$VMESS_UUID_INPUT")
vmess_link="vmess://$(printf '%s' "$vmess_json" | base64 | tr -d '\n')"

cat <<EOF

Installation completed and checks passed.

Protocol: VMess over TCP
Server: $server_ip
Port: $VMESS_PORT_INPUT
UUID: $VMESS_UUID_INPUT
Alter ID: 0
Encryption: auto
Transport: TCP
TLS: disabled

Import link:
$vmess_link

Security note: this minimal IP-only profile does not use TLS. For production,
prefer a domain-based TLS deployment or a modern VLESS/REALITY profile.
EOF
