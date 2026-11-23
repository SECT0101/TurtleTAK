# Changelog

TurtleTAK versions. Newest first.

## Hub Edition 1.0.0
- First release for the LAN Turtle Hub, as one `payload.sh`: Bash for the Hub commands, with a Python 3 service and a web page written from it.
- Sensor on TAK: a position and status marker (`a-f-G-E-S`) every 60 s, plus GeoChat send and receive. Chat commands `status`, `where`, `scan`, `alerts` and `help`.
- Network watch on the RJ45 side:
  - A baseline per network.
  - New-device alerts.
  - ARP-spoofing alerts: a gateway MAC change, or one MAC claiming the gateway and another IP.
  - Rogue DHCP check that never takes a lease.
  - RJ45 link lost / restored, and TAK link down / restored.
- Alerts go to a TAK marker, chat, the Hub's notifications, optional Cloud C², and the LED. Everything is queued while TAK is unreachable.
- ATAK mesh SA bridge in both directions, for XML and TAK protocol v1 (protobuf).
- Location from a USB GPS on the dynamic port, your ATAK, a saved site, a manual position or the public IP.
- Connecting to TAK works like ATAK, in three ways: a connection package; the client certificate and truststore, each with its own password; or enrollment with a TAK username and password.
- No openssl needed: TurtleTAK reads `.p12` files itself (AES, 3DES and RC2) and makes its own enrollment key and CSR.
- Out-of-band Wi-Fi and WireGuard uplinks.
- Web console on port 8484, on every interface.
- Device names and watched devices: alerts use the names, and a watched device that stops answering raises *Device missing* (then *Device back*).
- Client certificate expiry shown, with an alert 30 days before.
- Alert settings: each type on or off, the lowest level for map markers and chat lines, and quiet hours.
- Site survey data package to TAK (everyone, one contact, or upload only) or as a download.
- Clone package (`.turtletak`) to set up another Hub with the same settings and certificates, plus its own callsign and UID.
- Offline web map: Leaflet built in, with tiles cached on the Hub (or USB storage) and *Save this area offline* for USGS maps.
- Works without the `ip` command: it falls back to `/proc` and ioctl.
