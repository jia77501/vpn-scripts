#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_VPN_USER='admin'
readonly DEFAULT_VPN_PASSWORD='141242'
readonly UPSTREAM_COMMIT='aa2da30a57dd530829c99bfb37535f8d4cee4113'
readonly UPSTREAM_BASE="https://raw.githubusercontent.com/hwdsl2/setup-ipsec-vpn/${UPSTREAM_COMMIT}"

VPN_USER_INPUT="${VPN_USER:-}"
VPN_PASSWORD_INPUT="${VPN_PASSWORD:-}"
WORK_DIR=''

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-l2tp.sh
  sudo bash install-l2tp.sh [--user USERNAME] [--password PASSWORD]

Interactive mode prompts for the username and password. Press Enter at either
prompt to accept its default: username admin, password 141242.
Environment variables VPN_USER and VPN_PASSWORD are also supported for automation.
The IPsec pre-shared key is generated randomly for every installation.
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
    --user)
      (($# >= 2)) || die '--user requires a value'
      VPN_USER_INPUT=$2
      shift 2
      ;;
    --password)
      (($# >= 2)) || die '--password requires a value'
      VPN_PASSWORD_INPUT=$2
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

if [[ -s /etc/ipsec.conf ]] && grep -Eq '^[[:space:]]*conn l2tp-psk' /etc/ipsec.conf; then
  die 'an L2TP/IPsec installation already exists; refusing to overwrite its credentials'
fi

if [[ -t 0 ]]; then
  if [[ -z "$VPN_USER_INPUT" ]]; then
    read -r -p "VPN username [$DEFAULT_VPN_USER]: " entered_user
    VPN_USER_INPUT="${entered_user:-$DEFAULT_VPN_USER}"
  fi
  if [[ -z "$VPN_PASSWORD_INPUT" ]]; then
    read -r -s -p "VPN password [$DEFAULT_VPN_PASSWORD]: " entered_password
    printf '\n'
    VPN_PASSWORD_INPUT="${entered_password:-$DEFAULT_VPN_PASSWORD}"
  fi
else
  VPN_USER_INPUT="${VPN_USER_INPUT:-$DEFAULT_VPN_USER}"
  VPN_PASSWORD_INPUT="${VPN_PASSWORD_INPUT:-$DEFAULT_VPN_PASSWORD}"
fi

[[ -n "$VPN_USER_INPUT" ]] || die 'username cannot be empty'
[[ -n "$VPN_PASSWORD_INPUT" ]] || die 'password cannot be empty'
case "$VPN_USER_INPUT" in
  *[[:space:]]*|*\"*|*\'*|*\\*) die 'username contains unsupported characters' ;;
esac
case "$VPN_PASSWORD_INPUT" in
  *\"*|*\'*|*\\*) die 'password cannot contain double quote, single quote, or backslash' ;;
esac

UPSTREAM_SCRIPT_NAME=''
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} == centos && ${VERSION_ID%%.*} == 7 ]]; then
    printf 'Warning: CentOS 7 is end-of-life and no longer receives security updates.\n' >&2
  fi
  case "${ID:-}" in
    debian|ubuntu) UPSTREAM_SCRIPT_NAME='vpnsetup_ubuntu.sh' ;;
    alpine) UPSTREAM_SCRIPT_NAME='vpnsetup_alpine.sh' ;;
    centos|rhel|rocky|almalinux|ol) UPSTREAM_SCRIPT_NAME='vpnsetup_centos.sh' ;;
  esac
fi
[[ -n "$UPSTREAM_SCRIPT_NAME" ]] || die 'unsupported Linux distribution'
readonly UPSTREAM_SCRIPT_NAME
readonly UPSTREAM_URL="${UPSTREAM_BASE}/${UPSTREAM_SCRIPT_NAME}"

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v openssl >/dev/null 2>&1 || die 'openssl is required'

umask 077
WORK_DIR=$(mktemp -d /tmp/l2tp-installer.XXXXXX)
readonly WORK_DIR
readonly UPSTREAM_SCRIPT="$WORK_DIR/vpnsetup.sh"

VPN_IPSEC_PSK=$(openssl rand -base64 36 | tr -d '\n')
readonly VPN_IPSEC_PSK
[[ ${#VPN_IPSEC_PSK} -ge 32 ]] || die 'failed to generate a strong random PSK'

printf 'Downloading reviewed upstream installer at commit %s...\n' "$UPSTREAM_COMMIT"
curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 \
  --output "$UPSTREAM_SCRIPT" "$UPSTREAM_URL"
[[ -s "$UPSTREAM_SCRIPT" ]] || die 'downloaded installer is empty'
grep -q 'Script for automatic setup of an IPsec VPN server' "$UPSTREAM_SCRIPT" \
  || die 'downloaded file did not pass the title sanity check'
grep -q 'github.com/hwdsl2/setup-ipsec-vpn' "$UPSTREAM_SCRIPT" \
  || die 'downloaded file did not pass the source sanity check'

export VPN_USER="$VPN_USER_INPUT"
export VPN_PASSWORD="$VPN_PASSWORD_INPUT"
export VPN_IPSEC_PSK
export VPN_SKIP_IKEV2=yes

printf 'Installing IPsec/L2TP...\n'
bash "$UPSTREAM_SCRIPT"

printf 'Running post-install checks...\n'
modprobe ppp_generic 2>/dev/null || die 'the running kernel does not provide the ppp_generic module'
modprobe l2tp_ppp 2>/dev/null || die 'the running kernel does not provide the l2tp_ppp module'
[[ -c /dev/ppp ]] || die '/dev/ppp is missing; install a kernel with PPP support and reboot'
printf '%s\n' ppp_generic l2tp_ppp > /etc/modules-load.d/l2tp.conf
systemctl restart xl2tpd
[[ -s /etc/ipsec.conf ]] || die '/etc/ipsec.conf was not created'
[[ -s /etc/ipsec.secrets ]] || die '/etc/ipsec.secrets was not created'
[[ -s /etc/xl2tpd/xl2tpd.conf ]] || die '/etc/xl2tpd/xl2tpd.conf was not created'
[[ -s /etc/ppp/chap-secrets ]] || die '/etc/ppp/chap-secrets was not created'
grep -Fq "\"$VPN_USER_INPUT\" l2tpd \"$VPN_PASSWORD_INPUT\"" /etc/ppp/chap-secrets \
  || die 'L2TP user was not written correctly'
grep -Fq "$VPN_IPSEC_PSK" /etc/ipsec.secrets || die 'IPsec PSK was not written correctly'
grep -Eq '^[[:space:]]*conn l2tp-psk' /etc/ipsec.conf || die 'L2TP/IPsec connection is missing'

if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet ipsec || die 'IPsec service is not active'
  systemctl is-active --quiet xl2tpd || die 'xl2tpd service is not active'
fi

server_ip=$(curl --fail --silent --show-error --max-time 10 --proto '=https' --tlsv1.2 https://api.ipify.org || true)
[[ -n "$server_ip" ]] || server_ip='<server-public-ip>'

cat <<EOF

Installation completed and local service checks passed.

VPN type: L2TP/IPsec with pre-shared key
Server: $server_ip
Username: $VPN_USER_INPUT
Password: $VPN_PASSWORD_INPUT
IPsec PSK: $VPN_IPSEC_PSK

Required firewall ports: UDP 500 and UDP 4500
EOF
