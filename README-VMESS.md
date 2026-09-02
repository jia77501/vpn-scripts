# Interactive VMess installer

Run:

```bash
sudo bash install-vmess.sh
```

The installer asks for the TCP port and VMess UUID. Press Enter to accept port
`10086` and generate a random UUID. VMess does not use a username/password; the
UUID is the authentication credential and must be kept private.

For automation, `--port`, `--uuid`, `VMESS_PORT`, and `VMESS_UUID` are supported.

The script downloads the official XTLS installer from a reviewed, fixed commit,
writes a minimal VMess-over-TCP configuration, validates it with Xray, starts the
service, opens the local firewall port, and prints an importable `vmess://` link.
It first installs the required `ca-certificates`, `curl`, `unzip`, `tar`,
`iproute2`, and `openssl` packages using the detected distribution package manager.

The script refuses to run when Xray or x-ui is already installed. This prevents
repeated runs or competing managers from silently replacing the working port and
UUID. Xray runs under a dedicated unprivileged `xray` system account.

This IP-only profile does not use TLS. It is intended as the simplest functional
VMess deployment. A domain-based TLS configuration or VLESS/REALITY is preferred
when metadata protection, camouflage, or stronger modern defaults are required.
