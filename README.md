# TurtleTAK

<p align="center"><img src="docs/logo.png" width="260" alt="TurtleTAK"></p>

TAK payloads for the **Hak5 LAN Turtle** family. The LAN Turtle becomes a sensor on the TAK map, watches the wired network, and raises TAK alerts.

| Edition | Device | Status |
|---|---|---|
| [**Hub Edition**](payloads/library/general/TurtleTAK-Hub/) | LAN Turtle Hub | 1.0.0 |

**Hub Edition** puts the Hub on TAK with:

- Position and status reports, and GeoChat
- Network watch alerts: new devices, watched devices going missing, ARP spoofing, rogue DHCP, link tamper, TAK link down and certificate expiry, with per-type settings and quiet hours
- Device names, site survey data packages to TAK, and clone packages to set up more Hubs
- An ATAK mesh SA bridge
- Easy TAK setup like ATAK (connection package, certificates with their own passwords, or enrollment), with no openssl needed
- Wi-Fi and WireGuard uplinks
- A web console with an offline map

See its [README](payloads/library/general/TurtleTAK-Hub/README.md).

Part of the SECT0101 TAK projects, with PagerTAK, PineappleTAK and SharkTAKDisplay.

> Use only on networks you own or are authorized to monitor. Community project, not supported by Hak5.

## License

GPL-3.0. See [LICENSE](LICENSE).

[Buy Me a Coffee](https://buymeacoffee.com/sect0101)
