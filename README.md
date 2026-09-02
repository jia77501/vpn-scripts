# VPN one-click installers

Interactive installers for L2TP/IPsec and VMess on Linux servers.

## L2TP/IPsec

```bash
wget -O install-l2tp.sh https://raw.githubusercontent.com/jia77501/vpn-scripts/main/install-l2tp.sh
chmod +x install-l2tp.sh
sudo ./install-l2tp.sh
```

Enter a custom username and password when prompted, or press Enter to use
username `admin` and password `141242`. The IPsec pre-shared key is generated
randomly during installation.

## VMess

```bash
wget -O install-vmess.sh https://raw.githubusercontent.com/jia77501/vpn-scripts/main/install-vmess.sh
chmod +x install-vmess.sh
sudo ./install-vmess.sh
```

Enter a TCP port when prompted, or press Enter to use port `10086`. Press Enter
at the UUID prompt to generate a random credential.

See [README-L2TP.md](README-L2TP.md) and [README-VMESS.md](README-VMESS.md) for
requirements, behavior, and security notes.

