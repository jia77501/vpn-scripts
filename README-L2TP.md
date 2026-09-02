# L2TP/IPsec one-click installer

This installer wraps the reviewed `hwdsl2/setup-ipsec-vpn` installer at a fixed
commit. It accepts only a VPN username and password and generates a random IPsec
pre-shared key locally on the server.

```bash
sudo bash install-l2tp.sh
```

The installer asks for a username and password. Enter a custom value or press
Enter to accept the displayed default. The defaults are username `admin` and
password `141242`; they are convenient but weak, so change them for any
Internet-facing installation.

For automated deployment, `--user` and `--password` or the `VPN_USER` and
`VPN_PASSWORD` environment variables are also supported.

If an L2TP/IPsec installation already exists, the script stops without changing
the PSK or user credentials. Remove the old installation deliberately before
performing a fresh install.

The script verifies that the IPsec, xl2tpd, PPP credential files and services
were created. A successful local check does not prove that an external firewall
or cloud security group permits UDP ports 500 and 4500.

Some cloud-optimized kernels omit the `ppp_generic` module required by L2TP. In
that case, install the distribution's standard kernel, reboot into it, and run
the installer again. On Debian this kernel is provided by `linux-image-amd64`.

CentOS 7 is end-of-life. The installer emits a warning on CentOS 7, and a newer
supported operating system is strongly recommended for production use.
