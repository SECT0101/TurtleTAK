#!/bin/bash
# Title: TurtleTAK Hub Edition
# Description: Puts the LAN Turtle Hub on TAK as a facility sensor - position and status, GeoChat, network watch alerts (new devices, ARP spoofing, rogue DHCP, link tamper), an ATAK mesh SA bridge and a web console
# Author: SECT0101
# Version: 1.0.0
# Category: General
# Target: LAN Turtle Hub on a network you own or are authorized to monitor
#
# What it does
#   Sensor on TAK     The Hub reports its position and status (uplink, RJ45 link, VPN, public IP,
#                     watch and bridge counts) as a CoT marker (a-f-G-E-S) every SA_INTERVAL seconds
#   GeoChat           Send / receive from the web console. Others can direct-message the Hub:
#                     status, where, scan, alerts, help
#   Network watch     Sweeps the RJ45 network, keeps a baseline per network and alerts on:
#                     new devices, a gateway MAC change or duplicate gateway MAC (ARP spoofing),
#                     a rogue DHCP server, RJ45 link lost / restored (tamper), TAK link down
#   Alerts            Marker at the Hub (yellow = warning, red = critical) + All Chat Rooms line
#                     + Hub notification (bell icon) + optional Cloud C2 notification + LED flash.
#                     Nothing reachable? Alerts and chat are queued and sent when TAK is back.
#   Mesh SA bridge    Optional: ATAK mesh SA / chat on the LAN (239.2.3.1:6969, 224.10.10.1:17012,
#                     XML or TAK protocol v1) forwarded to the TAK Server, and server traffic
#                     repeated back onto the LAN - a whole room of ATAK users on the server
#   Uplinks           Out-of-band Wi-Fi client and the Hub's WireGuard client from the settings
#   Web console       http://<hub>:8484 on every interface (USB-C host, RJ45, Wi-Fi, VPN)
#
# Location (the Hub has no GPS), first that works in auto mode:
#   1. USB GPS on the dynamic USB port (u-blox / VK-162 style NMEA, claimed for the Hub)
#   2. Anchor to your ATAK (MY_ATAK callsign, from the TAK Server or the mesh)
#   3. A saved site   4. Manual lat/lon (or click the web map)   5. Public IP (city level)
#
# Setup
#   1. Run the payload once. It creates /root/turtletak/ and its default.cfg, and posts the web
#      console's first password as a Hub notification (also in /root/turtletak/web-password.txt).
#   2. Open http://172.16.84.1:8484 (or the Hub's RJ45 / Wi-Fi / VPN address) > Setup.
#   3. Setup > TAK Server connection, one of:
#        Connection package  the .zip from your TAK admin (passwords inside it are used)
#        Certificates        server + client .p12 with its password + truststore .p12 with its password
#        Enroll              your TAK username and password (certificate enrollment)
#      No openssl needed: .p12 files (AES, 3DES or RC2) and enrollment keys are handled in Python.
#   4. Set the location, and turn on the mesh bridge if you want it.
#
# LED (LED: 0 in the settings keeps it dark)
#   Magenta solid    starting          Yellow double   connecting to TAK
#   Green single     on TAK            Red slow        setup needed (no server / certificate)
#   Cyan inverse     warning alert     Red fast        critical alert (both for 60 s)
#
# Files
#   /root/turtletak/default.cfg     every setting, "KEY: value" (web console Settings, or SSH)
#   /root/turtletak/certs/          TAK certificates, connection packages, wg.conf (never share)
#   /root/turtletak/baselines/      known devices, one file per network
#   /root/turtletak/sites.txt       saved sites: name|lat|lon
#   /root/turtletak/logs/           turtletak.log (also in the web console)
#   /root/turtletak/app/            the service and web page - rewritten from this payload on every run
#
# Use only on networks you own or are authorized to monitor. Community payload, not supported by Hak5.

BASE="${TT_BASE:-/root/turtletak}"
APP="$BASE/app"
PY=$(command -v python3 || command -v python)

# Hak5 commands (LED, NOTIFY_*, C2NOTIFY, WIFI_CONNECT, WIREGUARD_*, USB_*, BOOT_PAYLOAD) are
# handed to the Python service's child shells, whether they are programs or Bash functions here.
for c in LED NOTIFY_INFO NOTIFY_WARNING NOTIFY_ERROR LOG_INFO LOG_WARNING LOG_ERROR C2NOTIFY C2EXFIL \
         WIFI_CONNECT WIFI_DISCONNECT WIREGUARD_CONFIGURE WIREGUARD_ENABLE WIREGUARD_DISABLE \
         USB_CLAIM_DEVICE USB_POWER_ON USB_POWER_OFF BOOT_PAYLOAD; do
    [ "$(type -t "$c")" = "function" ] && export -f "$c"
done

if [ -z "$PY" ]; then
    LED FAIL 2>/dev/null
    NOTIFY_ERROR TurtleTAK "Python 3 not found - TurtleTAK needs it" 2>/dev/null
    echo "TurtleTAK: python3 not found" >&2
    exit 1
fi

mkdir -p "$APP" "$BASE/certs" "$BASE/logs" "$BASE/baselines"
chmod 700 "$BASE/certs"

# Stop an older copy (re-running the payload restarts the service with this version)
if [ -f "$BASE/turtletak.pid" ]; then
    old=$(cat "$BASE/turtletak.pid" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q turtletak "/proc/$old/cmdline" 2>/dev/null; then
        kill "$old" 2>/dev/null; sleep 2; kill -9 "$old" 2>/dev/null
    fi
fi

[ -f "$BASE/certs/README.txt" ] || cat > "$BASE/certs/README.txt" <<'EOF'
TurtleTAK certificates - keep this folder private.

Easiest: copy your ATAK connection package (.zip, with a .pref and .p12 files) here, or upload it
in the web console (Setup). Server, port, protocol and both certificates are imported from it.

Other ways:
  client.pem (certificate + private key) and ca.pem (the server's CA)  - used as they are
  client.p12 + truststore.p12 - converted with openssl (password: P12_PASSWORD, default atakatak)
  Enroll with your TAK username and password in the web console (needs openssl)

wg.conf here (or uploaded in Setup) brings up the Hub's WireGuard client.
EOF

# ---- the service and the web page (written fresh every run) ----------------------------------
cat > "$APP/turtletak.py" <<'TURTLETAK_PY'
#!/usr/bin/env python3
# TurtleTAK Hub Edition - core service (written to /root/turtletak/app/ by payload.sh; started by it).
# Puts the LAN Turtle Hub on TAK as a sensor: position + status SA, GeoChat, facility network watch
# (new devices, ARP spoofing, rogue DHCP, link tamper), an ATAK mesh SA bridge and a web console.
# Standard library only (Python 3.7+). Use only on networks you own or are authorized to monitor.
import base64, binascii, calendar, hashlib, hmac, ipaddress, json, math, os, random, re, select, shutil
import socket, ssl, struct, subprocess, sys, threading, time, traceback, uuid, zipfile, io
import urllib.request, urllib.error, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ttcrypto
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from xml.sax.saxutils import escape as _xesc

VERSION = "1.0.0"

# ---- DNS: the Hub's C library (musl) can fail a lookup that asks for IPv4 and IPv6 at once
# ("[Errno -5] Name has no usable address") while an IPv4-only lookup works - that is why ping works.
# Fall back to IPv4 only, then IPv6 only, then the system's nslookup. Covers TAK, enrollment and urllib.
_getaddrinfo = socket.getaddrinfo
DNS_CACHE = {}


def _nslookup(host):
    try:
        out = subprocess.run(["nslookup", host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=10).stdout.decode("utf-8", "replace")
    except Exception:
        return []
    ips, after_name = [], False
    for line in out.splitlines():
        if line.strip().lower().startswith("name:"):
            after_name = True
            continue
        m = re.search(r"Address(?:es)?(?:\s+\d+)?:\s*([0-9.]+)\s*$", line)
        if after_name and m:
            ips.append(m.group(1))
    return ips


def _gai(host, port, family=0, type=0, proto=0, flags=0):
    try:
        res = _getaddrinfo(host, port, family, type, proto, flags)
        if host:
            DNS_CACHE[host] = "system"
        return res
    except socket.gaierror as first:
        if not host or family not in (0, socket.AF_UNSPEC):
            raise
        for fam, how in ((socket.AF_INET, "IPv4 only"), (socket.AF_INET6, "IPv6 only")):
            try:
                res = _getaddrinfo(host, port, fam, type, proto, flags)
                DNS_CACHE[host] = how
                return res
            except socket.gaierror:
                pass
        ips = _nslookup(host)
        if ips:
            DNS_CACHE[host] = "nslookup %s" % ips[0]
            return _getaddrinfo(ips[0], port, socket.AF_INET, type, proto, flags | socket.AI_NUMERICHOST)
        DNS_CACHE[host] = "failed: %s" % first
        raise


socket.getaddrinfo = _gai
PRODUCT = "TurtleTAK"
EDITION = "Hub Edition"
BASE = os.environ.get("TT_BASE", "/root/turtletak")
APP = os.path.join(BASE, "app")
CERTS = os.path.join(BASE, "certs")
LOGS = os.path.join(BASE, "logs")
QUEUE = os.path.join(BASE, "queue.jsonl")
BASELINES = os.path.join(BASE, "baselines")
SITES = os.path.join(BASE, "sites.txt")
STATEF = os.path.join(BASE, "state.json")
CFG_FILE = os.path.join(BASE, "default.cfg")
LOOT = os.environ.get("TT_LOOT", "/root/loot/turtletak")
DRY = os.environ.get("TT_DRY_HUB") == "1"          # test mode: log Hub commands instead of running them

# ----------------------------------------------------------------------------------------------
# settings (default.cfg, "KEY: value", one per line; edited in the web console or over SSH)
# ----------------------------------------------------------------------------------------------
DEFAULTS = [
    ("# TAK Server", None),
    ("TAK_HOST", "takserver.example.com"),
    ("TAK_PROTO", "tls"),            # tls (8089, client cert) | tcp (8087/8088) | udp (send only)
    ("TAK_PORT", "8089"),
    ("TAK_VERIFY_HOST", "0"),        # 1 = check the server name against its certificate
    ("CLIENT_PASSWORD", "atakatak"), # client certificate (.p12) password - TAK default atakatak
    ("CA_PASSWORD", "atakatak"),     # truststore / CA (.p12) password - can differ from the client one
    ("API_PORT", "8443"),
    ("ENROLL_PORT", "8446"),
    ("CALLSIGN", "TURTLE-1"),
    ("UID", ""),                     # blank = made once from the device
    ("TEAM", "Cyan"),
    ("ROLE", "Team Member"),
    ("COT_TYPE", "a-f-G-E-S"),       # friendly ground equipment sensor
    ("SA_INTERVAL", "60"),           # seconds between position/status reports
    ("# Location", None),
    ("LOC_MODE", "auto"),            # auto | gps | atak | site | manual | ip
    ("SITE", ""),
    ("MANUAL_LAT", ""),
    ("MANUAL_LON", ""),
    ("MY_ATAK", ""),                 # your ATAK callsign, for "anchor to my ATAK"
    ("ANCHOR_MAX_AGE", "1800"),
    ("GPS_DEVICE", "auto"),          # auto | /dev/ttyACM0 | /dev/ttyUSB0 | off
    ("GPS_BAUD", "9600"),
    ("GPS_CLAIM_USB", "1"),          # 1 = claim the dynamic USB port for the Hub (GPS / radio)
    ("IPGEO", "1"),
    ("IPGEO_URL", "https://ipinfo.io/json"),
    ("# Network watch (RJ45 side)", None),
    ("WATCH", "1"),
    ("WATCH_IFACE", "auto"),         # auto = the RJ45 interface
    ("WATCH_INTERVAL", "300"),       # seconds between device sweeps
    ("WATCH_MAX_HOSTS", "256"),      # largest sweep (a /24); bigger subnets sweep the Hub's /24
    ("WATCH_RATE", "50"),            # nmap --max-rate when nmap is installed
    ("AUTO_BASELINE", "1"),          # 1 = first sweep of a new network becomes its baseline
    ("ARP_WATCH", "1"),              # gateway MAC changes / duplicate MACs
    ("DHCP_WATCH", "1"),             # rogue DHCP server check
    ("DHCP_INTERVAL", "900"),
    ("DHCP_KNOWN", ""),              # comma list of allowed DHCP server IPs (blank = learn the first)
    ("LINK_WATCH", "1"),             # RJ45 link lost / restored (tamper)
    ("UPLINK_WATCH", "1"),           # TAK link lost for longer than UPLINK_GRACE
    ("UPLINK_GRACE", "120"),
    ("MISSING_AFTER", "2"),          # sweeps a watched device can be absent before "Device missing"
    ("# Alerts", None),
    ("ALERTS_ON", "new_device,missing,arp,dhcp,link,uplink,cert"),  # alert types that are raised
    ("ALERT_MARKER", "1"),           # alert markers on the map
    ("MARKER_MIN_LEVEL", "warning"), # info | warning | critical - lowest level that gets a map marker
    ("ALERT_CHAT", "1"),             # alert line to All Chat Rooms
    ("CHAT_MIN_LEVEL", "info"),      # lowest level that goes to chat
    ("QUIET_HOURS", ""),             # e.g. 22-06: no chat lines or LED flashes then (still logged + marked)
    ("QUIET_CRITICAL", "1"),         # 1 = critical alerts still go out in quiet hours
    ("CERT_WARN_DAYS", "30"),        # warn this many days before the client certificate expires
    ("ALERT_TO", ""),                # blank = everyone, or a callsign for a direct chat instead
    ("ALERT_STALE_HOURS", "12"),
    ("HUB_NOTIFY", "1"),             # Hub web UI notifications (bell icon)
    ("C2_NOTIFY", "0"),              # also Cloud C2 notifications
    ("# Mesh SA bridge", None),
    ("BRIDGE_UP", "0"),              # 1 = forward ATAK mesh SA / chat on the LAN to the TAK Server
    ("BRIDGE_DOWN", "0"),            # 1 = repeat TAK Server traffic onto the LAN mesh
    ("BRIDGE_IFACES", "auto"),       # auto = every IPv4 interface except loopback / VPN, or a comma list
    ("BRIDGE_SA_GROUP", "239.2.3.1:6969"),
    ("BRIDGE_CHAT_GROUP", "224.10.10.1:17012"),
    ("BRIDGE_MIN_GAP", "5"),         # seconds: forward one SA per device at most this often
    ("BRIDGE_DOWN_TYPES", "a-f,a-h,a-n,a-u,b-t-f,b-m"),
    ("# Map", None),
    ("MAP_SOURCE", "usgs_topo"),     # usgs_topo | usgs_imagery | usgs_hybrid | osm (osm: live only, never bulk-saved)
    ("TILE_CACHE_MB", "500"),        # map tile cache limit (on USB storage when one is attached)
    ("TILE_MAX_DOWNLOAD", "20000"),  # most tiles one "Save this area" may fetch
    ("# Uplinks", None),
    ("WIFI_SSID", ""),               # out-of-band Wi-Fi uplink (Hub joins this network as a client)
    ("WIFI_KEY", ""),
    ("WIFI_ENC", "psk2"),            # open | psk | psk2 | sae
    ("WIFI_COUNTRY", "US"),
    ("WG_CONF", ""),                 # path to a wg.conf for the Hub's WireGuard client
    ("# Hub", None),
    ("LED", "1"),                    # 0 = keep the LED dark (stealth)
    ("RUN_AT_BOOT", "1"),
    ("CHAT_COMMANDS", "1"),          # answer "status", "where", "scan", "help" sent to this callsign
    ("CHAT_COMMANDS_FROM", ""),      # blank = anyone on the server, or a comma list of callsigns
    ("WEB", "1"),
    ("WEB_PORT", "8484"),
    ("WEB_BIND", "0.0.0.0"),         # every interface: USB-C host, RJ45, Wi-Fi, VPN
    ("WEB_TLS", "0"),
    ("WEB_PASS_HASH", ""),
]
CFG = {}
CFG_LOCK = threading.Lock()


def cfg_load():
    vals = {k: v for k, v in DEFAULTS if v is not None}
    if os.path.exists(CFG_FILE):
        for line in open(CFG_FILE, encoding="utf-8", errors="replace"):
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                vals[k.strip()] = v.strip()
    with CFG_LOCK:
        CFG.clear()
        CFG.update(vals)
    cfg_write()


def cfg_write():
    out = ["# TurtleTAK %s settings - KEY: value. Changed in the web console or over SSH." % EDITION]
    known = set()
    with CFG_LOCK:
        for k, v in DEFAULTS:
            if v is None:
                out.append("")
                out.append(k)
            else:
                out.append("%s: %s" % (k, CFG.get(k, v)))
                known.add(k)
        extra = [k for k in CFG if k not in known]
        if extra:
            out.append("")
            out.append("# Other")
            out += ["%s: %s" % (k, CFG[k]) for k in extra]
    tmp = CFG_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(out) + "\n")
    os.replace(tmp, CFG_FILE)


def cfg(k, default=""):
    with CFG_LOCK:
        return CFG.get(k, default)


def cfgi(k, default=0):
    try:
        return int(float(cfg(k, default)))
    except (TypeError, ValueError):
        return default


def cfgb(k):
    return cfg(k, "0").strip().lower() in ("1", "yes", "true", "on")


def cfg_set(changes):
    with CFG_LOCK:
        for k, v in changes.items():
            CFG[k] = str(v).replace("\n", " ").strip()
    cfg_write()


# ----------------------------------------------------------------------------------------------
# logging, events, Hub commands
# ----------------------------------------------------------------------------------------------
LOGQ = []
LOG_LOCK = threading.Lock()


def log(msg, level="info"):
    line = "%s [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), level, msg)
    with LOG_LOCK:
        LOGQ.append(line)
        del LOGQ[:-400]
        try:
            with open(os.path.join(LOGS, "turtletak.log"), "a") as fh:
                fh.write(line + "\n")
            p = os.path.join(LOGS, "turtletak.log")
            if os.path.getsize(p) > 512 * 1024:
                os.replace(p, p + ".1")
        except OSError:
            pass
    print(line, flush=True)


HUB_LOCK = threading.Lock()


def hub(*args, timeout=20):
    """Run a Hak5 DuckyScript command (LED, NOTIFY_INFO, C2NOTIFY...). payload.sh exports them to
    child shells, so they work whether the firmware ships them as programs or Bash functions."""
    cmd = " ".join(sh_quote(str(a)) for a in args)
    if DRY:
        log("hub> " + cmd, "debug")
        return 0, ""
    try:
        with HUB_LOCK:
            p = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace").strip()
    except Exception as e:
        return 1, str(e)


def sh_quote(s):
    if re.match(r"^[A-Za-z0-9_./:@,+=-]+$", s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


def run(cmd, timeout=10):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def have(prog):
    return shutil.which(prog) is not None


LED_STATE = {"base": "SETUP", "until": 0, "shown": None}


def led(state=None, flash=None, secs=30):
    """state = steady LED for the current link state; flash = temporary state (alerts)."""
    if state:
        LED_STATE["base"] = state
    if flash:
        LED_STATE["flash"] = flash
        LED_STATE["until"] = time.time() + secs
    want = LED_STATE["base"]
    if time.time() < LED_STATE.get("until", 0):
        want = LED_STATE.get("flash", want)
    if not cfgb("LED"):
        want = "OFF"
    if want != LED_STATE["shown"]:
        LED_STATE["shown"] = want
        hub("LED", *want.split())


def notify(level, msg):
    if cfgb("HUB_NOTIFY"):
        hub({"info": "NOTIFY_INFO", "warning": "NOTIFY_WARNING", "error": "NOTIFY_ERROR"}[level], "TurtleTAK", msg)
    if cfgb("C2_NOTIFY"):
        hub("C2NOTIFY", {"info": "INFO", "warning": "WARNING", "error": "ERROR"}[level], "TurtleTAK: " + msg)


# ----------------------------------------------------------------------------------------------
# shared state
# ----------------------------------------------------------------------------------------------
S = {
    "started": time.time(),
    "tak": {"state": "starting", "since": time.time(), "error": "", "tx": 0, "rx": 0, "last_rx": 0},
    "pos": {"lat": None, "lon": None, "ce": 9999999, "hae": 0, "src": "none", "time": 0},
    "gps": {"device": "", "fix": False, "sats": 0, "time": 0, "lat": None, "lon": None},
    "contacts": {},       # uid -> {callsign, lat, lon, type, team, time, how}
    "chat": [],           # {time, dir, from, to, room, text, id}
    "alerts": [],         # {id, time, kind, level, title, detail, sent}
    "net": {},            # network watch status
    "hosts": {},          # mac -> {ip, first, last, known, vendor}
    "bridge": {"up_rx": 0, "up_tx": 0, "down_tx": 0, "devices": {}, "ifaces": [], "error": ""},
    "status": {},
}
SL = threading.RLock()


def save_state():
    try:
        with SL:
            keep = {"pos": S["pos"], "alerts": S["alerts"][-200:], "chat": S["chat"][-300:],
                    "dhcp_known": S["net"].get("dhcp_known", [])}
        tmp = STATEF + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(keep, fh)
        os.replace(tmp, STATEF)
    except Exception as e:
        log("state save failed: %s" % e, "warning")


def load_state():
    try:
        d = json.load(open(STATEF))
        with SL:
            if d.get("pos", {}).get("lat") is not None:
                S["pos"] = d["pos"]
                S["pos"]["src"] = "last known"
            S["alerts"] = d.get("alerts", [])
            S["chat"] = d.get("chat", [])
            S["net"]["dhcp_known"] = d.get("dhcp_known", [])
    except Exception:
        pass


# ----------------------------------------------------------------------------------------------
# CoT helpers
# ----------------------------------------------------------------------------------------------
def x(v):
    return _xesc(str(v), {'"': "&quot;"})


def iso(t=None):
    t = time.time() if t is None else t
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def my_uid():
    u = cfg("UID")
    if not u:
        mac = ""
        for n in sorted(os.listdir("/sys/class/net")) if os.path.isdir("/sys/class/net") else []:
            try:
                m = open("/sys/class/net/%s/address" % n).read().strip()
                if m and m != "00:00:00:00:00:00":
                    mac = m
                    break
            except OSError:
                pass
        u = "TurtleTAK-" + (mac.replace(":", "")[-8:] if mac else uuid.uuid4().hex[:8])
        cfg_set({"UID": u})
    return u


def point_xml(lat, lon, ce=9999999, hae=0):
    if lat is None:
        lat, lon, ce = 0.0, 0.0, 9999999
    return '<point lat="%.7f" lon="%.7f" hae="%s" ce="%s" le="9999999"/>' % (lat, lon, hae or 0, int(ce))


def ev_open(uid, ctype, stale_s, how="h-e", t=None):
    t = time.time() if t is None else t
    return '<event version="2.0" uid="%s" type="%s" how="%s" time="%s" start="%s" stale="%s">' % (
        x(uid), x(ctype), how, iso(t), iso(t), iso(t + stale_s))


def sa_event():
    p = S["pos"]
    st = S["status"]
    uid = my_uid()
    remarks = status_text()
    interval = max(15, cfgi("SA_INTERVAL", 60))
    return (ev_open(uid, cfg("COT_TYPE", "a-f-G-E-S"), interval * 3 + 30, "m-g" if p["src"] == "gps" else "h-e")
            + point_xml(p["lat"], p["lon"], p["ce"], p.get("hae", 0))
            + "<detail>"
            + '<contact callsign="%s" endpoint="*:-1:stcp"/>' % x(cfg("CALLSIGN"))
            + '<__group name="%s" role="%s"/>' % (x(cfg("TEAM")), x(cfg("ROLE")))
            + '<takv device="LAN Turtle Hub" platform="%s" os="%s" version="%s"/>' % (
                PRODUCT, x(st.get("os", "Linux")), VERSION)
            + '<precisionlocation geopointsrc="%s" altsrc="???"/>' % ("GPS" if p["src"] == "gps" else "USER")
            + '<uid Droid="%s"/>' % x(cfg("CALLSIGN"))
            + "<remarks>%s</remarks>" % x(remarks)
            + "</detail></event>")


def chat_event(text, to_cs=None, to_uid=None):
    uid = my_uid()
    cs = cfg("CALLSIGN")
    mid = str(uuid.uuid4())
    if to_uid:
        room, rid = to_cs, to_uid
    else:
        room, rid = "All Chat Rooms", "All Chat Rooms"
    p = S["pos"]
    dest = '<marti><dest callsign="%s"/></marti>' % x(to_cs) if to_uid else ""
    return (ev_open("GeoChat.%s.%s.%s" % (uid, rid, mid), "b-t-f", 86400, "h-g-i-g-o")
            + point_xml(p["lat"], p["lon"], p["ce"])
            + "<detail>"
            + '<__chat parent="RootContactGroup" groupOwner="false" messageId="%s" chatroom="%s" id="%s" senderCallsign="%s">'
            % (mid, x(room), x(rid), x(cs))
            + '<chatgrp uid0="%s" uid1="%s" id="%s"/></__chat>' % (x(uid), x(rid), x(rid))
            + '<link uid="%s" type="%s" relation="p-p"/>' % (x(uid), x(cfg("COT_TYPE")))
            + '<remarks source="BAO.F.ATAK.%s" to="%s" time="%s">%s</remarks>' % (x(uid), x(rid), iso(), x(text))
            + dest + "</detail></event>"), mid, room


def marker_event(uid, ctype, title, remarks, lat, lon, ce, stale_s):
    return (ev_open(uid, ctype, stale_s, "h-e") + point_xml(lat, lon, ce)
            + "<detail>"
            + '<contact callsign="%s"/>' % x(title)
            + '<link uid="%s" production_time="%s" type="%s" parent_callsign="%s" relation="p-p"/>'
            % (x(my_uid()), iso(), x(cfg("COT_TYPE")), x(cfg("CALLSIGN")))
            + '<archive/><usericon iconsetpath="COT_MAPPING_2525B/%s/%s"/>' % (ctype[:3], ctype)
            + "<remarks>%s</remarks></detail></event>" % x(remarks))


ATTR_RE = re.compile(r'([A-Za-z_:][-\w:.]*)\s*=\s*"([^"]*)"|([A-Za-z_:][-\w:.]*)\s*=\s*\'([^\']*)\'')


def attrs(tag):
    out = {}
    for m in ATTR_RE.finditer(tag):
        if m.group(1):
            out[m.group(1)] = xml_unesc(m.group(2))
        else:
            out[m.group(3)] = xml_unesc(m.group(4))
    return out


def xml_unesc(v):
    return (v.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'")
            .replace("&#10;", "\n").replace("&amp;", "&"))


def tag(ev, name):
    m = re.search(r"<%s\b([^>]*?)/?>" % re.escape(name), ev)
    return attrs(m.group(1)) if m else None


def parse_time(s):
    try:
        base, _, frac = s.rstrip("Z").partition(".")
        return calendar.timegm(time.strptime(base, "%Y-%m-%dT%H:%M:%S")) + float("0." + (re.sub(r"\D", "", frac) or "0"))
    except Exception:
        return time.time()


# ----------------------------------------------------------------------------------------------
# TAK protocol v1 (protobuf) - mesh SA from ATAK; tiny decoder, no library needed
# ----------------------------------------------------------------------------------------------
def pb_fields(buf):
    i, n = 0, len(buf)
    while i < n:
        key, i = pb_varint(buf, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = pb_varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]; i += 8
        elif wt == 2:
            ln, i = pb_varint(buf, i)
            v = buf[i:i + ln]; i += ln
        elif wt == 5:
            v = buf[i:i + 4]; i += 4
        else:
            raise ValueError("wire type %d" % wt)
        yield f, wt, v


def pb_varint(buf, i):
    r = s = 0
    while True:
        b = buf[i]; i += 1
        r |= (b & 0x7F) << s
        s += 7
        if not b & 0x80:
            return r, i


def tak_proto_to_xml(data):
    """TAK protocol v1 mesh packet (0xbf 0x01 0xbf + TakMessage) -> CoT XML string."""
    if len(data) < 4 or data[0] != 0xBF or data[2] != 0xBF:
        return None
    ev = None
    for f, wt, v in pb_fields(data[3:]):
        if f == 2 and wt == 2:
            ev = v
    if ev is None:
        return None
    e = {}
    detail = b""
    for f, wt, v in pb_fields(ev):
        if wt == 2 and f in (1, 2, 3, 4, 5, 9):
            e[f] = v.decode("utf-8", "replace")
        elif wt == 0 and f in (6, 7, 8):
            e[f] = v
        elif wt == 1 and f in (10, 11, 12, 13, 14):
            e[f] = struct.unpack("<d", v)[0]
        elif f == 15 and wt == 2:
            detail = v
    d = []
    for f, wt, v in pb_fields(detail):
        if wt != 2:
            continue
        sub = {ff: vv for ff, ww, vv in pb_fields(v)} if f != 1 else {}
        s = lambda k: x(sub.get(k, b"").decode("utf-8", "replace")) if isinstance(sub.get(k, b""), bytes) else ""
        if f == 1:
            d.append(v.decode("utf-8", "replace"))
        elif f == 2:
            d.append('<contact endpoint="%s" callsign="%s"/>' % (s(1), s(2)))
        elif f == 3:
            d.append('<__group name="%s" role="%s"/>' % (s(1), s(2)))
        elif f == 4:
            d.append('<precisionlocation geopointsrc="%s" altsrc="%s"/>' % (s(1), s(2)))
        elif f == 5:
            d.append('<status battery="%s"/>' % sub.get(1, 0))
        elif f == 6:
            d.append('<takv device="%s" platform="%s" os="%s" version="%s"/>' % (s(1), s(2), s(3), s(4)))
        elif f == 7:
            sp = struct.unpack("<d", sub[1])[0] if isinstance(sub.get(1), bytes) and len(sub[1]) == 8 else 0
            co = struct.unpack("<d", sub[2])[0] if isinstance(sub.get(2), bytes) and len(sub[2]) == 8 else 0
            d.append('<track speed="%s" course="%s"/>' % (sp, co))
    ms = lambda k: iso(e.get(k, int(time.time() * 1000)) / 1000.0)
    return ('<event version="2.0" uid="%s" type="%s" how="%s" time="%s" start="%s" stale="%s">'
            % (x(e.get(5, "")), x(e.get(1, "a-u-G")), x(e.get(9, "m-g")), ms(6), ms(7), ms(8))
            + '<point lat="%s" lon="%s" hae="%s" ce="%s" le="%s"/>'
            % (e.get(10, 0.0), e.get(11, 0.0), e.get(12, 9999999.0), e.get(13, 9999999.0), e.get(14, 9999999.0))
            + "<detail>%s</detail></event>" % "".join(d))


# ----------------------------------------------------------------------------------------------
# certificates: ATAK connection package (.zip), .p12 files, PEM files, enrollment
# ----------------------------------------------------------------------------------------------
def write_secret(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)


def b64_cert(v):
    """Server/file value -> clean base64 DER of one certificate (strips PEM headers, whitespace, escapes)."""
    v = re.sub(r"-----[A-Z0-9 ]+-----", "", str(v)).replace("\\n", "").replace("\\r", "")
    v = re.sub(r"[^A-Za-z0-9+/=]", "", v)
    der = base64.b64decode(v + "=" * (-len(v) % 4))
    if not der or der[0] != 0x30:
        raise ValueError("not a certificate")
    return base64.b64encode(der).decode()


def cert_pem(v):
    b = b64_cert(v)
    return "-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n" % "\n".join(b[i:i + 64] for i in range(0, len(b), 64))


def pem_summary(path):
    """What is in a PEM file, without showing it: e.g. 'CERTIFICATE x1, RSA PRIVATE KEY x1'."""
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return "missing"
    kinds = re.findall(r"-----BEGIN ([A-Z0-9 ]+)-----", text)
    if not kinds:
        return "no PEM blocks (%d bytes)" % len(text)
    out = []
    for k in sorted(set(kinds)):
        out.append("%s x%d" % (k, kinds.count(k)))
    if text.count("-----BEGIN") != text.count("-----END"):
        out.append("UNBALANCED begin/end")
    return ", ".join(out)


def save_cert_files(client=None, ca=None, why=""):
    """Check new client / CA PEM text loads in TLS before using it; keep the old files in certs/backup/."""
    tmp = {}
    try:
        for kind, text in (("client", client), ("ca", ca)):
            if text is None:
                continue
            t = os.path.join(CERTS, ".new-%s.pem" % kind)
            write_secret(t, text)
            tmp[kind] = t
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        if "client" in tmp:
            try:
                ctx.load_cert_chain(tmp["client"])
            except (ssl.SSLError, OSError) as e:
                raise RuntimeError("the new client certificate does not load (%s; %s) - your old certificates are unchanged"
                                   % (e, pem_summary(tmp["client"])))
        if "ca" in tmp:
            try:
                ctx.load_verify_locations(tmp["ca"])
            except (ssl.SSLError, OSError) as e:
                raise RuntimeError("the new truststore does not load (%s; %s) - your old certificates are unchanged"
                                   % (e, pem_summary(tmp["ca"])))
        stamp = time.strftime("%Y%m%d-%H%M%S")
        for kind, t in tmp.items():
            cur = os.path.join(CERTS, kind + ".pem")
            if os.path.exists(cur):
                bdir = os.path.join(CERTS, "backup", stamp)
                os.makedirs(bdir, exist_ok=True)
                os.replace(cur, os.path.join(bdir, kind + ".pem"))
            os.replace(t, cur)
        if tmp:
            log("certificates updated (%s)%s" % (", ".join(sorted(tmp)), (" - " + why) if why else ""))
            threading.Thread(target=cert_check, daemon=True).start()
    finally:
        for t in tmp.values():
            if os.path.exists(t):
                os.unlink(t)


def restore_certs():
    bdir = os.path.join(CERTS, "backup")
    snaps = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    if not snaps:
        raise RuntimeError("no earlier certificates saved")
    last = os.path.join(bdir, snaps[-1])
    for kind in ("client", "ca"):
        f = os.path.join(last, kind + ".pem")
        if os.path.exists(f):
            os.replace(f, os.path.join(CERTS, kind + ".pem"))
    shutil.rmtree(last, ignore_errors=True)
    TAK.reconnect()
    return "restored the certificates from %s" % snaps[-1]


def p12_to_pem(p12, out, passwords, nokeys=False):
    """Convert a .p12 to PEM with the built-in reader (no openssl needed); openssl is only a fallback.
    passwords: one password or a list to try in order. Client: out gets leaf cert + key (+ CA certs go
    to ca.pem if there is none). CA: out gets every certificate."""
    if isinstance(passwords, str):
        passwords = [passwords]
    tried, errors = [], []
    data = open(p12, "rb").read()
    for pw in passwords:
        if pw is None or pw in tried:
            continue
        tried.append(pw)
        try:
            key, certs = ttcrypto.read_p12(data, pw)
        except ValueError as e:
            errors.append(str(e))
            if "wrong password" in str(e) or "padding" in str(e):
                continue
            break                                  # unsupported format: try openssl below
        kind_out = "ca" if os.path.basename(out).startswith("ca") else "client"
        if nokeys:
            if not certs:
                raise RuntimeError("%s has no certificates" % os.path.basename(p12))
            save_cert_files(**{kind_out: "".join(certs)}, why=os.path.basename(p12))
            return pw
        if not key:
            raise RuntimeError("%s has no private key - is it the truststore instead of the client cert?" % os.path.basename(p12))
        leaf, rest = ttcrypto.split_chain(key, certs)
        if not leaf:
            raise RuntimeError("%s: no certificate matches its private key" % os.path.basename(p12))
        ca = os.path.join(os.path.dirname(out), "ca.pem")
        save_cert_files(client=leaf + key, ca=("".join(rest) if rest and not os.path.exists(ca) else None),
                        why=os.path.basename(p12))
        return pw
    if have("openssl") and errors and not any("wrong password" in e for e in errors):
        for pw in tried:
            for legacy in (["-legacy"], []):
                p = subprocess.run(["openssl", "pkcs12"] + legacy + ["-in", p12, "-out", out, "-passin", "pass:" + pw]
                                   + (["-nokeys"] if nokeys else ["-nodes"]), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
                if p.returncode == 0 and os.path.getsize(out) > 0:
                    os.chmod(out, 0o600)
                    return pw
    if any("wrong password" in e or "padding" in e for e in errors):
        raise RuntimeError("wrong password for %s - type its password in Setup (client and truststore passwords are separate)"
                           % os.path.basename(p12))
    raise RuntimeError("could not read %s: %s" % (os.path.basename(p12), "; ".join(errors) or "unknown format"))


def pref(xmltext, key):
    m = re.search(r'<entry[^>]*key="%s"[^>]*>([^<]*)</entry>' % re.escape(key), xmltext)
    return xml_unesc(m.group(1).strip()) if m else ""


def import_package(path, client_pw=None, ca_pw=None):
    """ATAK connection data package -> server settings + certs/client.pem + certs/ca.pem."""
    z = zipfile.ZipFile(path)
    names = z.namelist()
    prefs = [n for n in names if n.lower().endswith(".pref")]
    if not prefs:
        raise RuntimeError("no .pref file in %s - is it an ATAK connection package?" % os.path.basename(path))
    text = "\n".join(z.read(n).decode("utf-8", "replace") for n in prefs)
    conn = pref(text, "connectString0")
    parts = conn.split(":")
    if len(parts) < 2:
        raise RuntimeError("no TAK Server (connectString0) in the package")
    changes = {"TAK_HOST": parts[0], "TAK_PORT": parts[1],
               "TAK_PROTO": {"ssl": "tls", "tcp": "tcp", "udp": "udp"}.get((parts[2] if len(parts) > 2 else "ssl").lower(), "tls")}
    by_base = {os.path.basename(n): n for n in names if n.lower().endswith(".p12")}
    for kind, key, pwkey in (("client", "certificateLocation", "clientPassword"), ("ca", "caLocation", "caPassword")):
        base = os.path.basename(pref(text, key))
        src = by_base.get(base)
        if not src:
            continue
        tmp = os.path.join(CERTS, ".%s.p12" % kind)
        with open(tmp, "wb") as fh:
            fh.write(z.read(src))
        try:
            typed = client_pw if kind == "client" else ca_pw
            setting = "CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"
            used = p12_to_pem(tmp, os.path.join(CERTS, kind + ".pem"),
                              [typed, pref(text, pwkey), cfg(setting), "atakatak"], nokeys=(kind == "ca"))
            changes[setting] = used
        finally:
            os.unlink(tmp)
    cfg_set(changes)
    log("imported connection package %s -> %s:%s (%s)" % (os.path.basename(path), changes["TAK_HOST"],
                                                         changes["TAK_PORT"], changes["TAK_PROTO"]))
    done = os.path.join(CERTS, "imported")
    os.makedirs(done, exist_ok=True)
    os.replace(path, os.path.join(done, os.path.basename(path)))
    return changes


def cert_kind(name):
    return "ca" if re.search(r"trust|(^|[^a-z])ca([^a-z]|$)|root", name, re.I) else "client"


def scan_certs():
    """Pick up a connection package or .p12 files dropped in certs/."""
    try:
        for n in sorted(os.listdir(CERTS)):
            p = os.path.join(CERTS, n)
            if n.lower().endswith(".zip"):
                try:
                    import_package(p)
                    notify("info", "Imported TAK connection package %s" % n)
                    TAK.reconnect()
                except Exception as e:
                    log("package %s: %s" % (n, e), "error")
                    notify("error", "Connection package %s: %s" % (n, e))
                    os.replace(p, p + ".failed")
            elif n.lower().endswith(".p12"):
                kind = cert_kind(n)
                try:
                    p12_to_pem(p, os.path.join(CERTS, kind + ".pem"),
                               [cfg("CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"), "atakatak"], nokeys=(kind == "ca"))
                    os.makedirs(os.path.join(CERTS, "imported"), exist_ok=True)
                    os.replace(p, os.path.join(CERTS, "imported", n))
                    log("converted %s -> %s.pem" % (n, kind))
                    TAK.reconnect()
                except Exception as e:
                    log(str(e), "error")
                    os.replace(p, p + ".failed")
    except FileNotFoundError:
        pass


def enroll(user, password):
    """TAK Server certificate enrollment (port 8446). Key and CSR are made in Python - no openssl needed."""
    if not user or not password:
        raise RuntimeError("enter your TAK Server username and password")
    host, port = cfg("TAK_HOST"), cfgi("ENROLL_PORT", 8446)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    auth = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()

    def call(path, body=None, ctype="text/plain"):
        req = urllib.request.Request("https://%s:%d%s" % (host, port, path), data=body,
                                     headers={"Authorization": auth, "Content-Type": ctype, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise RuntimeError("the TAK Server rejected that username or password")
            raise RuntimeError("enrollment %s failed: HTTP %d" % (path.split("?")[0], e.code))
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError("cannot reach %s:%d for enrollment: %s" % (host, port, getattr(e, "reason", e)))

    conf = call("/Marti/api/tls/config")
    names = dict(re.findall(r'<nameEntry[^>]*name="([^"]+)"[^>]*value="([^"]*)"', conf))
    subject = [(k, v) for k, v in names.items() if k.upper() != "CN"] + [("CN", user)]
    log("enrollment: making a 2048-bit key (can take up to a minute on the Hub)")
    key = ttcrypto.rsa_generate(2048)
    csr = ttcrypto.pem("CERTIFICATE REQUEST", ttcrypto.csr_der(key, subject))
    body = "".join(l for l in csr.splitlines(True) if "CERTIFICATE REQUEST" not in l)
    raw = call("/Marti/api/tls/signClient/v2?clientUid=%s&version=%s" % (my_uid(), VERSION), body.encode())
    try:
        resp = json.loads(raw)
    except ValueError:   # some servers answer in XML
        resp = {m[0]: m[1] for m in re.findall(r"<(signedCert|ca\d*)>\s*([^<]+?)\s*</\1>", raw)}
        if "ca" in resp:
            resp["ca0"] = resp.pop("ca")
    log("enrollment reply fields: %s" % ", ".join("%s(%d)" % (k, len(str(v))) for k, v in sorted(resp.items())))
    if "signedCert" not in resp:
        raise RuntimeError("the TAK Server did not return a certificate (fields: %s)" % ", ".join(sorted(resp)))
    try:
        client_text = cert_pem(resp["signedCert"]) + ttcrypto.rsa_key_pem(key)
    except ValueError as e:
        raise RuntimeError("the certificate the TAK Server sent could not be read (%s) - your old certificates are unchanged" % e)
    cas = []
    for k, v in sorted(resp.items()):
        if re.match(r"^ca\d*$", k):
            try:
                cas.append(cert_pem(v))
            except ValueError:
                log("enrollment: skipped %s (not a certificate)" % k, "warning")
    save_cert_files(client=client_text, ca=("".join(cas) if cas else None), why="enrollment")
    cfg_set({"TAK_PROTO": "tls"})
    log("enrolled with %s:%d" % (host, port))
    TAK.reconnect()


# ----------------------------------------------------------------------------------------------
# TAK Server link
# ----------------------------------------------------------------------------------------------
class TakLink:
    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()
        self.kick = threading.Event()
        self.down_since = time.time()
        self.alerted_down = False
        self.recent_down = {}          # uid -> time, events we repeated onto the mesh (loop guard)

    def connected(self):
        return self.sock is not None

    def reconnect(self):
        with self.lock:
            self._close()
        self.kick.set()

    def _close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def set_state(self, st, err=""):
        with SL:
            if (S["tak"]["state"] == "connected") != (st == "connected"):
                S["tak"]["since"] = time.time()
            S["tak"]["state"] = st
            S["tak"]["error"] = err

    def open(self):
        host, port, proto = cfg("TAK_HOST"), cfgi("TAK_PORT", 8089), cfg("TAK_PROTO", "tls").lower()
        if not host or host.endswith("example.com"):
            raise RuntimeError("set TAK_HOST (Settings, or drop a connection package in certs/)")
        if proto == "udp":
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((host, port))
            return s
        raw = socket.create_connection((host, port), timeout=15)
        if proto != "tls":
            raw.settimeout(None)
            return raw
        client = os.path.join(CERTS, "client.pem")
        ca = os.path.join(CERTS, "ca.pem")
        if not os.path.exists(client):
            raw.close()
            raise RuntimeError("no client certificate - drop an ATAK connection package (.zip) in %s, or enroll" % CERTS)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        keyf = os.path.join(CERTS, "client.key")
        ctx.load_cert_chain(client, keyf if os.path.exists(keyf) else None)
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.check_hostname = cfgb("TAK_VERIFY_HOST")
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            log("no ca.pem - the server certificate is not checked", "warning")
        s = ctx.wrap_socket(raw, server_hostname=host)
        s.settimeout(None)
        return s

    def send(self, xml, queue=False):
        data = xml.encode("utf-8")
        with self.lock:
            if self.sock:
                try:
                    self.sock.sendall(data)
                    with SL:
                        S["tak"]["tx"] += 1
                    return True
                except OSError as e:
                    log("TAK send failed: %s" % e, "warning")
                    self._close()
                    self.kick.set()
        if queue:
            with open(QUEUE, "a") as fh:
                fh.write(json.dumps({"t": time.time(), "xml": xml}) + "\n")
        return False

    def flush_queue(self):
        if not os.path.exists(QUEUE):
            return
        lines = open(QUEUE).read().splitlines()
        os.unlink(QUEUE)
        sent = 0
        for i, l in enumerate(lines):
            try:
                xml = json.loads(l)["xml"]
            except Exception:
                continue
            if not self.send(xml):
                with open(QUEUE, "a") as fh:
                    fh.write("\n".join(lines[i:]) + "\n")
                break
            sent += 1
        if sent:
            log("sent %d queued message(s)" % sent)

    def run(self):
        backoff = 5
        while True:
            self.kick.clear()
            try:
                self.set_state("connecting")
                led("Y DOUBLE")
                s = self.open()
                with self.lock:
                    self.sock = s
                self.set_state("connected")
                led("G SINGLE")
                log("TAK connected to %s:%s (%s)" % (cfg("TAK_HOST"), cfg("TAK_PORT"), cfg("TAK_PROTO")))
                if self.alerted_down:
                    raise_alert("uplink", "info", "TAK link restored",
                                "Back on the TAK Server after %s." % dur(time.time() - self.down_since), marker=False)
                self.alerted_down = False
                backoff = 5
                self.send(sa_event())
                self.flush_queue()
                if cfg("TAK_PROTO") == "udp":
                    while not self.kick.wait(30):
                        pass
                else:
                    self.read_loop(s)
            except Exception as e:
                err = str(e) or e.__class__.__name__
                self.set_state("down", err)
                if S["tak"]["error"] != getattr(self, "_last_err", None):
                    log("TAK: %s" % err, "warning")
                self._last_err = err
            with self.lock:
                self._close()
            if S["tak"]["state"] == "connected":
                self.set_state("down", "disconnected")
            led("FAIL" if "certificate" in S["tak"]["error"] or "TAK_HOST" in S["tak"]["error"] else "Y DOUBLE")
            self.kick.wait(backoff)
            backoff = min(backoff * 2, 60)

    def read_loop(self, s):
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except OSError as e:
                raise RuntimeError("read: %s" % e)
            if not chunk:
                raise RuntimeError("server closed the connection")
            buf += chunk
            if len(buf) > 2 * 1024 * 1024:
                buf = buf[-65536:]
            while b"</event>" in buf:
                ev, buf = buf.split(b"</event>", 1)
                start = ev.find(b"<event")
                if start < 0:
                    continue
                handle_event((ev[start:] + b"</event>").decode("utf-8", "replace"), source="server")

    def watchdog(self):
        """Raise an alert when the TAK link has been down longer than UPLINK_GRACE."""
        while True:
            time.sleep(10)
            if not cfgb("UPLINK_WATCH") or self.connected() or self.alerted_down:
                continue
            if S["tak"]["state"] in ("down", "connecting") and time.time() - S["tak"]["since"] > cfgi("UPLINK_GRACE", 120):
                if S["tak"]["error"].startswith("set TAK_HOST") or "certificate" in S["tak"]["error"]:
                    continue
                self.alerted_down = True
                self.down_since = S["tak"]["since"]
                raise_alert("uplink", "warning", "TAK link down",
                            "No TAK Server for %s: %s" % (dur(time.time() - S["tak"]["since"]), S["tak"]["error"]),
                            marker=False)


TAK = TakLink()


def handle_event(ev, source="server"):
    uid = (re.search(r'<event[^>]*\suid="([^"]*)"', ev) or [None, ""])[1]
    ctype = (re.search(r'<event[^>]*\stype="([^"]*)"', ev) or [None, ""])[1]
    if not uid or uid == my_uid():
        return
    with SL:
        S["tak"]["rx"] += 1
        S["tak"]["last_rx"] = time.time()
    if source == "server" and cfgb("BRIDGE_DOWN"):
        BRIDGE.down(ev, uid, ctype)
    if ctype.startswith("b-t-f"):
        chat_in(ev, ctype)
        return
    if ctype.startswith("t-x"):
        return
    pt = tag(ev, "point") or {}
    contact = tag(ev, "contact") or {}
    if not contact.get("callsign"):
        return
    try:
        lat, lon = float(pt.get("lat", 0)), float(pt.get("lon", 0))
    except ValueError:
        return
    grp = tag(ev, "__group") or {}
    stale = (re.search(r'<event[^>]*\sstale="([^"]*)"', ev) or [None, ""])[1]
    with SL:
        S["contacts"][uid] = {"callsign": contact["callsign"], "lat": lat, "lon": lon,
                              "ce": float(pt.get("ce", 9999999) or 9999999), "type": ctype, "team": grp.get("name", ""),
                              "role": grp.get("role", ""), "time": time.time(), "stale": parse_time(stale) if stale else 0,
                              "source": source, "endpoint": contact.get("endpoint", "")}
        if len(S["contacts"]) > 2000:
            for k in sorted(S["contacts"], key=lambda k: S["contacts"][k]["time"])[:200]:
                del S["contacts"][k]


def chat_in(ev, ctype):
    if ctype != "b-t-f":
        return
    c = tag(ev, "__chat") or {}
    m = re.search(r"<remarks[^>]*>(.*?)</remarks>", ev, re.S)
    text = xml_unesc(m.group(1)) if m else ""
    sender_uid = ((tag(ev, "link") or {}).get("uid")) or ""
    mid = c.get("messageId", "")
    with SL:
        if mid and any(cc.get("id") == mid for cc in S["chat"][-200:]):
            return
        to_me = c.get("id") == my_uid() or c.get("chatroom") == cfg("CALLSIGN")
        S["chat"].append({"time": time.time(), "dir": "in", "from": c.get("senderCallsign", "?"), "from_uid": sender_uid,
                          "room": "Direct" if to_me else c.get("chatroom", ""), "text": text, "id": mid})
        del S["chat"][:-300]
    log("chat from %s: %s" % (c.get("senderCallsign", "?"), text[:120]))
    if to_me and cfgb("CHAT_COMMANDS"):
        chat_command(text.strip(), c.get("senderCallsign", ""), sender_uid)
    save_state()


def chat_send(text, to_cs=None):
    to_uid = None
    if to_cs:
        with SL:
            for u, c in S["contacts"].items():
                if c["callsign"] == to_cs:
                    to_uid = u
        if not to_uid:
            raise RuntimeError("no TAK contact called %s" % to_cs)
    xml, mid, room = chat_event(text, to_cs, to_uid)
    ok = TAK.send(xml, queue=True)
    with SL:
        S["chat"].append({"time": time.time(), "dir": "out", "from": cfg("CALLSIGN"), "room": room, "text": text,
                          "id": mid, "sent": ok})
        del S["chat"][:-300]
    save_state()
    return ok


def chat_command(text, cs, uid):
    allow = [a.strip() for a in cfg("CHAT_COMMANDS_FROM").split(",") if a.strip()]
    if allow and cs not in allow:
        return
    cmd = text.lower().split()[0] if text else ""
    if cmd == "status":
        reply = status_text()
    elif cmd == "where":
        p = S["pos"]
        reply = "%s at %s (%s, +/- %s m)" % (cfg("CALLSIGN"), fmt_ll(p["lat"], p["lon"]), p["src"], int(p["ce"]))
    elif cmd == "scan":
        WATCH.kick.set()
        reply = "Network sweep started."
    elif cmd == "alerts":
        with SL:
            al = S["alerts"][-5:]
        reply = "; ".join("%s %s" % (time.strftime("%H:%M", time.localtime(a["time"])), a["title"]) for a in al) or "No alerts."
    elif cmd == "help":
        reply = "TurtleTAK commands: status, where, scan, alerts"
    else:
        return
    try:
        chat_send(reply, cs)
    except RuntimeError:
        pass


# ----------------------------------------------------------------------------------------------
# alerts
# ----------------------------------------------------------------------------------------------
ALERT_TYPES = {"warning": "a-u-G", "critical": "a-h-G", "info": "a-n-G"}


LEVELS = {"info": 0, "warning": 1, "critical": 2}
ALERT_KINDS = [("new_device", "New device"), ("missing", "Watched device missing / back"), ("arp", "ARP spoofing"),
               ("dhcp", "Rogue DHCP"), ("link", "RJ45 link lost / restored"), ("uplink", "TAK link down / restored"),
               ("cert", "Certificate expiring")]


def in_quiet_hours(now=None):
    q = cfg("QUIET_HOURS").replace(" ", "")
    m = re.match(r"^(\d{1,2})(?::(\d\d))?-(\d{1,2})(?::(\d\d))?$", q)
    if not m:
        return False
    t = time.localtime(now or time.time())
    cur = t.tm_hour * 60 + t.tm_min
    start = int(m.group(1)) * 60 + int(m.group(2) or 0)
    end = int(m.group(3)) * 60 + int(m.group(4) or 0)
    return start <= cur < end if start < end else (cur >= start or cur < end)


def raise_alert(kind, level, title, detail, marker=True, key=None):
    """level: info | warning | critical. Goes to TAK (marker + chat), the Hub UI, Cloud C2, LED -
    filtered by ALERTS_ON, MARKER_MIN_LEVEL, CHAT_MIN_LEVEL and QUIET_HOURS."""
    now = time.time()
    if kind != "test" and kind not in [k.strip() for k in cfg("ALERTS_ON").split(",")]:
        log("alert type %s is off: %s - %s" % (kind, title, detail), "debug")
        return
    with SL:
        if key and any(a.get("key") == key and now - a["time"] < 3600 for a in S["alerts"]):
            return
        aid = "%s-%d-%04d" % (kind, int(now), random.randint(0, 9999))
        a = {"id": aid, "key": key, "time": now, "kind": kind, "level": level, "title": title, "detail": detail}
        S["alerts"].append(a)
        del S["alerts"][:-200]
    rank = LEVELS.get(level, 0)
    quiet = in_quiet_hours(now) and not (level == "critical" and cfgb("QUIET_CRITICAL"))
    log("ALERT [%s] %s - %s%s" % (level, title, detail, " (quiet hours)" if quiet else ""), "warning" if level != "info" else "info")
    notify("error" if level == "critical" else ("warning" if level == "warning" else "info"), "%s: %s" % (title, detail))
    if level != "info" and not quiet:
        led(flash="SPECIAL" if level == "warning" else "FAIL2", secs=60)
    line = "[%s] %s %s - %s" % (cfg("CALLSIGN"), {"critical": "ALERT", "warning": "WARNING"}.get(level, "INFO"),
                                title, detail)
    p = S["pos"]
    if marker and cfgb("ALERT_MARKER") and p["lat"] is not None and rank >= LEVELS.get(cfg("MARKER_MIN_LEVEL"), 1):
        ang = random.uniform(0, 2 * math.pi)
        dlat = 15 * math.cos(ang) / 111111.0
        dlon = 15 * math.sin(ang) / (111111.0 * max(0.1, math.cos(math.radians(p["lat"]))))
        rem = "%s\n%s\nFrom %s (%s) at %s. Position is the Hub's, offset a few meters." % (
            title, detail, cfg("CALLSIGN"), PRODUCT, time.strftime("%Y-%m-%d %H:%M:%S %Z"))
        TAK.send(marker_event("%s.alert.%s" % (my_uid(), aid), ALERT_TYPES.get(level, "a-u-G"),
                              "%s %s" % (cfg("CALLSIGN"), title), rem, p["lat"] + dlat, p["lon"] + dlon,
                              max(15, p["ce"]), cfgi("ALERT_STALE_HOURS", 12) * 3600), queue=True)
    if cfgb("ALERT_CHAT") and not quiet and rank >= LEVELS.get(cfg("CHAT_MIN_LEVEL"), 0):
        to = cfg("ALERT_TO").strip() or None
        try:
            chat_send(line, to)
        except RuntimeError:
            chat_send(line, None)
    save_state()


# ----------------------------------------------------------------------------------------------
# device names and watched devices (devices.json: mac -> {name, watch})
# ----------------------------------------------------------------------------------------------
DEVICES_FILE = os.path.join(BASE, "devices.json")
DEV_LOCK = threading.Lock()


def devices():
    with DEV_LOCK:
        try:
            return json.load(open(DEVICES_FILE))
        except (OSError, ValueError):
            return {}


def set_device(mac, name=None, watch=None):
    mac = mac.lower()
    if not re.match(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", mac):
        raise RuntimeError("bad MAC address")
    with DEV_LOCK:
        try:
            d = json.load(open(DEVICES_FILE))
        except (OSError, ValueError):
            d = {}
        e = d.get(mac, {})
        if name is not None:
            e["name"] = name.strip()[:40]
        if watch is not None:
            e["watch"] = bool(watch)
        if e.get("name") or e.get("watch"):
            d[mac] = e
        else:
            d.pop(mac, None)
        tmp = DEVICES_FILE + ".tmp"
        json.dump(d, open(tmp, "w"), indent=1)
        os.replace(tmp, DEVICES_FILE)
    return e


def dev_label(mac, ip=""):
    n = devices().get((mac or "").lower(), {}).get("name")
    return "%s (%s)" % (n, ip or mac) if n else (ip or mac)


# ----------------------------------------------------------------------------------------------
# client certificate expiry
# ----------------------------------------------------------------------------------------------
def cert_info():
    path = os.path.join(CERTS, "client.pem")
    if not os.path.exists(path):
        return {}
    try:
        d = ssl._ssl._test_decode_cert(path)
        exp = ssl.cert_time_to_seconds(d["notAfter"])
        subj = ", ".join("%s=%s" % kv for rdn in d.get("subject", ()) for kv in rdn)
        return {"subject": subj, "expires": exp, "days": int((exp - time.time()) // 86400),
                "issuer": ", ".join("%s=%s" % kv for rdn in d.get("issuer", ()) for kv in rdn)}
    except Exception as e:
        return {"error": str(e)}


def cert_check():
    c = cert_info()
    with SL:
        S["cert"] = c
    if "days" not in c:
        return
    day = time.strftime("%Y-%m-%d")
    if c["days"] < 0:
        raise_alert("cert", "critical", "Client certificate expired",
                    "Expired %s - TurtleTAK cannot connect until it is renewed (Setup > Enroll)" %
                    time.strftime("%Y-%m-%d", time.localtime(c["expires"])), marker=False, key="certexp:" + day)
    elif c["days"] <= cfgi("CERT_WARN_DAYS", 30):
        raise_alert("cert", "warning", "Client certificate expires in %d days" % c["days"],
                    "Expires %s - renew it (Setup > Enroll, or a new certificate)" %
                    time.strftime("%Y-%m-%d", time.localtime(c["expires"])), marker=False, key="certwarn:" + day)


# ----------------------------------------------------------------------------------------------
# system status, interfaces
# ----------------------------------------------------------------------------------------------

def _ioctl_addr(name, req):
    import fcntl
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        r = fcntl.ioctl(s.fileno(), req, struct.pack("256s", name[:15].encode()))
        return socket.inet_ntoa(r[20:24])
    finally:
        s.close()


def ipv4_addrs():
    """iface -> [cidr]. `ip` when present, else ioctl (primary address only)."""
    out = {}
    if have("ip"):
        for line in run(["ip", "-o", "-4", "addr", "show"]).splitlines():
            m = re.match(r"\d+:\s+(\S+)\s+inet\s+(\S+)", line)
            if m:
                out.setdefault(m.group(1), []).append(m.group(2))
        return out
    for n in (os.listdir("/sys/class/net") if os.path.isdir("/sys/class/net") else []):
        try:
            a = _ioctl_addr(n, 0x8915)
            mask = _ioctl_addr(n, 0x891B)
            out[n] = ["%s/%d" % (a, ipaddress.ip_network("0.0.0.0/%s" % mask).prefixlen)]
        except OSError:
            pass
    return out


def routes():
    """[(iface, dest_cidr, gateway)] from /proc/net/route."""
    out = []
    for line in rd("/proc/net/route").splitlines()[1:]:
        f = line.split()
        if len(f) < 8:
            continue
        h = lambda v: socket.inet_ntoa(struct.pack("<I", int(v, 16)))
        out.append((f[0], "%s/%d" % (h(f[1]), ipaddress.ip_network("0.0.0.0/%s" % h(f[7])).prefixlen), h(f[2])))
    return out


def neighbors(dev=None):
    """[(ip, mac, iface)] from /proc/net/arp (complete entries only)."""
    out = []
    for line in rd("/proc/net/arp").splitlines()[1:]:
        f = line.split()
        if len(f) >= 6 and int(f[2], 16) & 2 and f[3] != "00:00:00:00:00:00" and (dev is None or f[5] == dev):
            out.append((f[0], f[3].lower(), f[5]))
    return out


def ifaces():
    """name -> {ipv4: [cidr], mac, carrier, kind}"""
    out = {n: {"ipv4": a} for n, a in ipv4_addrs().items()}
    base = "/sys/class/net"
    for n in (os.listdir(base) if os.path.isdir(base) else []):
        d = out.setdefault(n, {"ipv4": []})
        d["mac"] = rd("%s/%s/address" % (base, n))
        d["carrier"] = rd("%s/%s/carrier" % (base, n)) == "1"
        d["oper"] = rd("%s/%s/operstate" % (base, n))
        d["wireless"] = os.path.isdir("%s/%s/wireless" % (base, n)) or os.path.isdir("%s/%s/phy80211" % (base, n))
        d["bridge"] = os.path.isdir("%s/%s/bridge" % (base, n))
        d["usb"] = "usb" in os.path.realpath("%s/%s/device" % (base, n)) if os.path.exists("%s/%s/device" % (base, n)) else False
    return out


def rd(p):
    try:
        return open(p).read().strip()
    except OSError:
        return ""


def default_route(dev=None):
    for n, dest, gw in routes():
        if dest == "0.0.0.0/0" and gw != "0.0.0.0" and (dev is None or n == dev):
            return gw, n
    return None, None


def rj45_iface(ifs=None):
    w = cfg("WATCH_IFACE", "auto")
    if w and w != "auto":
        return w
    ifs = ifs or ifaces()
    # The Hub's RJ45 is its "WAN" (WAN_IPCONFIG). Prefer an Ethernet with carrier and an IPv4 address that
    # is not the USB-C target side (172.16.84.0/24 by default) and not Wi-Fi / VPN / bridge.
    cands = []
    for n, d in ifs.items():
        if n == "lo" or d.get("wireless") or n.startswith(("wg", "tun", "nb", "wt", "br-", "docker")):
            continue
        if any(c.startswith("172.16.84.") for c in d.get("ipv4", [])):
            continue
        score = (2 if d.get("ipv4") else 0) + (1 if d.get("carrier") else 0) + (1 if n.startswith(("eth", "wan")) else 0)
        cands.append((score, n))
    gw, dev = default_route()
    if dev and dev in ifs and not ifs[dev].get("wireless") and not dev.startswith(("wg", "tun")):
        return dev
    return max(cands)[1] if cands else None


def status_collect():
    ifs = ifaces()
    gw, dev = default_route()
    rj = rj45_iface(ifs)
    wifi = [n for n, d in ifs.items() if d.get("wireless") and d.get("ipv4")]
    wg = run(["wg", "show", "interfaces"]).split() if have("wg") else []
    wg_hs = ""
    if wg:
        hs = run(["wg", "show", wg[0], "latest-handshakes"]).split()
        if len(hs) >= 2 and hs[1].isdigit() and int(hs[1]):
            wg_hs = dur(time.time() - int(hs[1])) + " ago"
    up = float((rd("/proc/uptime") or "0").split()[0])
    mem = {}
    for line in rd("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        mem[k] = int(v.split()[0]) if v.split() else 0
    leases = len([l for l in rd("/tmp/dhcp.leases").splitlines() if l.strip()])
    nb = ""
    if have("netbird"):
        nb = "connected" if "Management: Connected" in run(["netbird", "status"], 8) else "not connected"
    osname = ""
    for line in rd("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            osname = line.split("=", 1)[1].strip('"')
    st = {
        "uplink": dev or "none", "gateway": gw or "", "rj45": rj or "", "rj45_ip": ",".join(ifs.get(rj, {}).get("ipv4", [])) if rj else "",
        "rj45_link": bool(ifs.get(rj, {}).get("carrier")) if rj else False,
        "wifi_client": ",".join("%s %s" % (n, ifs[n]["ipv4"][0]) for n in wifi),
        "vpn": ("WireGuard %s%s" % (wg[0], (", handshake " + wg_hs) if wg_hs else "")) if wg else "",
        "netbird": nb, "uptime": up, "mem_free_kb": mem.get("MemAvailable", mem.get("MemFree", 0)),
        "mem_total_kb": mem.get("MemTotal", 0), "load": (rd("/proc/loadavg") or "0").split()[0],
        "target_leases": leases, "os": osname or "Linux", "public_ip": S["status"].get("public_ip", ""),
        "isp": S["status"].get("isp", ""), "ifaces": {n: {k: d.get(k) for k in ("ipv4", "mac", "carrier", "wireless", "usb")}
                                                      for n, d in ifs.items() if n != "lo"},
        "dns": DNS_CACHE.get(cfg("TAK_HOST"), ""),
        "tools": {t: have(t) for t in ("openssl", "nmap", "wg", "netbird", "arping", "tcpdump", "stty")},
        "python": sys.version.split()[0],
    }
    with SL:
        S["status"] = st
    return st


def status_text():
    st = S["status"]
    p = S["pos"]
    n = S["net"]
    parts = ["%s %s %s" % (PRODUCT, EDITION, VERSION),
             "Uplink: %s%s" % (st.get("uplink", "?"), (" via " + st["gateway"]) if st.get("gateway") else ""),
             "RJ45: %s %s" % ("link" if st.get("rj45_link") else "NO LINK", st.get("rj45_ip", "")),
             ]
    if st.get("wifi_client"):
        parts.append("Wi-Fi: " + st["wifi_client"])
    if st.get("vpn"):
        parts.append("VPN: " + st["vpn"])
    if st.get("netbird"):
        parts.append("NetBird: " + st["netbird"])
    if st.get("public_ip"):
        parts.append("Public IP: %s %s" % (st["public_ip"], st.get("isp", "")))
    if cfgb("WATCH"):
        parts.append("Watch: %s devices (%s new), last sweep %s" % (
            n.get("count", 0), n.get("new", 0), (dur(time.time() - n["last_sweep"]) + " ago") if n.get("last_sweep") else "pending"))
    if cfgb("BRIDGE_UP") or cfgb("BRIDGE_DOWN"):
        b = S["bridge"]
        parts.append("Mesh bridge: %d devices, %d up / %d down" % (len(b["devices"]), b["up_tx"], b["down_tx"]))
    parts.append("Location: %s, +/- %s m" % (p["src"], int(p["ce"]) if p["ce"] < 9999999 else "?"))
    parts.append("Up %s, load %s, %d MB free" % (dur(st.get("uptime", 0)), st.get("load", "?"), st.get("mem_free_kb", 0) // 1024))
    return "\n".join(parts)


def dur(s):
    s = int(max(0, s))
    if s < 90:
        return "%ds" % s
    if s < 5400:
        return "%dm" % (s // 60)
    if s < 172800:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    return "%dd%02dh" % (s // 86400, (s % 86400) // 3600)


def fmt_ll(lat, lon):
    return "unknown" if lat is None else "%.5f, %.5f" % (lat, lon)


# ----------------------------------------------------------------------------------------------
# location
# ----------------------------------------------------------------------------------------------
def sites():
    out = []
    for line in (open(SITES).read().splitlines() if os.path.exists(SITES) else []):
        p = line.split("|")
        if len(p) >= 3:
            try:
                out.append({"name": p[0], "lat": float(p[1]), "lon": float(p[2])})
            except ValueError:
                pass
    return out


def save_site(name, lat, lon):
    rows = [s for s in sites() if s["name"] != name] + [{"name": name, "lat": lat, "lon": lon}]
    with open(SITES, "w") as fh:
        fh.write("".join("%s|%.7f|%.7f\n" % (s["name"].replace("|", "/"), s["lat"], s["lon"]) for s in rows))


IPGEO = {"t": 0, "lat": None, "lon": None}


def ipgeo():
    if time.time() - IPGEO["t"] < 3600:
        return IPGEO
    IPGEO["t"] = time.time()
    try:
        with urllib.request.urlopen(cfg("IPGEO_URL"), timeout=10) as r:
            d = json.loads(r.read().decode())
        if "loc" in d:
            IPGEO["lat"], IPGEO["lon"] = [float(v) for v in d["loc"].split(",")]
        elif "lat" in d:
            IPGEO["lat"], IPGEO["lon"] = float(d["lat"]), float(d.get("lon", d.get("lng")))
        with SL:
            S["status"]["public_ip"] = d.get("ip") or d.get("query", "")
            S["status"]["isp"] = d.get("org") or d.get("isp", "")
    except Exception as e:
        log("IP geolocation failed: %s" % e, "debug")
    return IPGEO


def locate():
    mode = cfg("LOC_MODE", "auto").lower()
    order = ["gps", "atak", "site", "manual", "ip"] if mode == "auto" else [mode]
    for m in order:
        r = None
        if m == "gps":
            g = S["gps"]
            if g["fix"] and time.time() - g["time"] < 30:
                r = (g["lat"], g["lon"], g.get("ce", 10), g.get("hae", 0))
        elif m == "atak" and cfg("MY_ATAK"):
            with SL:
                for c in S["contacts"].values():
                    if c["callsign"] == cfg("MY_ATAK") and time.time() - c["time"] < cfgi("ANCHOR_MAX_AGE", 1800):
                        r = (c["lat"], c["lon"], max(10, c["ce"] if c["ce"] < 9999999 else 10), 0)
        elif m == "site" and cfg("SITE"):
            for s in sites():
                if s["name"] == cfg("SITE"):
                    r = (s["lat"], s["lon"], 10, 0)
        elif m == "manual" and cfg("MANUAL_LAT") and cfg("MANUAL_LON"):
            try:
                r = (float(cfg("MANUAL_LAT")), float(cfg("MANUAL_LON")), 10, 0)
            except ValueError:
                pass
        elif m == "ip" and cfgb("IPGEO"):
            g = ipgeo()
            if g["lat"] is not None:
                r = (g["lat"], g["lon"], 25000, 0)
        if r:
            with SL:
                changed = S["pos"]["src"] != m
                S["pos"] = {"lat": r[0], "lon": r[1], "ce": r[2], "hae": r[3], "src": m, "time": time.time()}
            if changed:
                log("location from %s: %s" % (m, fmt_ll(r[0], r[1])))
                save_state()
            return
    if cfgb("IPGEO"):
        ipgeo()     # still fill in the public IP for the status


class Gps:
    def run(self):
        claimed = False
        while True:
            dev = cfg("GPS_DEVICE", "auto")
            if dev == "off":
                time.sleep(30)
                continue
            if cfgb("GPS_CLAIM_USB") and not claimed:
                hub("USB_CLAIM_DEVICE")
                hub("USB_POWER_ON")
                claimed = True
            if dev == "auto":
                cands = sorted(p for p in ("/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyUSB0", "/dev/ttyUSB1") if os.path.exists(p))
                dev = cands[0] if cands else ""
            if not dev or not os.path.exists(dev):
                with SL:
                    S["gps"].update({"device": "", "fix": False})
                time.sleep(15)
                continue
            try:
                if have("stty"):
                    run(["stty", "-F", dev, cfg("GPS_BAUD", "9600"), "raw", "-echo"], 5)
                with SL:
                    S["gps"]["device"] = dev
                self.read(dev)
            except Exception as e:
                log("GPS %s: %s" % (dev, e), "debug")
            time.sleep(5)

    def read(self, dev):
        fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
        buf = b""
        last = time.time()
        try:
            while True:
                r, _, _ = select.select([fd], [], [], 5)
                if not r:
                    if time.time() - last > 20:
                        raise RuntimeError("no data")
                    continue
                chunk = os.read(fd, 4096)
                if not chunk:
                    raise RuntimeError("closed")
                last = time.time()
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self.nmea(line.decode("ascii", "replace").strip())
                buf = buf[-2048:]
        finally:
            os.close(fd)

    @staticmethod
    def dm(v, h):
        if not v:
            return None
        d = float(v)
        deg = int(d / 100)
        val = deg + (d - deg * 100) / 60
        return -val if h in ("S", "W") else val

    def nmea(self, line):
        if not line.startswith("$") or "*" not in line:
            return
        body, _, cks = line[1:].partition("*")
        c = 0
        for ch in body:
            c ^= ord(ch)
        if cks[:2].upper() != "%02X" % c:
            return
        f = body.split(",")
        t = f[0][2:]
        with SL:
            g = S["gps"]
            if t == "GGA" and len(f) > 9:
                q = int(f[6] or 0)
                g["sats"] = int(f[7] or 0)
                if q > 0 and f[2]:
                    hdop = float(f[8] or 2)
                    g.update({"lat": self.dm(f[2], f[3]), "lon": self.dm(f[4], f[5]), "hae": float(f[9] or 0),
                              "ce": max(3, round(hdop * 5)), "fix": True, "time": time.time()})
                else:
                    g["fix"] = False
            elif t == "RMC" and len(f) > 6:
                if f[2] == "A" and f[3]:
                    g.update({"lat": self.dm(f[3], f[4]), "lon": self.dm(f[5], f[6]), "fix": True, "time": time.time()})
                    g.setdefault("ce", 10)
                else:
                    g["fix"] = False


# ----------------------------------------------------------------------------------------------
# network watch: device sweep + baseline, ARP spoofing, rogue DHCP, link tamper
# ----------------------------------------------------------------------------------------------
class Watch:
    def __init__(self):
        self.kick = threading.Event()
        self.dhcp_kick = threading.Event()
        self.baseline = None
        self.key = None

    def sweep(self):
        ifn = rj45_iface()
        ifs = ifaces()
        if not ifn or ifn not in ifs or not ifs[ifn].get("ipv4"):
            with SL:
                S["net"].update({"iface": ifn or "", "state": "no IPv4 address on the RJ45 side", "last_try": time.time()})
            return
        cidr = ifs[ifn]["ipv4"][0]
        net = ipaddress.ip_interface(cidr).network
        my_ip = cidr.split("/")[0]
        if net.num_addresses > cfgi("WATCH_MAX_HOSTS", 256):
            net = ipaddress.ip_interface("%s/24" % my_ip).network
        gw, _ = default_route(ifn)
        with SL:
            S["net"].update({"iface": ifn, "subnet": str(net), "state": "sweeping", "my_ip": my_ip, "gateway": gw or ""})
        t0 = time.time()
        found = {}
        if have("nmap"):
            out = run(["nmap", "-sn", "-n", "-T3", "--max-rate", str(cfgi("WATCH_RATE", 50)), "-e", ifn, "-oX", "-", str(net)],
                      timeout=600)
            for h in re.findall(r"<host>.*?</host>", out, re.S):
                ip = re.search(r'addr="([\d.]+)" addrtype="ipv4"', h)
                mac = re.search(r'addr="([0-9A-Fa-f:]{17})" addrtype="mac"(?: vendor="([^"]*)")?', h)
                if ip and mac:
                    found[mac.group(1).lower()] = {"ip": ip.group(1), "vendor": mac.group(2) or ""}
            method = "nmap"
        else:
            self.ping_sweep(net, my_ip)
            method = "ping"
        for ip, mac, _ in neighbors(ifn):
            if ipaddress.ip_address(ip) in net:
                found.setdefault(mac, {"ip": ip, "vendor": ""})
        self.compare(found, net, gw, method, time.time() - t0)

    def ping_sweep(self, net, my_ip):
        hosts = [str(h) for h in net.hosts() if str(h) != my_ip]
        sem = threading.Semaphore(24)

        def one(ip):
            with sem:
                run(["ping", "-c", "1", "-W", "1", ip], 3)
        th = [threading.Thread(target=one, args=(h,), daemon=True) for h in hosts]
        for t in th:
            t.start()
        for t in th:
            t.join(10)

    def pick_baseline(self, found, net, gw, gw_mac):
        """Baselines are per network: subnet + gateway IP + gateway MAC. Same subnet and gateway IP but a
        different gateway MAC is either another site (few devices in common -> its own baseline) or the
        same network with a spoofed gateway (most devices in common -> keep that baseline, alert)."""
        stem = "%s_%s" % (str(net).replace("/", "-"), gw or "nogw")
        key = "%s_%s" % (stem, (gw_mac or "nomac").replace(":", ""))
        if os.path.exists(os.path.join(BASELINES, key + ".json")):
            return key, None
        macs = set(found) - {gw_mac}
        best, best_overlap = None, 0.0
        for f in os.listdir(BASELINES):
            if f.startswith(stem + "_") and f.endswith(".json"):
                try:
                    b = json.load(open(os.path.join(BASELINES, f)))
                except Exception:
                    continue
                devs = set(b.get("devices", {})) - {b.get("gateway_mac")}
                if devs and macs:
                    ov = len(devs & macs) / float(min(len(devs), len(macs)))
                    if ov > best_overlap:
                        best, best_overlap = f[:-5], ov
        if best and best_overlap >= 0.5 and gw_mac:
            return best, best_overlap
        return key, None

    def compare(self, found, net, gw, method, took):
        gw_mac = next((m for m, d in found.items() if d["ip"] == gw), None) if gw else None
        key, overlap = self.pick_baseline(found, net, gw, gw_mac)
        path = os.path.join(BASELINES, key + ".json")
        if self.key != key:
            self.key = key
            self.baseline = json.load(open(path)) if os.path.exists(path) else None
        now = time.time()
        new = []
        if self.baseline is None and cfgb("AUTO_BASELINE"):
            self.baseline = {"network": str(net), "gateway": gw, "gateway_mac": gw_mac, "created": now,
                             "devices": {m: {"ip": d["ip"], "vendor": d["vendor"], "first": now} for m, d in found.items()}}
            json.dump(self.baseline, open(path, "w"), indent=1)
            log("baseline saved for %s: %d devices" % (net, len(found)))
            notify("info", "Network baseline saved for %s (%d devices)" % (net, len(found)))
        known = (self.baseline or {}).get("devices", {})
        with SL:
            hosts = S["hosts"] if S["net"].get("key") == key else {}
            for m, d in found.items():
                h = hosts.get(m) or {"first": now, "vendor": d["vendor"]}
                h.update({"ip": d["ip"], "last": now, "known": m in known, "vendor": d["vendor"] or h.get("vendor", "")})
                hosts[m] = h
                if self.baseline is not None and m not in known and not h.get("alerted"):
                    h["alerted"] = True
                    new.append((m, d))
            S["hosts"] = hosts
            S["net"].update({"key": key, "state": "ok", "count": len(found), "last_sweep": now, "method": method,
                             "took": round(took, 1), "new": len([1 for h in hosts.values() if not h["known"]]),
                             "baseline": bool(self.baseline), "baseline_count": len(known), "gateway_mac": gw_mac or ""})
        for m, d in new:
            raise_alert("new_device", "warning", "New device %s" % dev_label(m, d["ip"]),
                        "MAC %s%s on %s, not in the baseline" % (m, (" (%s)" % d["vendor"]) if d["vendor"] else "", net),
                        key="new:%s:%s" % (key, m))
        self.missing_check(found, known, hosts, key)
        if cfgb("ARP_WATCH"):
            self.arp_check(found, gw, gw_mac, net)
        save_state()

    def missing_check(self, found, known, hosts, key):
        """Watched devices (devices.json watch=true) that belong to this network and stopped answering."""
        after = max(1, cfgi("MISSING_AFTER", 2))
        miss = S["net"].setdefault("missing", {})
        for mac, meta in devices().items():
            if not meta.get("watch") or (mac not in known and mac not in hosts):
                continue
            ip = (hosts.get(mac) or known.get(mac) or {}).get("ip", "")
            if mac in found:
                if miss.get(mac, {}).get("alerted"):
                    raise_alert("missing", "info", "Device back: %s" % dev_label(mac, ip),
                                "Answering again after %s" % dur(time.time() - miss[mac]["since"]), key=None)
                miss.pop(mac, None)
                continue
            m = miss.setdefault(mac, {"count": 0, "since": (hosts.get(mac) or {}).get("last", time.time())})
            m["count"] += 1
            if m["count"] >= after and not m.get("alerted"):
                m["alerted"] = True
                last = hosts.get(mac, {}).get("last")
                raise_alert("missing", "critical", "Device missing: %s" % dev_label(mac, ip),
                            "Watched device %s has not answered for %d sweeps%s" % (
                                mac, m["count"], (" (last seen %s ago)" % dur(time.time() - last)) if last else ""),
                            key="missing:%s:%d" % (mac, int(m["since"])))

    def arp_check(self, found, gw, gw_mac, net):
        if gw and gw_mac:
            base_gw = (self.baseline or {}).get("gateway_mac")
            if base_gw and base_gw != gw_mac:
                raise_alert("arp", "critical", "Gateway MAC changed",
                            "Gateway %s now answers as %s (baseline %s) - possible ARP spoofing / MITM" % (gw, gw_mac, base_gw),
                            key="gwmac:%s:%s" % (gw, gw_mac))
        by_mac = {}
        for m, d in found.items():
            by_mac.setdefault(m, set()).add(d["ip"])
        # ip neigh can show one MAC on several IPs - the gateway's IP sharing a MAC with another host is the classic sign
        for ip, mac, _ in neighbors():
            if ipaddress.ip_address(ip) in net:
                by_mac.setdefault(mac, set()).add(ip)
        for m, ips in by_mac.items():
            if gw and gw in ips and len(ips) > 1:
                raise_alert("arp", "critical", "Duplicate gateway MAC",
                            "%s claims the gateway %s and %s - possible ARP spoofing" % (dev_label(m, m), gw, ", ".join(sorted(ips - {gw}))),
                            key="dup:%s" % m)

    def accept_all(self):
        if not self.key:
            return 0
        now = time.time()
        with SL:
            for m, h in S["hosts"].items():
                h["known"] = True
            devs = {m: {"ip": h["ip"], "vendor": h.get("vendor", ""), "first": h.get("first", now)} for m, h in S["hosts"].items()}
            gwm = S["net"].get("gateway_mac") or None
            S["net"]["new"] = 0
            S["net"]["baseline"] = True
            S["net"]["baseline_count"] = len(devs)
        b = self.baseline or {"network": S["net"].get("subnet"), "created": now}
        b["devices"] = devs
        b["gateway_mac"] = gwm or b.get("gateway_mac")
        self.baseline = b
        json.dump(b, open(os.path.join(BASELINES, self.key + ".json"), "w"), indent=1)
        log("baseline updated: %d devices" % len(devs))
        return len(devs)

    def run(self):
        time.sleep(20)
        while True:
            if cfgb("WATCH"):
                try:
                    self.sweep()
                except Exception as e:
                    log("network sweep: %s" % e, "warning")
                    traceback.print_exc()
            self.kick.wait(max(60, cfgi("WATCH_INTERVAL", 300)))
            self.kick.clear()

    # ---- rogue DHCP: DHCPDISCOVER from a random MAC (broadcast reply), never requests a lease
    def dhcp_probe(self, ifn, wait=6):
        xid = random.getrandbits(32)
        mac = bytes([0x02] + [random.getrandbits(8) for _ in range(5)])
        pkt = struct.pack("!BBBBIHH4s4s4s4s16s64s128s", 1, 1, 6, 0, xid, 0, 0x8000, b"\0" * 4, b"\0" * 4, b"\0" * 4,
                          b"\0" * 4, mac + b"\0" * 10, b"\0" * 64, b"\0" * 128)
        pkt += b"\x63\x82\x53\x63" + b"\x35\x01\x01" + b"\x37\x03\x01\x03\x06" + b"\xff"
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            s.setsockopt(socket.SOL_SOCKET, 25, (ifn + "\0").encode())  # SO_BINDTODEVICE
        except OSError:
            pass
        s.bind(("0.0.0.0", 68))
        servers = {}
        try:
            s.sendto(pkt, ("255.255.255.255", 67))
            end = time.time() + wait
            while time.time() < end:
                r, _, _ = select.select([s], [], [], max(0.1, end - time.time()))
                if not r:
                    break
                data, addr = s.recvfrom(4096)
                if len(data) < 240 or struct.unpack("!I", data[4:8])[0] != xid:
                    continue
                opts, i, sid, mtype = data[240:], 0, addr[0], 0
                while i < len(opts) and opts[i] != 255:
                    if opts[i] == 0:
                        i += 1
                        continue
                    o, ln = opts[i], opts[i + 1]
                    v = opts[i + 2:i + 2 + ln]
                    if o == 54 and ln == 4:
                        sid = socket.inet_ntoa(v)
                    if o == 53 and ln == 1:
                        mtype = v[0]
                    i += 2 + ln
                if mtype == 2:
                    servers[sid] = {"offer": socket.inet_ntoa(data[16:20]), "from": addr[0]}
        finally:
            s.close()
        return servers

    def dhcp_check(self):
        ifn = rj45_iface()
        if not ifn:
            return
        try:
            servers = self.dhcp_probe(ifn)
        except OSError as e:
            with SL:
                S["net"]["dhcp"] = "check failed: %s" % e
            log("DHCP check: %s" % e, "debug")
            return
        allowed = [a.strip() for a in cfg("DHCP_KNOWN").split(",") if a.strip()]
        with SL:
            learned = S["net"].setdefault("dhcp_known", [])
            if not allowed and not learned and len(servers) == 1:
                learned.append(next(iter(servers)))
                log("DHCP server learned: %s" % learned[0])
            ok = allowed or learned
            S["net"]["dhcp"] = ", ".join("%s (offered %s)" % (k, v["offer"]) for k, v in servers.items()) or "no answer"
            S["net"]["dhcp_time"] = time.time()
        rogue = [k for k in servers if ok and k not in ok]
        if len(servers) > 1 and not ok:
            rogue = list(servers)
        for r in rogue:
            raise_alert("dhcp", "critical", "Rogue DHCP server %s" % r,
                        "DHCP offer from %s (offered %s); known server(s): %s" % (r, servers[r]["offer"], ", ".join(ok) or "none"),
                        key="dhcp:%s" % r)
        save_state()

    def dhcp_run(self):
        time.sleep(45)
        while True:
            if cfgb("DHCP_WATCH"):
                try:
                    self.dhcp_check()
                except Exception as e:
                    log("DHCP check: %s" % e, "warning")
            self.dhcp_kick.wait(max(120, cfgi("DHCP_INTERVAL", 900)))
            self.dhcp_kick.clear()

    def link_run(self):
        last = None
        down_at = 0
        while True:
            time.sleep(2)
            ifn = rj45_iface()
            if not ifn:
                continue
            up = rd("/sys/class/net/%s/carrier" % ifn) == "1"
            if last is not None and up != last and cfgb("LINK_WATCH"):
                if not up:
                    down_at = time.time()
                    raise_alert("link", "warning", "RJ45 link lost",
                                "Ethernet link on %s went down - cable pulled or switch port off?" % ifn)
                else:
                    raise_alert("link", "info", "RJ45 link restored", "Ethernet on %s back after %s" % (ifn, dur(time.time() - down_at)))
                    self.kick.set()
            last = up


WATCH = Watch()


# ----------------------------------------------------------------------------------------------
# ATAK mesh SA bridge (multicast <-> TAK Server)
# ----------------------------------------------------------------------------------------------
class Bridge:
    def __init__(self):
        self.out = None
        self.last_up = {}
        self.lock = threading.Lock()

    def groups(self):
        out = []
        for k in ("BRIDGE_SA_GROUP", "BRIDGE_CHAT_GROUP"):
            g, _, p = cfg(k).partition(":")
            if g and p.isdigit():
                out.append((g, int(p)))
        return out

    def local_ips(self):
        want = [i.strip() for i in cfg("BRIDGE_IFACES", "auto").split(",") if i.strip()]
        ips = []
        for n, d in ifaces().items():
            if n == "lo" or n.startswith(("wg", "tun", "nb", "wt")):
                continue
            if want and want != ["auto"] and n not in want:
                continue
            for c in d.get("ipv4", []):
                ips.append((n, c.split("/")[0]))
        return ips

    def run(self):
        while True:
            if not (cfgb("BRIDGE_UP") or cfgb("BRIDGE_DOWN")):
                time.sleep(5)
                continue
            socks = []
            try:
                ips = self.local_ips()
                for g, p in self.groups():
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind(("", p))
                    for n, ip in ips:
                        try:
                            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(g) + socket.inet_aton(ip))
                        except OSError:
                            pass
                    socks.append((s, g, p))
                self.out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                self.out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
                self.out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
                with SL:
                    S["bridge"]["ifaces"] = ["%s %s" % i for i in ips]
                    S["bridge"]["error"] = ""
                log("mesh bridge on %s" % (", ".join("%s %s" % i for i in ips) or "no interfaces"))
                started = time.time()
                while (cfgb("BRIDGE_UP") or cfgb("BRIDGE_DOWN")) and time.time() - started < 300:
                    r, _, _ = select.select([s for s, _, _ in socks], [], [], 5)
                    for s in r:
                        data, addr = s.recvfrom(65535)
                        if addr[0] in [ip for _, ip in ips]:
                            continue
                        self.up(data, addr)
            except Exception as e:
                with SL:
                    S["bridge"]["error"] = str(e)
                log("mesh bridge: %s" % e, "warning")
                time.sleep(10)
            finally:
                for s, _, _ in socks:
                    s.close()
                if self.out:
                    self.out.close()
                    self.out = None
            # loop rebuilds every 5 minutes so new interfaces (Wi-Fi joins, DHCP) are picked up

    def up(self, data, addr):
        with SL:
            S["bridge"]["up_rx"] += 1
        try:
            if data[:1] == b"\xbf":
                xml = tak_proto_to_xml(data)
            else:
                xml = data.decode("utf-8", "replace")
                xml = xml[xml.find("<event"):] if "<event" in xml else None
        except Exception:
            xml = None
        if not xml:
            return
        uid = (re.search(r'<event[^>]*\suid="([^"]*)"', xml) or [None, ""])[1]
        ctype = (re.search(r'<event[^>]*\stype="([^"]*)"', xml) or [None, ""])[1]
        if not uid or uid == my_uid():
            return
        now = time.time()
        if TAK.recent_down.get(uid, 0) > now - 30:
            return   # our own repeat of server traffic
        cs = (tag(xml, "contact") or {}).get("callsign", "")
        with SL:
            dev = S["bridge"]["devices"].setdefault(uid, {"first": now})
            dev.update({"callsign": cs or dev.get("callsign", uid), "ip": addr[0], "last": now, "type": ctype})
        handle_event(xml, source="mesh")
        if not cfgb("BRIDGE_UP"):
            return
        if not ctype.startswith("b-t-f"):
            if now - self.last_up.get(uid, 0) < cfgi("BRIDGE_MIN_GAP", 5):
                return
            self.last_up[uid] = now
        if TAK.send(xml):
            with SL:
                S["bridge"]["up_tx"] += 1

    def down(self, xml, uid, ctype):
        if not self.out:
            return
        types = [t.strip() for t in cfg("BRIDGE_DOWN_TYPES").split(",") if t.strip()]
        if types and not any(ctype.startswith(t) for t in types):
            return
        with SL:
            if uid in S["bridge"]["devices"]:
                return  # it came from the mesh in the first place
        groups = self.groups()
        g = groups[1] if ctype.startswith("b-t-f") and len(groups) > 1 else groups[0]
        data = xml.encode("utf-8")
        TAK.recent_down[uid] = time.time()
        if len(TAK.recent_down) > 5000:
            cut = time.time() - 60
            TAK.recent_down = {k: v for k, v in TAK.recent_down.items() if v > cut}
        for n, ip in self.local_ips():
            try:
                self.out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
                self.out.sendto(data, g)
            except OSError:
                pass
        with SL:
            S["bridge"]["down_tx"] += 1


BRIDGE = Bridge()


# ----------------------------------------------------------------------------------------------
# uplinks (Hub Wi-Fi client, WireGuard)
# ----------------------------------------------------------------------------------------------
def uplinks_apply():
    msgs = []
    if cfg("WIFI_SSID"):
        rc, out = hub("WIFI_CONNECT", cfg("WIFI_COUNTRY", "US"), cfg("WIFI_SSID"), cfg("WIFI_ENC", "psk2"),
                      cfg("WIFI_KEY") or "NONE", "ANY", timeout=60)
        msgs.append("Wi-Fi %s: %s" % (cfg("WIFI_SSID"), "ok" if rc == 0 else "failed " + out[-120:]))
    if cfg("WG_CONF"):
        if os.path.exists(cfg("WG_CONF")):
            rc, out = hub("WIREGUARD_CONFIGURE", "enable", cfg("WG_CONF"), timeout=60)
            msgs.append("WireGuard: %s" % ("ok" if rc == 0 else "failed " + out[-120:]))
        else:
            msgs.append("WireGuard: %s not found" % cfg("WG_CONF"))
    for m in msgs:
        log(m)
    return msgs


# ----------------------------------------------------------------------------------------------
# periodic SA
# ----------------------------------------------------------------------------------------------
def sa_loop():
    while True:
        try:
            status_collect()
            locate()
            if TAK.connected():
                TAK.send(sa_event())
            led()
        except Exception as e:
            log("SA: %s" % e, "warning")
            traceback.print_exc()
        time.sleep(max(15, cfgi("SA_INTERVAL", 60)))


def housekeeping():
    last_cert = 0
    while True:
        time.sleep(15)
        scan_certs()
        if time.time() - last_cert > 3600:
            last_cert = time.time()
            cert_check()
        now = time.time()
        with SL:
            for k in [k for k, c in S["contacts"].items() if (c.get("stale") or c["time"] + 900) < now - 3600]:
                del S["contacts"][k]
            for k in [k for k, d in S["bridge"]["devices"].items() if d["last"] < now - 3600]:
                del S["bridge"]["devices"][k]
        led()


# ----------------------------------------------------------------------------------------------
# clone package (.turtletak): settings, certificates, sites, device names, baselines -> another Hub
# ----------------------------------------------------------------------------------------------
CLONE_SKIP = {"UID", "WEB_PASS_HASH", "CALLSIGN"}


def clone_export():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        with CFG_LOCK:
            cfgtxt = "".join("%s: %s\n" % (k, v) for k, v in CFG.items() if k not in CLONE_SKIP)
        z.writestr("default.cfg", cfgtxt)
        for f in ("client.pem", "ca.pem", "wg.conf"):
            fp = os.path.join(CERTS, f)
            if os.path.exists(fp):
                z.write(fp, "certs/" + f)
        for fp, arc in ((SITES, "sites.txt"), (DEVICES_FILE, "devices.json")):
            if os.path.exists(fp):
                z.write(fp, arc)
        for f in sorted(os.listdir(BASELINES)):
            if f.endswith(".json"):
                z.write(os.path.join(BASELINES, f), "baselines/" + f)
        z.writestr("turtletak-clone.json", json.dumps({"product": PRODUCT, "edition": EDITION, "version": VERSION,
                                                        "from": cfg("CALLSIGN"), "created": iso()}))
    log("clone package exported")
    return buf.getvalue()


def clone_import(data, callsign):
    callsign = (callsign or "").strip()
    if not re.match(r"^[A-Za-z0-9 _.-]{2,30}$", callsign):
        raise RuntimeError("give this Hub its own callsign (2-30 letters, numbers, - _ .)")
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
        meta = json.loads(z.read("turtletak-clone.json"))
    except Exception:
        raise RuntimeError("not a TurtleTAK clone package")
    names = z.namelist()
    if "certs/client.pem" in names or "certs/ca.pem" in names:
        save_cert_files(client=z.read("certs/client.pem").decode() if "certs/client.pem" in names else None,
                        ca=z.read("certs/ca.pem").decode() if "certs/ca.pem" in names else None, why="clone package")
    ch = {}
    for line in z.read("default.cfg").decode("utf-8", "replace").splitlines():
        if ":" in line and not line.startswith("#"):
            k, v = line.split(":", 1)
            if k.strip() not in CLONE_SKIP:
                ch[k.strip()] = v.strip()
    if "certs/wg.conf" in names:
        write_secret(os.path.join(CERTS, "wg.conf"), z.read("certs/wg.conf").decode())
        ch["WG_CONF"] = os.path.join(CERTS, "wg.conf")
    for arc, fp in (("sites.txt", SITES), ("devices.json", DEVICES_FILE)):
        if arc in names:
            with open(fp, "wb") as fh:
                fh.write(z.read(arc))
    for n in names:
        if n.startswith("baselines/") and n.endswith(".json") and "/" not in n[10:]:
            with open(os.path.join(BASELINES, os.path.basename(n)), "wb") as fh:
                fh.write(z.read(n))
    ch["CALLSIGN"] = callsign
    ch["UID"] = ""                     # a new UID is made for this Hub
    cfg_set(ch)
    my_uid()
    log("clone package from %s imported as %s" % (meta.get("from"), callsign))
    TAK.reconnect()
    threading.Thread(target=uplinks_apply, daemon=True).start()
    return "set up as %s from %s's clone package" % (callsign, meta.get("from", "?"))


# ----------------------------------------------------------------------------------------------
# site survey data package (MANIFEST v2) - sent to TAK like SharkTAKDisplay
# ----------------------------------------------------------------------------------------------
def survey_build():
    now = time.time()
    sid = uuid.uuid4().hex[:8]
    muid = "%s.survey.%s" % (my_uid(), sid)
    name = "%s-survey-%s" % (re.sub(r"[^A-Za-z0-9_-]", "_", cfg("CALLSIGN")), time.strftime("%Y%m%d-%H%M", time.localtime(now)))
    DEVS = devices()
    with SL:
        n = dict(S["net"])
        hosts = sorted(S["hosts"].items(), key=lambda kv: ipaddress.ip_address(kv[1]["ip"]))
        alerts = list(S["alerts"][-50:])
        p = dict(S["pos"])
    summary = ["%s site survey - %s" % (cfg("CALLSIGN"), time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(now))), "",
               status_text(), "",
               "Network: %s on %s, gateway %s %s" % (n.get("subnet", "?"), n.get("iface", "?"), n.get("gateway", ""), n.get("gateway_mac", "")),
               "Devices: %d seen, %d new (not in the baseline), baseline %d" % (len(hosts), n.get("new", 0), n.get("baseline_count", 0)),
               "DHCP servers: %s" % n.get("dhcp", "not checked"), ""]
    summary += ["%-15s %-17s %-6s %s" % (h["ip"], m, "known" if h.get("known") else "NEW",
                                          (DEVS.get(m, {}).get("name") or h.get("vendor") or "")) for m, h in hosts]
    csv = ["ip,mac,status,name,vendor,watched,first_seen,last_seen"]
    for m, h in hosts:
        nm = DEVS.get(m, {}).get("name", "").replace(",", " ")
        csv.append("%s,%s,%s,%s,%s,%s,%s,%s" % (h["ip"], m, "known" if h.get("known") else "new", nm, h.get("vendor", "").replace(",", " "),
                                                 "yes" if DEVS.get(m, {}).get("watch") else "", iso(h.get("first", now)), iso(h.get("last", now))))
    altxt = ["%s [%s] %s - %s" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(a["time"])), a["level"], a["title"], a["detail"]) for a in alerts]
    rem = "Site survey by %s\n%s devices (%s new) on %s\nSee the attached data package for the device list." % (
        cfg("CALLSIGN"), len(hosts), n.get("new", 0), n.get("subnet", "?"))
    marker = marker_event(muid, "b-m-p-s-m", "%s survey %s" % (cfg("CALLSIGN"), time.strftime("%m-%d %H:%M", time.localtime(now))),
                          rem, p["lat"], p["lon"], p["ce"], 7 * 86400)
    files = {"survey/summary.txt": "\n".join(summary) + "\n", "survey/devices.csv": "\n".join(csv) + "\n",
             "survey/alerts.txt": "\n".join(altxt) + "\n", "survey/survey.cot": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + marker}
    if WATCH.baseline:
        files["survey/baseline.json"] = json.dumps(WATCH.baseline, indent=1)
    manifest = ['<MissionPackageManifest version="2">', " <Configuration>",
                '  <Parameter name="uid" value="%s"/>' % uuid.uuid4(), '  <Parameter name="name" value="%s"/>' % x(name),
                '  <Parameter name="onReceiveDelete" value="false"/>', " </Configuration>", " <Contents>"]
    for f in sorted(files):
        manifest.append('  <Content ignore="false" zipEntry="%s"><Parameter name="uid" value="%s"/></Content>' % (f, muid))
    manifest += [" </Contents>", "</MissionPackageManifest>"]
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("MANIFEST/manifest.xml", "\n".join(manifest) + "\n")
        for f, t in sorted(files.items()):
            z.writestr(f, t)
    data = buf.getvalue()
    os.makedirs(LOOT, exist_ok=True)
    with open(os.path.join(LOOT, name + ".zip"), "wb") as fh:
        fh.write(data)
    return name + ".zip", data, marker


def marti_upload(name, data):
    """Upload a data package to the TAK Server (Marti API) -> download URL."""
    tls = cfg("TAK_PROTO") == "tls"
    base = "%s://%s:%s" % ("https" if tls else "http", cfg("TAK_HOST"), cfg("API_PORT", "8443" if tls else "8080"))
    ctx = None
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.load_cert_chain(os.path.join(CERTS, "client.pem"))
        ca = os.path.join(CERTS, "ca.pem")
        ctx.check_hostname = False
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.verify_mode = ssl.CERT_NONE
    h = hashlib.sha256(data).hexdigest()
    bnd = "----TurtleTAK" + uuid.uuid4().hex
    body = ("--%s\r\nContent-Disposition: form-data; name=\"assetfile\"; filename=\"%s\"\r\n"
            "Content-Type: application/x-zip-compressed\r\n\r\n" % (bnd, name)).encode() + data + ("\r\n--%s--\r\n" % bnd).encode()
    q = urllib.parse.urlencode({"hash": h, "filename": name, "creatorUid": my_uid()})
    req = urllib.request.Request("%s/Marti/sync/missionupload?%s" % (base, q), data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=" + bnd})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=120) as r:
            url = r.read().decode("utf-8", "replace").strip()
    except urllib.error.HTTPError as e:
        raise RuntimeError("TAK Server refused the upload: HTTP %d" % e.code)
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError("cannot reach the TAK Server API (%s): %s" % (base, getattr(e, "reason", e)))
    if not url.startswith("http"):
        url = "%s/Marti/sync/content?hash=%s" % (base, h)
    try:   # list it in the server's Data Packages
        urllib.request.urlopen(urllib.request.Request("%s/Marti/api/sync/metadata/%s/tool" % (base, h), data=b"public",
                                                      method="PUT", headers={"Content-Type": "text/plain"}), context=ctx, timeout=30).read()
    except Exception:
        pass
    return url, h


def survey_send(to):
    """to: '' = everyone, 'upload' = server only, or a callsign."""
    if to and to != "upload":
        with SL:
            if not any(c["callsign"] == to for c in S["contacts"].values()):
                raise RuntimeError("no TAK contact called %s" % to)
    name, data, marker = survey_build()
    url, h = marti_upload(name, data)
    TAK.send(marker, queue=True)
    if to == "upload":
        log("survey %s uploaded to the TAK Server" % name)
        return "%s uploaded to the TAK Server's data packages" % name
    dest, dest_uid = "", None
    if to:
        with SL:
            dest_uid = next((u for u, c in S["contacts"].items() if c["callsign"] == to), None)
        if not dest_uid:
            raise RuntimeError("no TAK contact called %s" % to)
        dest = '<marti><dest callsign="%s"/></marti>' % x(to)
    p = S["pos"]
    ev = (ev_open(str(uuid.uuid4()), "b-f-t-r", 600) + point_xml(p["lat"], p["lon"], p["ce"]) + "<detail>"
          + '<fileshare filename="%s" senderUrl="%s" sizeInBytes="%d" sha256="%s" senderUid="%s" senderCallsign="%s" name="%s"/>'
          % (x(name), x(url), len(data), h, x(my_uid()), x(cfg("CALLSIGN")), x(name[:-4]))
          + '<ackrequest uid="%s" ackrequested="true" tag="%s"/>%s</detail></event>' % (uuid.uuid4(), x(name[:-4]), dest))
    TAK.send(ev, queue=True)
    log("survey %s sent to %s" % (name, to or "everyone"))
    return "%s sent to %s" % (name, to or "everyone")


# ----------------------------------------------------------------------------------------------
# map tiles: cached on the Hub (USB storage when attached) so the web map works offline
# ----------------------------------------------------------------------------------------------
TILE_SOURCES = {
    "usgs_topo": ("USGS Topo", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}", 16, True),
    "usgs_imagery": ("USGS Imagery", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}", 16, True),
    "usgs_hybrid": ("USGS Imagery + Topo", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}", 16, True),
    "osm": ("OpenStreetMap (live only)", "https://tile.openstreetmap.org/{z}/{x}/{y}.png", 19, False),
}


class Tiles:
    def __init__(self):
        self.job = None
        self.lock = threading.Lock()
        self.size = None

    def root(self):
        for u in ("/usb", "/mnt/usb", "/mnt/sda1"):
            if os.path.ismount(u) and os.access(u, os.W_OK):
                return os.path.join(u, "turtletak-tiles")
        return os.path.join(BASE, "tiles")

    def path(self, src, z, x_, y):
        return os.path.join(self.root(), src, str(z), str(x_), "%d.tile" % y)

    def fetch(self, src, z, x_, y):
        name, url, maxz, _ = TILE_SOURCES[src]
        req = urllib.request.Request(url.format(z=z, x=x_, y=y), headers={"User-Agent": "TurtleTAK/%s (LAN Turtle Hub)" % VERSION})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = r.read()
        if len(data) < 64:
            raise ValueError("empty tile")
        fp = self.path(src, z, x_, y)
        if self.size is None or self.size < cfgi("TILE_CACHE_MB", 500) * 1048576:
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp + ".tmp", "wb") as fh:
                fh.write(data)
            os.replace(fp + ".tmp", fp)
            if self.size is not None:
                self.size += len(data)
        return data

    def get(self, src, z, x_, y):
        if src not in TILE_SOURCES or z > TILE_SOURCES[src][2]:
            return None
        fp = self.path(src, z, x_, y)
        if os.path.exists(fp):
            return open(fp, "rb").read()
        try:
            return self.fetch(src, z, x_, y)
        except Exception:
            return None

    def measure(self):
        total = n = 0
        for d, _, fs in os.walk(self.root()):
            for f in fs:
                total += os.path.getsize(os.path.join(d, f))
                n += 1
        self.size = total
        self.count = n
        return total

    @staticmethod
    def tile_range(s_, w, n, e, z):
        def xy(lat, lon):
            lat = max(-85.05, min(85.05, lat))
            k = 2 ** z
            xt = int((lon + 180) / 360 * k)
            yt = int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * k)
            return min(k - 1, max(0, xt)), min(k - 1, max(0, yt))
        x0, y0 = xy(n, w)
        x1, y1 = xy(s_, e)
        return x0, x1, y0, y1

    def plan(self, b, zmin, zmax):
        total = 0
        for z in range(zmin, zmax + 1):
            x0, x1, y0, y1 = self.tile_range(b["s"], b["w"], b["n"], b["e"], z)
            total += (x1 - x0 + 1) * (y1 - y0 + 1)
        return total

    def download(self, src, b, zmin, zmax):
        if src not in TILE_SOURCES or not TILE_SOURCES[src][3]:
            raise RuntimeError("%s can't be saved for offline use - pick a USGS map" % TILE_SOURCES.get(src, ("that map",))[0])
        zmax = min(zmax, TILE_SOURCES[src][2])
        n = self.plan(b, zmin, zmax)
        if n > cfgi("TILE_MAX_DOWNLOAD", 20000):
            raise RuntimeError("that is %d tiles - zoom in, or lower the top zoom (limit TILE_MAX_DOWNLOAD %s)" % (n, cfg("TILE_MAX_DOWNLOAD")))
        with self.lock:
            if self.job and self.job.get("running"):
                raise RuntimeError("a map download is already running")
            self.job = {"running": True, "total": n, "done": 0, "saved": 0, "failed": 0, "src": src, "started": time.time()}
        self.measure()
        threading.Thread(target=self._run, args=(src, b, zmin, zmax), daemon=True).start()
        return "saving %d tiles of %s for offline use" % (n, TILE_SOURCES[src][0])

    def _run(self, src, b, zmin, zmax):
        j = self.job
        try:
            for z in range(zmin, zmax + 1):
                x0, x1, y0, y1 = self.tile_range(b["s"], b["w"], b["n"], b["e"], z)
                for x_ in range(x0, x1 + 1):
                    for y in range(y0, y1 + 1):
                        if not j.get("running"):
                            return
                        if not os.path.exists(self.path(src, z, x_, y)):
                            if self.size is not None and self.size >= cfgi("TILE_CACHE_MB", 500) * 1048576:
                                j["error"] = "tile cache is full (TILE_CACHE_MB)"
                                return
                            try:
                                self.fetch(src, z, x_, y)
                                j["saved"] += 1
                            except Exception:
                                j["failed"] += 1
                            time.sleep(0.05)
                        j["done"] += 1
        finally:
            j["running"] = False
            j["finished"] = time.time()
            log("map download: %d saved, %d failed, %d already there" % (j["saved"], j["failed"], j["done"] - j["saved"] - j["failed"]))

    def clear(self):
        shutil.rmtree(self.root(), ignore_errors=True)
        self.size = 0
        return "tile cache cleared"

    def status(self):
        if self.size is None:
            threading.Thread(target=self.measure, daemon=True).start()
            self.size = 0
        return {"root": self.root(), "mb": round((self.size or 0) / 1048576.0, 1), "limit_mb": cfgi("TILE_CACHE_MB", 500),
                "job": self.job, "sources": {k: v[0] for k, v in TILE_SOURCES.items()}, "source": cfg("MAP_SOURCE", "usgs_topo"),
                "offline_ok": {k: v[3] for k, v in TILE_SOURCES.items()}}


TILES = Tiles()


# ----------------------------------------------------------------------------------------------
# web console
# ----------------------------------------------------------------------------------------------
SESSIONS = {}


def hash_pw(pw, salt=None):
    salt = salt or binascii.hexlify(os.urandom(8)).decode()
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 60000)
    return "pbkdf2$%s$%s" % (salt, binascii.hexlify(h).decode())


def check_pw(pw, stored):
    try:
        _, salt, h = stored.split("$")
        return hmac.compare_digest(hash_pw(pw, salt), stored)
    except ValueError:
        return False


def state_json():
    DEVS = devices()
    with SL:
        now = time.time()
        p = S["pos"]
        contacts = []
        for u, c in S["contacts"].items():
            d = dict(c, uid=u, age=int(now - c["time"]))
            if p["lat"] is not None:
                d["dist"], d["brg"] = dist_brg(p["lat"], p["lon"], c["lat"], c["lon"])
            contacts.append(d)
        contacts.sort(key=lambda c: c.get("dist", 0))
        out = {"version": VERSION, "edition": EDITION, "callsign": cfg("CALLSIGN"), "uid": my_uid(), "now": now,
               "uptime": now - S["started"], "tak": dict(S["tak"], host=cfg("TAK_HOST"), port=cfg("TAK_PORT"),
                                                         proto=cfg("TAK_PROTO"), queued=queue_len()),
               "pos": p, "gps": S["gps"], "status": S["status"], "contacts": contacts[:500],
               "chat": S["chat"][-150:], "alerts": S["alerts"][-100:][::-1], "net": {k: v for k, v in S["net"].items()},
               "hosts": sorted(({"mac": m, **h, "name": DEVS.get(m, {}).get("name", ""), "watch": DEVS.get(m, {}).get("watch", False),
                                 "missing": bool(S["net"].get("missing", {}).get(m, {}).get("alerted"))}
                                for m, h in S["hosts"].items()), key=lambda h: ipaddress.ip_address(h["ip"])),
               "devices": DEVS, "cert": S.get("cert", {}), "alert_kinds": ALERT_KINDS, "quiet": in_quiet_hours(),
               "tiles": TILES.status(),
               "bridge": {"up": cfgb("BRIDGE_UP"), "down": cfgb("BRIDGE_DOWN"), **{k: v for k, v in S["bridge"].items()}},
               "sites": sites(), "status_text": status_text(),
               "certs": {f: os.path.exists(os.path.join(CERTS, f)) for f in ("client.pem", "ca.pem")}}
    return json.dumps(out, default=str).encode()


def queue_len():
    try:
        return sum(1 for _ in open(QUEUE))
    except OSError:
        return 0


def dist_brg(a1, o1, a2, o2):
    r = 6371000.0
    p1, p2 = math.radians(a1), math.radians(a2)
    dp, dl = p2 - p1, math.radians(o2 - o1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * r * math.asin(min(1, math.sqrt(a)))
    b = math.degrees(math.atan2(math.sin(dl) * math.cos(p2), math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)))
    return round(d), round((b + 360) % 360)


SECRET_KEYS = {"WEB_PASS_HASH", "WIFI_KEY", "CLIENT_PASSWORD", "CA_PASSWORD"}


def action(a, d):
    if a == "chat":
        text = (d.get("text") or "").strip()[:1000]
        if not text:
            raise RuntimeError("empty message")
        ok = chat_send(text, d.get("to") or None)
        return "sent" if ok else "queued (TAK offline)"
    if a == "scan":
        WATCH.kick.set()
        return "sweep started"
    if a == "dhcp":
        WATCH.dhcp_check()
        return S["net"].get("dhcp", "")
    if a == "accept":
        return "baseline now %d devices" % WATCH.accept_all()
    if a == "clear_alerts":
        with SL:
            S["alerts"] = []
        save_state()
        return "cleared"
    if a == "test_alert":
        raise_alert("test", "warning", "Test alert", "This is a TurtleTAK test alert.", key=None)
        return "sent"
    if a == "reconnect":
        TAK.reconnect()
        return "reconnecting"
    if a == "send_sa":
        locate()
        return "sent" if TAK.send(sa_event()) else "TAK offline"
    if a == "set_pos":
        lat, lon = float(d["lat"]), float(d["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise RuntimeError("bad coordinates")
        ch = {"MANUAL_LAT": "%.7f" % lat, "MANUAL_LON": "%.7f" % lon}
        if d.get("site"):
            save_site(d["site"].strip()[:40], lat, lon)
            ch = {"SITE": d["site"].strip()[:40], "LOC_MODE": "site"}
        elif cfg("LOC_MODE") not in ("manual", "auto"):
            ch["LOC_MODE"] = "manual"
        cfg_set(ch)
        locate()
        TAK.send(sa_event())
        return "location set"
    if a == "uplinks":
        return "; ".join(uplinks_apply()) or "nothing configured"
    if a == "enroll":
        enroll(d.get("user", ""), d.get("password", ""))
        return "enrolled"
    if a == "set_password":
        pw = d.get("password", "")
        if len(pw) < 8:
            raise RuntimeError("use at least 8 characters")
        cfg_set({"WEB_PASS_HASH": hash_pw(pw)})
        return "password changed"
    if a == "set_device":
        e = set_device(d.get("mac", ""), d.get("name"), d.get("watch"))
        return "saved %s" % (e.get("name") or d.get("mac"))
    if a == "send_survey":
        return survey_send((d.get("to") or "").strip())
    if a == "tiles_download":
        b = {k: float(d["bounds"][k]) for k in ("s", "w", "n", "e")}
        return TILES.download(d.get("src") or cfg("MAP_SOURCE"), b, int(d.get("zmin", 1)), int(d.get("zmax", 15)))
    if a == "tiles_plan":
        b = {k: float(d["bounds"][k]) for k in ("s", "w", "n", "e")}
        src = d.get("src") or cfg("MAP_SOURCE")
        return "%d tiles" % TILES.plan(b, int(d.get("zmin", 1)), min(int(d.get("zmax", 15)), TILE_SOURCES.get(src, ("", "", 16))[2]))
    if a == "tiles_stop":
        if TILES.job:
            TILES.job["running"] = False
        return "stopping"
    if a == "tiles_clear":
        return TILES.clear()
    if a == "restore_certs":
        return restore_certs()
    if a == "diagnose":
        return "\n".join(diagnose())
    if a == "install_openssl":
        for mgr, cmd in (("opkg", "opkg update && opkg install openssl-util"), ("apk", "apk update && apk add openssl")):
            if have(mgr):
                p = subprocess.run(["sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
                out = p.stdout.decode("utf-8", "replace")
                log("%s: %s" % (cmd, out[-300:]))
                return "openssl installed" if have("openssl") else "install failed: %s" % out.strip()[-160:]
        return "no package manager (opkg/apk) found - openssl is optional, TurtleTAK works without it"
    if a == "boot":
        rc, out = hub("BOOT_PAYLOAD", "enable" if d.get("on") else "disable")
        cfg_set({"RUN_AT_BOOT": "1" if d.get("on") else "0"})
        return "run at boot %s" % ("on" if d.get("on") else "off")
    raise RuntimeError("unknown action")


def diagnose():
    """Step-by-step TAK connection check for the Setup page."""
    host, port, proto = cfg("TAK_HOST"), cfgi("TAK_PORT", 8089), cfg("TAK_PROTO", "tls").lower()
    out = ["Server: %s:%d (%s)" % (host, port, proto)]
    out.append("DNS servers: %s" % (", ".join(re.findall(r"^nameserver\s+(\S+)", rd("/etc/resolv.conf"), re.M)) or "none in /etc/resolv.conf"))
    try:
        socket.inet_aton(host)
        ips = [host]
        out.append("1. DNS: %s is an IP address - no lookup needed" % host)
    except OSError:
        detail = []
        for fam, name in ((socket.AF_UNSPEC, "any"), (socket.AF_INET, "IPv4"), (socket.AF_INET6, "IPv6")):
            try:
                r = _getaddrinfo(host, port, fam, socket.SOCK_STREAM)
                detail.append("%s ok (%s)" % (name, r[0][4][0]))
            except socket.gaierror as e:
                detail.append("%s failed (%s)" % (name, e.strerror or e))
        ns = _nslookup(host)
        detail.append("nslookup %s" % (ns[0] if ns else "failed"))
        try:
            ips = [ai[4][0] for ai in socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)]
            out.append("1. DNS: OK -> %s  [%s]" % (ips[0], "; ".join(detail)))
        except socket.gaierror as e:
            out.append("1. DNS: FAILED - %s  [%s]. Check the server name's spelling first, then try the server's IP address, or set SYSTEM_DNS on the Hub." % (e, "; ".join(detail)))
            return out
    if proto == "udp":
        out.append("2. UDP: send-only, nothing to test")
        return out
    try:
        t0 = time.time()
        raw = socket.create_connection((host, port), timeout=10)
        out.append("2. TCP %d: OK (%d ms, from %s)" % (port, (time.time() - t0) * 1000, raw.getsockname()[0]))
    except OSError as e:
        out.append("2. TCP %d: FAILED - %s. Check the port, a firewall, or the route (VPN?)." % (port, e))
        return out
    if proto != "tls":
        raw.close()
        out.append("3. TLS: not used (tcp)")
        return out
    client, ca = os.path.join(CERTS, "client.pem"), os.path.join(CERTS, "ca.pem")
    if not os.path.exists(client):
        raw.close()
        out.append("3. TLS: no client certificate loaded")
        return out
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        try:
            ctx.load_cert_chain(client)
            out.append("3a. Client certificate file: OK (%s)" % pem_summary(client))
        except (ssl.SSLError, OSError) as e:
            out.append("3a. Client certificate file: BROKEN - %s (%s). Re-import it, or Restore previous certificates." % (e, pem_summary(client)))
            raw.close()
            return out
        if os.path.exists(ca):
            try:
                ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(ca)
                out.append("3b. Truststore file: OK (%s)" % pem_summary(ca))
            except (ssl.SSLError, OSError) as e:
                out.append("3b. Truststore file: BROKEN - %s (%s). Re-import it, or Restore previous certificates." % (e, pem_summary(ca)))
                raw.close()
                return out
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.check_hostname = cfgb("TAK_VERIFY_HOST")
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(raw, server_hostname=host)
        peer = s.getpeercert(binary_form=False) or {}
        subj = ", ".join("%s=%s" % kv for rdn in peer.get("subject", ()) for kv in rdn)
        out.append("3. TLS: OK (%s, server cert %s%s)" % (s.version(), subj or "not checked", "" if os.path.exists(ca) else ", truststore not loaded"))
        s.settimeout(3)
        try:
            data = s.recv(4096)
            out.append("4. Server accepted the client certificate%s" % (" and sent data" if data else ""))
        except socket.timeout:
            out.append("4. Server accepted the client certificate (connection held open)")
        except (ssl.SSLError, OSError) as e:
            out.append("4. Server REJECTED the client certificate: %s (wrong CA / revoked / not enrolled?)" % e)
        s.close()
    except ssl.SSLCertVerificationError as e:
        out.append("3. TLS: server certificate NOT trusted by the truststore - %s (wrong truststore, or turn TAK_VERIFY_HOST off)" % e.verify_message)
    except (ssl.SSLError, OSError) as e:
        out.append("3. TLS: FAILED - %s" % e)
    return out


class Web(BaseHTTPRequestHandler):
    server_version = "TurtleTAK"
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if not any(k == "Cache-Control" for k, _ in extra):
            self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def session(self):
        m = re.search(r"tt_session=([0-9a-f]{32})", self.headers.get("Cookie", ""))
        s = m and SESSIONS.get(m.group(1))
        return bool(s and s > time.time())

    def body(self, limit=64 * 1024):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise RuntimeError("too large")
        return self.rfile.read(n)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send(200, open(os.path.join(APP, "index.html"), "rb").read(), "text/html; charset=utf-8")
        if path == "/api/state":
            if not self.session():
                return self.send(401, b'{"login":true}')
            return self.send(200, state_json())
        if path == "/api/cfg":
            if not self.session():
                return self.send(401, b'{"login":true}')
            with CFG_LOCK:
                c = [{"key": k, "value": ("" if k in SECRET_KEYS and CFG.get(k) else CFG.get(k, v)) if v is not None else None,
                      "set": bool(CFG.get(k)), "secret": k in SECRET_KEYS, "section": v is None} for k, v in DEFAULTS]
            return self.send(200, json.dumps(c).encode())
        if path.startswith("/static/") and re.match(r"^/static/[a-z0-9_.-]+$", path):
            fp = os.path.join(APP, "static", path[8:])
            if os.path.exists(fp):
                ctype = "text/css" if fp.endswith(".css") else "application/javascript"
                return self.send(200, open(fp, "rb").read(), ctype, extra=[("Cache-Control", "max-age=86400")])
            return self.send(404, b"")
        m = re.match(r"^/tiles/([a-z_]+)/(\d+)/(\d+)/(\d+)$", path)
        if m:
            if not self.session():
                return self.send(401, b"")
            data = TILES.get(m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)))
            if data is None:
                return self.send(404, b"")
            ctype = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
            return self.send(200, data, ctype)
        if path in ("/api/export", "/api/survey"):
            if not self.session():
                return self.send(401, b'{"login":true}')
            if path == "/api/export":
                body, fname = clone_export(), "%s.turtletak" % re.sub(r"[^A-Za-z0-9_-]", "_", cfg("CALLSIGN"))
            else:
                fname, body, _ = survey_build()
            return self.send(200, body, "application/octet-stream",
                             extra=[("Content-Disposition", 'attachment; filename="%s"' % fname)])
        if path == "/api/log":
            if not self.session():
                return self.send(401, b'{"login":true}')
            with LOG_LOCK:
                return self.send(200, "\n".join(LOGQ[-250:]).encode(), "text/plain; charset=utf-8")
        self.send(404, b'{"error":"not found"}')

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            if path == "/api/login":
                d = json.loads(self.body() or b"{}")
                time.sleep(0.5)
                if check_pw(d.get("password", ""), cfg("WEB_PASS_HASH")):
                    sid = binascii.hexlify(os.urandom(16)).decode()
                    SESSIONS[sid] = time.time() + 12 * 3600
                    return self.send(200, b'{"ok":true}', extra=[("Set-Cookie", "tt_session=%s; HttpOnly; SameSite=Strict; Path=/" % sid)])
                log("web login failed from %s" % self.client_address[0], "warning")
                return self.send(403, b'{"error":"wrong password"}')
            if not self.session():
                return self.send(401, b'{"login":true}')
            if self.headers.get("X-TT") != "1":
                return self.send(403, b'{"error":"missing header"}')
            if path == "/api/logout":
                m = re.search(r"tt_session=([0-9a-f]{32})", self.headers.get("Cookie", ""))
                if m:
                    SESSIONS.pop(m.group(1), None)
                return self.send(200, b'{"ok":true}')
            if path == "/api/action":
                d = json.loads(self.body() or b"{}")
                return self.send(200, json.dumps({"ok": True, "msg": action(d.get("action"), d)}).encode())
            if path == "/api/cfg":
                d = json.loads(self.body() or b"{}")
                known = {k for k, v in DEFAULTS if v is not None} - {"WEB_PASS_HASH", "UID"}
                ch = {k: v for k, v in d.items() if k in known and not (k in SECRET_KEYS and v == "")}
                cfg_set(ch)
                if set(ch) & {"TAK_HOST", "TAK_PORT", "TAK_PROTO", "TAK_VERIFY_HOST"}:
                    TAK.reconnect()
                if set(ch) & {"WIFI_SSID", "WIFI_KEY", "WIFI_ENC", "WG_CONF"}:
                    threading.Thread(target=uplinks_apply, daemon=True).start()
                if "LED" in ch:
                    LED_STATE["shown"] = None
                    led()
                log("settings changed in the web console: %s" % ", ".join(sorted(ch)))
                return self.send(200, json.dumps({"ok": True, "msg": "saved %d setting(s)" % len(ch)}).encode())
            if path == "/api/upload":
                name = os.path.basename(self.headers.get("X-Filename", "upload.bin"))
                name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:80]
                if name.lower().endswith(".turtletak"):
                    data = self.body(limit=64 * 1024 * 1024)
                    msg = clone_import(data, urllib.parse.unquote(self.headers.get("X-Callsign") or ""))
                    return self.send(200, json.dumps({"ok": True, "msg": msg}).encode())
                if not name.lower().endswith((".zip", ".p12", ".pfx", ".pem", ".key", ".conf")):
                    raise RuntimeError("upload a .zip connection package, .p12, .pem, .key, wg .conf or .turtletak clone")
                data = self.body(limit=8 * 1024 * 1024)
                dest = os.path.join(CERTS, name)
                if name.lower().endswith(".conf"):
                    dest = os.path.join(CERTS, "wg.conf")
                fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
                msg = "saved %s" % os.path.basename(dest)
                def hdr(k):
                    v = self.headers.get(k) or ""
                    return urllib.request.unquote(v) if v else None
                pw = hdr("X-Cert-Password")
                kind = (self.headers.get("X-Cert-Kind") or "").lower()
                if name.lower().endswith(".zip"):
                    import_package(dest, hdr("X-Client-Password"), hdr("X-CA-Password"))
                    TAK.reconnect()
                    msg = "connection package imported"
                elif name.lower().endswith((".p12", ".pfx")):
                    kind = kind if kind in ("client", "ca") else cert_kind(name)
                    setting = "CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"
                    try:
                        used = p12_to_pem(dest, os.path.join(CERTS, kind + ".pem"), [pw, cfg(setting), "atakatak"],
                                          nokeys=(kind == "ca"))
                    except Exception:
                        os.unlink(dest)
                        raise
                    os.makedirs(os.path.join(CERTS, "imported"), exist_ok=True)
                    os.replace(dest, os.path.join(CERTS, "imported", name))
                    cfg_set({setting: used})
                    TAK.reconnect()
                    msg = "%s imported" % ("client certificate" if kind == "client" else "truststore")
                elif name.lower().endswith(".conf"):
                    cfg_set({"WG_CONF": dest})
                    msg = "; ".join(uplinks_apply())
                elif name.lower().endswith((".pem", ".key")):
                    if kind in ("client", "ca") and name.lower().endswith(".pem"):
                        text = open(dest).read()
                        os.unlink(dest)
                        save_cert_files(**{kind: text}, why=name)
                        msg = "saved as %s.pem" % kind
                    TAK.reconnect()
                return self.send(200, json.dumps({"ok": True, "msg": msg}).encode())
            self.send(404, b'{"error":"not found"}')
        except Exception as e:
            log("web %s: %s" % (path, e), "warning")
            self.send(400, json.dumps({"ok": False, "error": str(e)}).encode())


class WebServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def web_run():
    if not cfgb("WEB"):
        return
    port = cfgi("WEB_PORT", 8484)
    if port == 1471:
        port = 8484
    try:
        srv = WebServer((cfg("WEB_BIND", "0.0.0.0"), port), Web)
    except OSError as e:
        log("web console could not use port %d: %s" % (port, e), "error")
        notify("error", "Web console port %d busy: %s" % (port, e))
        return
    scheme = "http"
    if cfgb("WEB_TLS") and have("openssl"):
        crt, key = os.path.join(BASE, "web.crt"), os.path.join(BASE, "web.key")
        if not os.path.exists(crt):
            run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=TurtleTAK",
                 "-keyout", key, "-out", crt], 120)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        scheme = "https"
    log("web console on %s://<hub>:%d (all interfaces: %s)" % (scheme, port, cfg("WEB_BIND")))
    srv.serve_forever()


# ----------------------------------------------------------------------------------------------
def first_run_password():
    if cfg("WEB_PASS_HASH"):
        return
    pw = "".join(random.SystemRandom().choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(10))
    cfg_set({"WEB_PASS_HASH": hash_pw(pw)})
    with open(os.path.join(BASE, "web-password.txt"), "w") as fh:
        fh.write("TurtleTAK web console first password: %s\nChange it in Setup > Web password, then delete this file.\n" % pw)
    os.chmod(os.path.join(BASE, "web-password.txt"), 0o600)
    notify("info", "Web console on port %s - first password: %s (change it in Setup)" % (cfg("WEB_PORT"), pw))
    log("web console first password written to %s/web-password.txt" % BASE)


def main():
    for d in (BASE, APP, CERTS, LOGS, BASELINES, LOOT):
        os.makedirs(d, exist_ok=True)
    os.chmod(CERTS, 0o700)
    cfg_load()
    load_state()
    log("%s %s %s starting (python %s)" % (PRODUCT, EDITION, VERSION, sys.version.split()[0]))
    led("SETUP")
    first_run_password()
    status_collect()
    if cfgb("RUN_AT_BOOT"):
        hub("BOOT_PAYLOAD", "enable")
    threading.Thread(target=uplinks_apply, daemon=True).start()
    scan_certs()
    locate()
    for target in (web_run, TAK.run, TAK.watchdog, sa_loop, housekeeping, Gps().run, WATCH.run, WATCH.dhcp_run,
                   WATCH.link_run, BRIDGE.run):
        threading.Thread(target=target, daemon=True, name=target.__name__).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        save_state()
        hub("LED", "OFF") if not cfgb("LED") else None


if __name__ == "__main__":
    main()
TURTLETAK_PY
cat > "$APP/ttcrypto.py" <<'TTCRYPTO_PY'
# TurtleTAK certificate helpers in pure Python (stdlib only), for Hubs without openssl:
#   - RSA key generation + PKCS#10 CSR (for TAK Server enrollment)
#   - PKCS#12 (.p12) reader: PBES2 (PBKDF2 + AES-CBC) and legacy PKCS#12 PBE (3DES, RC2)
# Not a general crypto library: just enough for TAK client certificates.
import base64, hashlib, hmac, os, struct

# ---------------------------------------------------------------------------------------------
# DER
# ---------------------------------------------------------------------------------------------
def _len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag, body):
    return bytes([tag]) + _len(len(body)) + body


def d_int(v):
    b = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big", signed=False)
    if b[0] & 0x80:
        b = b"\0" + b
    while len(b) > 1 and b[0] == 0 and not b[1] & 0x80:
        b = b[1:]
    return tlv(0x02, b)


def d_seq(*items):
    return tlv(0x30, b"".join(items))


def d_set(*items):
    return tlv(0x31, b"".join(items))


def d_oid(s):
    p = [int(x) for x in s.split(".")]
    out = bytes([40 * p[0] + p[1]])
    for v in p[2:]:
        enc = [v & 0x7F]
        v >>= 7
        while v:
            enc.append(0x80 | (v & 0x7F))
            v >>= 7
        out += bytes(reversed(enc))
    return tlv(0x06, out)


def d_null():
    return b"\x05\x00"


def d_bits(b):
    return tlv(0x03, b"\0" + b)


def d_utf8(s):
    return tlv(0x0C, s.encode("utf-8"))


def d_printable(s):
    return tlv(0x13, s.encode("ascii"))


def parse(buf, i=0):
    """-> (tag, value_bytes, next_index)"""
    tag = buf[i]
    ln = buf[i + 1]
    i += 2
    if ln & 0x80:
        n = ln & 0x7F
        if n == 0:  # indefinite length (BER) - not used by the files we read
            raise ValueError("indefinite length")
        ln = int.from_bytes(buf[i:i + n], "big")
        i += n
    return tag, buf[i:i + ln], i + ln


def children(buf):
    out, i = [], 0
    while i < len(buf):
        t, v, i = parse(buf, i)
        out.append((t, v))
    return out


def oid_str(v):
    p = [v[0] // 40, v[0] % 40]
    acc = 0
    for b in v[1:]:
        acc = (acc << 7) | (b & 0x7F)
        if not b & 0x80:
            p.append(acc)
            acc = 0
    return ".".join(map(str, p))


def pem(kind, der):
    b = base64.b64encode(der).decode()
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (kind, "\n".join(b[i:i + 64] for i in range(0, len(b), 64)), kind)


# ---------------------------------------------------------------------------------------------
# RSA key + CSR
# ---------------------------------------------------------------------------------------------
_SMALL = [p for p in range(3, 2000, 2) if all(p % q for q in range(3, int(p ** .5) + 1, 2))]


def _probable_prime(n, rounds=24):
    for p in _SMALL:
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = 2 + int.from_bytes(os.urandom(32), "big") % (n - 3)
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits):
    while True:
        c = int.from_bytes(os.urandom(bits // 8), "big") | (3 << (bits - 2)) | 1
        if _probable_prime(c):
            return c


def rsa_generate(bits=2048, e=65537):
    while True:
        p, q = _prime(bits // 2), _prime(bits // 2)
        if p == q:
            continue
        phi = (p - 1) * (q - 1)
        if phi % e == 0:
            continue
        n = p * q
        if n.bit_length() != bits:
            continue
        d = pow(e, -1, phi)
        return {"n": n, "e": e, "d": d, "p": p, "q": q, "dp": d % (p - 1), "dq": d % (q - 1), "qi": pow(q, -1, p)}


def rsa_key_pem(k):
    der = d_seq(d_int(0), d_int(k["n"]), d_int(k["e"]), d_int(k["d"]), d_int(k["p"]), d_int(k["q"]),
                d_int(k["dp"]), d_int(k["dq"]), d_int(k["qi"]))
    return pem("RSA PRIVATE KEY", der)


def _rsa_sign_sha256(k, data):
    h = hashlib.sha256(data).digest()
    t = bytes.fromhex("3031300d060960864801650304020105000420") + h
    klen = (k["n"].bit_length() + 7) // 8
    em = b"\x00\x01" + b"\xff" * (klen - len(t) - 3) + b"\x00" + t
    m = int.from_bytes(em, "big")
    s1, s2 = pow(m, k["dp"], k["p"]), pow(m, k["dq"], k["q"])
    s = s2 + k["q"] * ((k["qi"] * (s1 - s2)) % k["p"])
    return s.to_bytes(klen, "big")


_NAME_OIDS = {"C": "2.5.4.6", "ST": "2.5.4.8", "L": "2.5.4.7", "O": "2.5.4.10", "OU": "2.5.4.11", "CN": "2.5.4.3"}


def csr_der(k, subject):
    """subject: list of (attr, value) e.g. [("O","TAK"),("OU","TAK"),("CN","user")]"""
    rdns = []
    for a, v in subject:
        oid = _NAME_OIDS.get(a.upper())
        if not oid:
            continue
        val = d_printable(v) if a.upper() == "C" else d_utf8(v)
        rdns.append(d_set(d_seq(d_oid(oid), val)))
    name = d_seq(*rdns)
    spki = d_seq(d_seq(d_oid("1.2.840.113549.1.1.1"), d_null()), d_bits(d_seq(d_int(k["n"]), d_int(k["e"]))))
    info = d_seq(d_int(0), name, spki, b"\xa0\x00")
    sig = _rsa_sign_sha256(k, info)
    return d_seq(info, d_seq(d_oid("1.2.840.113549.1.1.11"), d_null()), d_bits(sig))


# ---------------------------------------------------------------------------------------------
# AES (decrypt only, CBC)
# ---------------------------------------------------------------------------------------------
def _aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i
    return sbox, inv


_SBOX, _INV = _aes_tables()


def _xt(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xt(a)
        b >>= 1
    return r


_M9 = [_mul(i, 9) for i in range(256)]
_M11 = [_mul(i, 11) for i in range(256)]
_M13 = [_mul(i, 13) for i in range(256)]
_M14 = [_mul(i, 14) for i in range(256)]


def _expand(key):
    nk = len(key) // 4
    nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xt(rcon)
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - nk], t)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(nr + 1)], nr


def _aes_decrypt_block(rk, nr, blk):
    s = [b ^ k for b, k in zip(blk, rk[nr])]
    for rnd in range(nr - 1, -1, -1):
        # inverse shift rows (column-major state)
        s = [s[((c - r) % 4) * 4 + r] for c in range(4) for r in range(4)]
        s = [_INV[b] for b in s]
        s = [b ^ k for b, k in zip(s, rk[rnd])]
        if rnd:
            o = []
            for c in range(4):
                a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                o += [_M14[a0] ^ _M11[a1] ^ _M13[a2] ^ _M9[a3], _M9[a0] ^ _M14[a1] ^ _M11[a2] ^ _M13[a3],
                      _M13[a0] ^ _M9[a1] ^ _M14[a2] ^ _M11[a3], _M11[a0] ^ _M13[a1] ^ _M9[a2] ^ _M14[a3]]
            s = o
    return bytes(s)


def aes_cbc_decrypt(key, iv, data):
    rk, nr = _expand(key)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(_aes_decrypt_block(rk, nr, blk), prev))
        prev = blk
    return _unpad(bytes(out), 16)


def _unpad(b, bs):
    n = b[-1] if b else 0
    if not 1 <= n <= bs or b[-n:] != bytes([n]) * n:
        raise ValueError("bad padding (wrong password?)")
    return b[:-n]


# ---------------------------------------------------------------------------------------------
# DES / 3DES (decrypt, CBC) - legacy PKCS#12
# ---------------------------------------------------------------------------------------------
_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
       57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
       36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
      16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]]


def _perm(v, table, nbits):
    o = 0
    for t in table:
        o = (o << 1) | ((v >> (nbits - t)) & 1)
    return o


def _des_keys(key8):
    k = _perm(int.from_bytes(key8, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    ks = []
    for s in _SHIFTS:
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF
        ks.append(_perm((c << 28) | d, _PC2, 56))
    return ks


def _des_block(ks, blk, decrypt):
    v = _perm(int.from_bytes(blk, "big"), _IP, 64)
    l, r = v >> 32, v & 0xFFFFFFFF
    for k in (reversed(ks) if decrypt else ks):
        x = _perm(r, _E, 32) ^ k
        f = 0
        for i in range(8):
            six = (x >> (42 - 6 * i)) & 0x3F
            f = (f << 4) | _S[i][((six & 0x20) >> 4 | (six & 1)) * 16 + ((six >> 1) & 0xF)]
        l, r = r, l ^ _perm(f, _P, 32)
    return _perm((r << 32) | l, _FP, 64).to_bytes(8, "big")


def des3_cbc_decrypt(key, iv, data):
    k1, k2, k3 = _des_keys(key[:8]), _des_keys(key[8:16]), _des_keys(key[16:24])
    out, prev = bytearray(), iv
    for i in range(0, len(data), 8):
        blk = data[i:i + 8]
        p = _des_block(k1, _des_block(k2, _des_block(k3, blk, True), False), True)
        out += bytes(a ^ b for a, b in zip(p, prev))
        prev = blk
    return _unpad(bytes(out), 8)


# ---------------------------------------------------------------------------------------------
# RC2 (decrypt, CBC) - legacy PKCS#12 certificate bags (RC2-40 / RC2-128)
# ---------------------------------------------------------------------------------------------
_PITABLE = bytes.fromhex(
    "d978f9c419ddb5ed28e9fd794aa0d89dc67e37832b76538e624c6488448bfba2179a59f587b34f1361456d8d09817d32"
    "bd8f40eb86b77b0bf09521225c6b4e8254d66593ce60b21c7356c014a78cf1dc1275ca1f3bbee4d1423dd430a33cb626"
    "6fbf0eda4669075727f21d9bbc944303f811c7f690ef3ee706c3d52fc8661ed708e8eade8052eef784aa72ac354d6a2a"
    "961ad2715a1549744b9fd05e0418a4ecc2e0416e0f51cbcc2491af50a1f47039997c3a8523b8b47afc02365b25559731"
    "2d5dfa98e38a92ae05df2910676cbac9d300e6cfe19ea82c6316013f58e289a90d38341bab33ffb0bb480c5fb9b1cd2e"
    "c5f3db47e5a59c770aa62068fe7fc1ad")


def _rc2_keyexp(key, bits):
    L = bytearray(key) + bytearray(128 - len(key))
    T = len(key)
    for i in range(T, 128):
        L[i] = _PITABLE[(L[i - 1] + L[i - T]) & 0xFF]
    T8 = (bits + 7) // 8
    TM = 0xFF % (1 << (8 + bits - 8 * T8))
    L[128 - T8] = _PITABLE[L[128 - T8] & TM]
    for i in range(127 - T8, -1, -1):
        L[i] = _PITABLE[L[i + 1] ^ L[i + T8]]
    return [L[2 * i] | (L[2 * i + 1] << 8) for i in range(64)]


def _rc2_decrypt_block(K, blk):
    R = list(struct.unpack("<4H", blk))
    s = [1, 2, 3, 5]
    j = 63
    for rnd in range(16):
        for i in (3, 2, 1, 0):
            R[i] = ((R[i] >> s[i]) | (R[i] << (16 - s[i]))) & 0xFFFF
            R[i] = (R[i] - K[j] - (R[(i - 1) % 4] & R[(i - 2) % 4]) - (~R[(i - 1) % 4] & R[(i - 3) % 4])) & 0xFFFF
            j -= 1
        if rnd in (4, 10):
            for i in (3, 2, 1, 0):
                R[i] = (R[i] - K[R[(i - 1) % 4] & 63]) & 0xFFFF
    return struct.pack("<4H", *R)


def rc2_cbc_decrypt(key, iv, data, bits):
    K = _rc2_keyexp(key, bits)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 8):
        blk = data[i:i + 8]
        out += bytes(a ^ b for a, b in zip(_rc2_decrypt_block(K, blk), prev))
        prev = blk
    return _unpad(bytes(out), 8)


# ---------------------------------------------------------------------------------------------
# PKCS#12
# ---------------------------------------------------------------------------------------------
def _p12_kdf(pw_bmp, salt, iters, id_byte, n, hname="sha1"):
    """RFC 7292 appendix B.2"""
    h = getattr(hashlib, hname)
    u, v = h().digest_size, 64
    D = bytes([id_byte]) * v
    fill = lambda b: (b * ((v * ((len(b) + v - 1) // v)) // len(b) + 1))[:v * ((len(b) + v - 1) // v)] if b else b""
    I = bytearray(fill(salt) + fill(pw_bmp))
    out = b""
    while len(out) < n:
        A = h(D + bytes(I)).digest()
        for _ in range(iters - 1):
            A = h(A).digest()
        out += A
        B = (A * (v // u + 1))[:v]
        Bn = int.from_bytes(B, "big")
        for j in range(0, len(I), v):
            x = (int.from_bytes(I[j:j + v], "big") + Bn + 1) % (1 << (8 * v))
            I[j:j + v] = x.to_bytes(v, "big")
    return out[:n]


_HMAC = {"1.2.840.113549.2.7": "sha1", "1.2.840.113549.2.9": "sha256", "1.2.840.113549.2.10": "sha384",
         "1.2.840.113549.2.11": "sha512", "1.2.840.113549.2.8": "sha224"}
_AES = {"2.16.840.1.101.3.4.1.2": 16, "2.16.840.1.101.3.4.1.22": 24, "2.16.840.1.101.3.4.1.42": 32}


def _decrypt(alg, data, password):
    """alg = AlgorithmIdentifier bytes (SEQUENCE body)"""
    items = children(alg)
    oid = oid_str(items[0][1])
    pw_utf8 = password.encode("utf-8")
    pw_bmp = (password + "\0").encode("utf-16-be")
    if oid == "1.2.840.113549.1.5.13":  # PBES2
        kdf, enc = children(items[1][1])
        kdf_items = children(kdf[1])
        if oid_str(kdf_items[0][1]) != "1.2.840.113549.1.5.12":
            raise ValueError("unsupported key derivation")
        prm = children(kdf_items[1][1])
        salt = prm[0][1]
        iters = int.from_bytes(prm[1][1], "big")
        prf = "sha1"
        keylen = None
        for t, v in prm[2:]:
            if t == 0x02:
                keylen = int.from_bytes(v, "big")
            elif t == 0x30:
                prf = _HMAC.get(oid_str(children(v)[0][1]), "sha1")
        enc_items = children(enc[1])
        eoid = oid_str(enc_items[0][1])
        iv = enc_items[1][1]
        if eoid in _AES:
            kl = keylen or _AES[eoid]
            last = None
            for pw in (pw_utf8, pw_bmp[:-2]):
                try:
                    key = hashlib.pbkdf2_hmac(prf, pw, salt, iters, kl)
                    return aes_cbc_decrypt(key, iv, data)
                except ValueError as e:
                    last = e
            raise last
        if eoid == "1.2.840.113549.3.7":  # des-ede3-cbc
            key = hashlib.pbkdf2_hmac(prf, pw_utf8, salt, iters, 24)
            return des3_cbc_decrypt(key, iv, data)
        raise ValueError("unsupported cipher %s" % eoid)
    legacy = {"1.2.840.113549.1.12.1.3": ("3des", 24), "1.2.840.113549.1.12.1.4": ("2des", 16),
              "1.2.840.113549.1.12.1.5": ("rc2", 16), "1.2.840.113549.1.12.1.6": ("rc2", 5)}
    if oid in legacy:
        kind, kl = legacy[oid]
        prm = children(items[1][1])
        salt, iters = prm[0][1], int.from_bytes(prm[1][1], "big")
        key = _p12_kdf(pw_bmp, salt, iters, 1, kl)
        iv = _p12_kdf(pw_bmp, salt, iters, 2, 8)
        if kind == "3des":
            return des3_cbc_decrypt(key, iv, data)
        if kind == "2des":
            return des3_cbc_decrypt(key + key[:8], iv, data)
        return rc2_cbc_decrypt(key, iv, data, kl * 8)
    raise ValueError("unsupported encryption %s" % oid)


def _check_mac(pfx_items, auth_content, password):
    if len(pfx_items) < 3:
        return
    mac = children(pfx_items[2][1])
    digest_info = children(mac[0][1])
    alg = oid_str(children(digest_info[0][1])[0][1])
    want = digest_info[1][1]
    salt = mac[1][1]
    iters = int.from_bytes(mac[2][1], "big") if len(mac) > 2 else 1
    hname = {"1.3.14.3.2.26": "sha1", "2.16.840.1.101.3.4.2.1": "sha256", "2.16.840.1.101.3.4.2.2": "sha384",
             "2.16.840.1.101.3.4.2.3": "sha512"}.get(alg)
    if not hname:
        return
    n = hashlib.new(hname).digest_size
    for pw in ((password + "\0").encode("utf-16-be"), password.encode("utf-8")):
        key = _p12_kdf(pw, salt, iters, 3, n, hname)
        if hmac.compare_digest(hmac.new(key, auth_content, hname).digest(), want):
            return
    raise ValueError("wrong password for this .p12 (the integrity check failed)")


def read_p12(data, password):
    """-> (key_pem or None, [cert_pem, ...]). Raises ValueError with a readable reason."""
    try:
        t, pfx, _ = parse(data)
        items = children(pfx)
        ci = children(items[1][1])
        if oid_str(ci[0][1]) != "1.2.840.113549.1.7.1":
            raise ValueError("public-key protected .p12 files are not supported")
        auth_content = children(ci[1][1])[0][1]
    except (IndexError, ValueError) as e:
        if "supported" in str(e):
            raise
        raise ValueError("not a .p12 file (%s)" % e)
    _check_mac(items, auth_content, password)
    keys, certs = [], []

    def bags(safe_contents):
        for t, bag in children(parse(safe_contents)[1]):
            b = children(bag)
            bag_id = oid_str(b[0][1])
            val = children(b[1][1])[0]
            if bag_id == "1.2.840.113549.1.12.10.1.1":  # keyBag
                keys.append(tlv(val[0], val[1]))
            elif bag_id == "1.2.840.113549.1.12.10.1.2":  # pkcs8ShroudedKeyBag
                epki = children(val[1])
                keys.append(_decrypt(epki[0][1], epki[1][1], password))
            elif bag_id == "1.2.840.113549.1.12.10.1.3":  # certBag
                cb = children(val[1])
                if oid_str(cb[0][1]) == "1.2.840.113549.1.9.22.1":
                    certs.append(children(cb[1][1])[0][1])

    for t, ci in children(parse(auth_content)[1]):
        c = children(ci)
        ctype = oid_str(c[0][1])
        if ctype == "1.2.840.113549.1.7.1":
            bags(children(c[1][1])[0][1])
        elif ctype == "1.2.840.113549.1.7.6":
            ed = children(children(c[1][1])[0][1])
            eci = children(ed[1][1])
            alg = eci[1][1]
            enc = eci[2][1]
            if eci[2][0] == 0xA0:     # constructed [0]: concatenated OCTET STRINGs
                enc = b"".join(v for _, v in children(enc))
            bags(_decrypt(alg, enc, password))
    return (pem("PRIVATE KEY", keys[0]) if keys else None), [pem("CERTIFICATE", c) for c in certs]


def _rsa_n_from_cert(der):
    tbs = children(children(parse(der)[1])[0][1])
    off = 1 if tbs[0][0] == 0xA0 else 0
    spki = children(tbs[5 + off][1])
    pub = parse(spki[1][1][1:])[1]          # BIT STRING minus the unused-bits byte
    return int.from_bytes(children(pub)[0][1], "big")


def _rsa_n_from_key_pem(key_pem):
    der = base64.b64decode("".join(l for l in key_pem.splitlines() if not l.startswith("-----")))
    items = children(parse(der)[1])
    if items[0][0] == 0x02 and len(items) >= 3 and items[1][0] == 0x30:   # PKCS#8
        items = children(parse(items[2][1])[1])
    return int.from_bytes(items[1][1], "big")


def split_chain(key_pem, cert_pems):
    """-> (leaf_pem or None, [other cert pems]) - the leaf is the cert matching the private key."""
    if not key_pem:
        return None, list(cert_pems)
    try:
        n = _rsa_n_from_key_pem(key_pem)
    except Exception:
        return (cert_pems[0] if cert_pems else None), list(cert_pems[1:])
    leaf, rest = None, []
    for c in cert_pems:
        der = base64.b64decode("".join(l for l in c.splitlines() if not l.startswith("-----")))
        try:
            match = _rsa_n_from_cert(der) == n
        except Exception:
            match = False
        if match and leaf is None:
            leaf = c
        else:
            rest.append(c)
    return leaf, rest
TTCRYPTO_PY
mkdir -p "$APP/static"
cat > "$APP/static/leaflet.js" <<'LEAFLET_JS'
/* @preserve
 * Leaflet 1.9.4, a JS library for interactive maps. https://leafletjs.com
 * (c) 2010-2023 Vladimir Agafonkin, (c) 2010-2011 CloudMade
 */
!function(t,e){"object"==typeof exports&&"undefined"!=typeof module?e(exports):"function"==typeof define&&define.amd?define(["exports"],e):e((t="undefined"!=typeof globalThis?globalThis:t||self).leaflet={})}(this,function(t){"use strict";function l(t){for(var e,i,n=1,o=arguments.length;n<o;n++)for(e in i=arguments[n])t[e]=i[e];return t}var R=Object.create||function(t){return N.prototype=t,new N};function N(){}function a(t,e){var i,n=Array.prototype.slice;return t.bind?t.bind.apply(t,n.call(arguments,1)):(i=n.call(arguments,2),function(){return t.apply(e,i.length?i.concat(n.call(arguments)):arguments)})}var D=0;function h(t){return"_leaflet_id"in t||(t._leaflet_id=++D),t._leaflet_id}function j(t,e,i){var n,o,s=function(){n=!1,o&&(r.apply(i,o),o=!1)},r=function(){n?o=arguments:(t.apply(i,arguments),setTimeout(s,e),n=!0)};return r}function H(t,e,i){var n=e[1],e=e[0],o=n-e;return t===n&&i?t:((t-e)%o+o)%o+e}function u(){return!1}function i(t,e){return!1===e?t:(e=Math.pow(10,void 0===e?6:e),Math.round(t*e)/e)}function W(t){return t.trim?t.trim():t.replace(/^\s+|\s+$/g,"")}function F(t){return W(t).split(/\s+/)}function c(t,e){for(var i in Object.prototype.hasOwnProperty.call(t,"options")||(t.options=t.options?R(t.options):{}),e)t.options[i]=e[i];return t.options}function U(t,e,i){var n,o=[];for(n in t)o.push(encodeURIComponent(i?n.toUpperCase():n)+"="+encodeURIComponent(t[n]));return(e&&-1!==e.indexOf("?")?"&":"?")+o.join("&")}var V=/\{ *([\w_ -]+) *\}/g;function q(t,i){return t.replace(V,function(t,e){e=i[e];if(void 0===e)throw new Error("No value provided for variable "+t);return e="function"==typeof e?e(i):e})}var d=Array.isArray||function(t){return"[object Array]"===Object.prototype.toString.call(t)};function G(t,e){for(var i=0;i<t.length;i++)if(t[i]===e)return i;return-1}var K="data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=";function Y(t){return window["webkit"+t]||window["moz"+t]||window["ms"+t]}var X=0;function J(t){var e=+new Date,i=Math.max(0,16-(e-X));return X=e+i,window.setTimeout(t,i)}var $=window.requestAnimationFrame||Y("RequestAnimationFrame")||J,Q=window.cancelAnimationFrame||Y("CancelAnimationFrame")||Y("CancelRequestAnimationFrame")||function(t){window.clearTimeout(t)};function x(t,e,i){if(!i||$!==J)return $.call(window,a(t,e));t.call(e)}function r(t){t&&Q.call(window,t)}var tt={__proto__:null,extend:l,create:R,bind:a,get lastId(){return D},stamp:h,throttle:j,wrapNum:H,falseFn:u,formatNum:i,trim:W,splitWords:F,setOptions:c,getParamString:U,template:q,isArray:d,indexOf:G,emptyImageUrl:K,requestFn:$,cancelFn:Q,requestAnimFrame:x,cancelAnimFrame:r};function et(){}et.extend=function(t){function e(){c(this),this.initialize&&this.initialize.apply(this,arguments),this.callInitHooks()}var i,n=e.__super__=this.prototype,o=R(n);for(i in(o.constructor=e).prototype=o,this)Object.prototype.hasOwnProperty.call(this,i)&&"prototype"!==i&&"__super__"!==i&&(e[i]=this[i]);if(t.statics&&l(e,t.statics),t.includes){var s=t.includes;if("undefined"!=typeof L&&L&&L.Mixin){s=d(s)?s:[s];for(var r=0;r<s.length;r++)s[r]===L.Mixin.Events&&console.warn("Deprecated include of L.Mixin.Events: this property will be removed in future releases, please inherit from L.Evented instead.",(new Error).stack)}l.apply(null,[o].concat(t.includes))}return l(o,t),delete o.statics,delete o.includes,o.options&&(o.options=n.options?R(n.options):{},l(o.options,t.options)),o._initHooks=[],o.callInitHooks=function(){if(!this._initHooksCalled){n.callInitHooks&&n.callInitHooks.call(this),this._initHooksCalled=!0;for(var t=0,e=o._initHooks.length;t<e;t++)o._initHooks[t].call(this)}},e},et.include=function(t){var e=this.prototype.options;return l(this.prototype,t),t.options&&(this.prototype.options=e,this.mergeOptions(t.options)),this},et.mergeOptions=function(t){return l(this.prototype.options,t),this},et.addInitHook=function(t){var e=Array.prototype.slice.call(arguments,1),i="function"==typeof t?t:function(){this[t].apply(this,e)};return this.prototype._initHooks=this.prototype._initHooks||[],this.prototype._initHooks.push(i),this};var e={on:function(t,e,i){if("object"==typeof t)for(var n in t)this._on(n,t[n],e);else for(var o=0,s=(t=F(t)).length;o<s;o++)this._on(t[o],e,i);return this},off:function(t,e,i){if(arguments.length)if("object"==typeof t)for(var n in t)this._off(n,t[n],e);else{t=F(t);for(var o=1===arguments.length,s=0,r=t.length;s<r;s++)o?this._off(t[s]):this._off(t[s],e,i)}else delete this._events;return this},_on:function(t,e,i,n){"function"!=typeof e?console.warn("wrong listener type: "+typeof e):!1===this._listens(t,e,i)&&(e={fn:e,ctx:i=i===this?void 0:i},n&&(e.once=!0),this._events=this._events||{},this._events[t]=this._events[t]||[],this._events[t].push(e))},_off:function(t,e,i){var n,o,s;if(this._events&&(n=this._events[t]))if(1===arguments.length){if(this._firingCount)for(o=0,s=n.length;o<s;o++)n[o].fn=u;delete this._events[t]}else"function"!=typeof e?console.warn("wrong listener type: "+typeof e):!1!==(e=this._listens(t,e,i))&&(i=n[e],this._firingCount&&(i.fn=u,this._events[t]=n=n.slice()),n.splice(e,1))},fire:function(t,e,i){if(this.listens(t,i)){var n=l({},e,{type:t,target:this,sourceTarget:e&&e.sourceTarget||this});if(this._events){var o=this._events[t];if(o){this._firingCount=this._firingCount+1||1;for(var s=0,r=o.length;s<r;s++){var a=o[s],h=a.fn;a.once&&this.off(t,h,a.ctx),h.call(a.ctx||this,n)}this._firingCount--}}i&&this._propagateEvent(n)}return this},listens:function(t,e,i,n){"string"!=typeof t&&console.warn('"string" type argument expected');var o=e,s=("function"!=typeof e&&(n=!!e,i=o=void 0),this._events&&this._events[t]);if(s&&s.length&&!1!==this._listens(t,o,i))return!0;if(n)for(var r in this._eventParents)if(this._eventParents[r].listens(t,e,i,n))return!0;return!1},_listens:function(t,e,i){if(this._events){var n=this._events[t]||[];if(!e)return!!n.length;i===this&&(i=void 0);for(var o=0,s=n.length;o<s;o++)if(n[o].fn===e&&n[o].ctx===i)return o}return!1},once:function(t,e,i){if("object"==typeof t)for(var n in t)this._on(n,t[n],e,!0);else for(var o=0,s=(t=F(t)).length;o<s;o++)this._on(t[o],e,i,!0);return this},addEventParent:function(t){return this._eventParents=this._eventParents||{},this._eventParents[h(t)]=t,this},removeEventParent:function(t){return this._eventParents&&delete this._eventParents[h(t)],this},_propagateEvent:function(t){for(var e in this._eventParents)this._eventParents[e].fire(t.type,l({layer:t.target,propagatedFrom:t.target},t),!0)}},it=(e.addEventListener=e.on,e.removeEventListener=e.clearAllEventListeners=e.off,e.addOneTimeEventListener=e.once,e.fireEvent=e.fire,e.hasEventListeners=e.listens,et.extend(e));function p(t,e,i){this.x=i?Math.round(t):t,this.y=i?Math.round(e):e}var nt=Math.trunc||function(t){return 0<t?Math.floor(t):Math.ceil(t)};function m(t,e,i){return t instanceof p?t:d(t)?new p(t[0],t[1]):null==t?t:"object"==typeof t&&"x"in t&&"y"in t?new p(t.x,t.y):new p(t,e,i)}function f(t,e){if(t)for(var i=e?[t,e]:t,n=0,o=i.length;n<o;n++)this.extend(i[n])}function _(t,e){return!t||t instanceof f?t:new f(t,e)}function s(t,e){if(t)for(var i=e?[t,e]:t,n=0,o=i.length;n<o;n++)this.extend(i[n])}function g(t,e){return t instanceof s?t:new s(t,e)}function v(t,e,i){if(isNaN(t)||isNaN(e))throw new Error("Invalid LatLng object: ("+t+", "+e+")");this.lat=+t,this.lng=+e,void 0!==i&&(this.alt=+i)}function w(t,e,i){return t instanceof v?t:d(t)&&"object"!=typeof t[0]?3===t.length?new v(t[0],t[1],t[2]):2===t.length?new v(t[0],t[1]):null:null==t?t:"object"==typeof t&&"lat"in t?new v(t.lat,"lng"in t?t.lng:t.lon,t.alt):void 0===e?null:new v(t,e,i)}p.prototype={clone:function(){return new p(this.x,this.y)},add:function(t){return this.clone()._add(m(t))},_add:function(t){return this.x+=t.x,this.y+=t.y,this},subtract:function(t){return this.clone()._subtract(m(t))},_subtract:function(t){return this.x-=t.x,this.y-=t.y,this},divideBy:function(t){return this.clone()._divideBy(t)},_divideBy:function(t){return this.x/=t,this.y/=t,this},multiplyBy:function(t){return this.clone()._multiplyBy(t)},_multiplyBy:function(t){return this.x*=t,this.y*=t,this},scaleBy:function(t){return new p(this.x*t.x,this.y*t.y)},unscaleBy:function(t){return new p(this.x/t.x,this.y/t.y)},round:function(){return this.clone()._round()},_round:function(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this},floor:function(){return this.clone()._floor()},_floor:function(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this},ceil:function(){return this.clone()._ceil()},_ceil:function(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this},trunc:function(){return this.clone()._trunc()},_trunc:function(){return this.x=nt(this.x),this.y=nt(this.y),this},distanceTo:function(t){var e=(t=m(t)).x-this.x,t=t.y-this.y;return Math.sqrt(e*e+t*t)},equals:function(t){return(t=m(t)).x===this.x&&t.y===this.y},contains:function(t){return t=m(t),Math.abs(t.x)<=Math.abs(this.x)&&Math.abs(t.y)<=Math.abs(this.y)},toString:function(){return"Point("+i(this.x)+", "+i(this.y)+")"}},f.prototype={extend:function(t){var e,i;if(t){if(t instanceof p||"number"==typeof t[0]||"x"in t)e=i=m(t);else if(e=(t=_(t)).min,i=t.max,!e||!i)return this;this.min||this.max?(this.min.x=Math.min(e.x,this.min.x),this.max.x=Math.max(i.x,this.max.x),this.min.y=Math.min(e.y,this.min.y),this.max.y=Math.max(i.y,this.max.y)):(this.min=e.clone(),this.max=i.clone())}return this},getCenter:function(t){return m((this.min.x+this.max.x)/2,(this.min.y+this.max.y)/2,t)},getBottomLeft:function(){return m(this.min.x,this.max.y)},getTopRight:function(){return m(this.max.x,this.min.y)},getTopLeft:function(){return this.min},getBottomRight:function(){return this.max},getSize:function(){return this.max.subtract(this.min)},contains:function(t){var e,i;return(t=("number"==typeof t[0]||t instanceof p?m:_)(t))instanceof f?(e=t.min,i=t.max):e=i=t,e.x>=this.min.x&&i.x<=this.max.x&&e.y>=this.min.y&&i.y<=this.max.y},intersects:function(t){t=_(t);var e=this.min,i=this.max,n=t.min,t=t.max,o=t.x>=e.x&&n.x<=i.x,t=t.y>=e.y&&n.y<=i.y;return o&&t},overlaps:function(t){t=_(t);var e=this.min,i=this.max,n=t.min,t=t.max,o=t.x>e.x&&n.x<i.x,t=t.y>e.y&&n.y<i.y;return o&&t},isValid:function(){return!(!this.min||!this.max)},pad:function(t){var e=this.min,i=this.max,n=Math.abs(e.x-i.x)*t,t=Math.abs(e.y-i.y)*t;return _(m(e.x-n,e.y-t),m(i.x+n,i.y+t))},equals:function(t){return!!t&&(t=_(t),this.min.equals(t.getTopLeft())&&this.max.equals(t.getBottomRight()))}},s.prototype={extend:function(t){var e,i,n=this._southWest,o=this._northEast;if(t instanceof v)i=e=t;else{if(!(t instanceof s))return t?this.extend(w(t)||g(t)):this;if(e=t._southWest,i=t._northEast,!e||!i)return this}return n||o?(n.lat=Math.min(e.lat,n.lat),n.lng=Math.min(e.lng,n.lng),o.lat=Math.max(i.lat,o.lat),o.lng=Math.max(i.lng,o.lng)):(this._southWest=new v(e.lat,e.lng),this._northEast=new v(i.lat,i.lng)),this},pad:function(t){var e=this._southWest,i=this._northEast,n=Math.abs(e.lat-i.lat)*t,t=Math.abs(e.lng-i.lng)*t;return new s(new v(e.lat-n,e.lng-t),new v(i.lat+n,i.lng+t))},getCenter:function(){return new v((this._southWest.lat+this._northEast.lat)/2,(this._southWest.lng+this._northEast.lng)/2)},getSouthWest:function(){return this._southWest},getNorthEast:function(){return this._northEast},getNorthWest:function(){return new v(this.getNorth(),this.getWest())},getSouthEast:function(){return new v(this.getSouth(),this.getEast())},getWest:function(){return this._southWest.lng},getSouth:function(){return this._southWest.lat},getEast:function(){return this._northEast.lng},getNorth:function(){return this._northEast.lat},contains:function(t){t=("number"==typeof t[0]||t instanceof v||"lat"in t?w:g)(t);var e,i,n=this._southWest,o=this._northEast;return t instanceof s?(e=t.getSouthWest(),i=t.getNorthEast()):e=i=t,e.lat>=n.lat&&i.lat<=o.lat&&e.lng>=n.lng&&i.lng<=o.lng},intersects:function(t){t=g(t);var e=this._southWest,i=this._northEast,n=t.getSouthWest(),t=t.getNorthEast(),o=t.lat>=e.lat&&n.lat<=i.lat,t=t.lng>=e.lng&&n.lng<=i.lng;return o&&t},overlaps:function(t){t=g(t);var e=this._southWest,i=this._northEast,n=t.getSouthWest(),t=t.getNorthEast(),o=t.lat>e.lat&&n.lat<i.lat,t=t.lng>e.lng&&n.lng<i.lng;return o&&t},toBBoxString:function(){return[this.getWest(),this.getSouth(),this.getEast(),this.getNorth()].join(",")},equals:function(t,e){return!!t&&(t=g(t),this._southWest.equals(t.getSouthWest(),e)&&this._northEast.equals(t.getNorthEast(),e))},isValid:function(){return!(!this._southWest||!this._northEast)}};var ot={latLngToPoint:function(t,e){t=this.projection.project(t),e=this.scale(e);return this.transformation._transform(t,e)},pointToLatLng:function(t,e){e=this.scale(e),t=this.transformation.untransform(t,e);return this.projection.unproject(t)},project:function(t){return this.projection.project(t)},unproject:function(t){return this.projection.unproject(t)},scale:function(t){return 256*Math.pow(2,t)},zoom:function(t){return Math.log(t/256)/Math.LN2},getProjectedBounds:function(t){var e;return this.infinite?null:(e=this.projection.bounds,t=this.scale(t),new f(this.transformation.transform(e.min,t),this.transformation.transform(e.max,t)))},infinite:!(v.prototype={equals:function(t,e){return!!t&&(t=w(t),Math.max(Math.abs(this.lat-t.lat),Math.abs(this.lng-t.lng))<=(void 0===e?1e-9:e))},toString:function(t){return"LatLng("+i(this.lat,t)+", "+i(this.lng,t)+")"},distanceTo:function(t){return st.distance(this,w(t))},wrap:function(){return st.wrapLatLng(this)},toBounds:function(t){var t=180*t/40075017,e=t/Math.cos(Math.PI/180*this.lat);return g([this.lat-t,this.lng-e],[this.lat+t,this.lng+e])},clone:function(){return new v(this.lat,this.lng,this.alt)}}),wrapLatLng:function(t){var e=this.wrapLng?H(t.lng,this.wrapLng,!0):t.lng;return new v(this.wrapLat?H(t.lat,this.wrapLat,!0):t.lat,e,t.alt)},wrapLatLngBounds:function(t){var e=t.getCenter(),i=this.wrapLatLng(e),n=e.lat-i.lat,e=e.lng-i.lng;return 0==n&&0==e?t:(i=t.getSouthWest(),t=t.getNorthEast(),new s(new v(i.lat-n,i.lng-e),new v(t.lat-n,t.lng-e)))}},st=l({},ot,{wrapLng:[-180,180],R:6371e3,distance:function(t,e){var i=Math.PI/180,n=t.lat*i,o=e.lat*i,s=Math.sin((e.lat-t.lat)*i/2),e=Math.sin((e.lng-t.lng)*i/2),t=s*s+Math.cos(n)*Math.cos(o)*e*e,i=2*Math.atan2(Math.sqrt(t),Math.sqrt(1-t));return this.R*i}}),rt=6378137,rt={R:rt,MAX_LATITUDE:85.0511287798,project:function(t){var e=Math.PI/180,i=this.MAX_LATITUDE,i=Math.max(Math.min(i,t.lat),-i),i=Math.sin(i*e);return new p(this.R*t.lng*e,this.R*Math.log((1+i)/(1-i))/2)},unproject:function(t){var e=180/Math.PI;return new v((2*Math.atan(Math.exp(t.y/this.R))-Math.PI/2)*e,t.x*e/this.R)},bounds:new f([-(rt=rt*Math.PI),-rt],[rt,rt])};function at(t,e,i,n){d(t)?(this._a=t[0],this._b=t[1],this._c=t[2],this._d=t[3]):(this._a=t,this._b=e,this._c=i,this._d=n)}function ht(t,e,i,n){return new at(t,e,i,n)}at.prototype={transform:function(t,e){return this._transform(t.clone(),e)},_transform:function(t,e){return t.x=(e=e||1)*(this._a*t.x+this._b),t.y=e*(this._c*t.y+this._d),t},untransform:function(t,e){return new p((t.x/(e=e||1)-this._b)/this._a,(t.y/e-this._d)/this._c)}};var lt=l({},st,{code:"EPSG:3857",projection:rt,transformation:ht(lt=.5/(Math.PI*rt.R),.5,-lt,.5)}),ut=l({},lt,{code:"EPSG:900913"});function ct(t){return document.createElementNS("http://www.w3.org/2000/svg",t)}function dt(t,e){for(var i,n,o,s,r="",a=0,h=t.length;a<h;a++){for(i=0,n=(o=t[a]).length;i<n;i++)r+=(i?"L":"M")+(s=o[i]).x+" "+s.y;r+=e?b.svg?"z":"x":""}return r||"M0 0"}var _t=document.documentElement.style,pt="ActiveXObject"in window,mt=pt&&!document.addEventListener,n="msLaunchUri"in navigator&&!("documentMode"in document),ft=y("webkit"),gt=y("android"),vt=y("android 2")||y("android 3"),yt=parseInt(/WebKit\/([0-9]+)|$/.exec(navigator.userAgent)[1],10),yt=gt&&y("Google")&&yt<537&&!("AudioNode"in window),xt=!!window.opera,wt=!n&&y("chrome"),bt=y("gecko")&&!ft&&!xt&&!pt,Pt=!wt&&y("safari"),Lt=y("phantom"),o="OTransition"in _t,Tt=0===navigator.platform.indexOf("Win"),Mt=pt&&"transition"in _t,zt="WebKitCSSMatrix"in window&&"m11"in new window.WebKitCSSMatrix&&!vt,_t="MozPerspective"in _t,Ct=!window.L_DISABLE_3D&&(Mt||zt||_t)&&!o&&!Lt,Zt="undefined"!=typeof orientation||y("mobile"),St=Zt&&ft,Et=Zt&&zt,kt=!window.PointerEvent&&window.MSPointerEvent,Ot=!(!window.PointerEvent&&!kt),At="ontouchstart"in window||!!window.TouchEvent,Bt=!window.L_NO_TOUCH&&(At||Ot),It=Zt&&xt,Rt=Zt&&bt,Nt=1<(window.devicePixelRatio||window.screen.deviceXDPI/window.screen.logicalXDPI),Dt=function(){var t=!1;try{var e=Object.defineProperty({},"passive",{get:function(){t=!0}});window.addEventListener("testPassiveEventSupport",u,e),window.removeEventListener("testPassiveEventSupport",u,e)}catch(t){}return t}(),jt=!!document.createElement("canvas").getContext,Ht=!(!document.createElementNS||!ct("svg").createSVGRect),Wt=!!Ht&&((Wt=document.createElement("div")).innerHTML="<svg/>","http://www.w3.org/2000/svg"===(Wt.firstChild&&Wt.firstChild.namespaceURI));function y(t){return 0<=navigator.userAgent.toLowerCase().indexOf(t)}var b={ie:pt,ielt9:mt,edge:n,webkit:ft,android:gt,android23:vt,androidStock:yt,opera:xt,chrome:wt,gecko:bt,safari:Pt,phantom:Lt,opera12:o,win:Tt,ie3d:Mt,webkit3d:zt,gecko3d:_t,any3d:Ct,mobile:Zt,mobileWebkit:St,mobileWebkit3d:Et,msPointer:kt,pointer:Ot,touch:Bt,touchNative:At,mobileOpera:It,mobileGecko:Rt,retina:Nt,passiveEvents:Dt,canvas:jt,svg:Ht,vml:!Ht&&function(){try{var t=document.createElement("div"),e=(t.innerHTML='<v:shape adj="1"/>',t.firstChild);return e.style.behavior="url(#default#VML)",e&&"object"==typeof e.adj}catch(t){return!1}}(),inlineSvg:Wt,mac:0===navigator.platform.indexOf("Mac"),linux:0===navigator.platform.indexOf("Linux")},Ft=b.msPointer?"MSPointerDown":"pointerdown",Ut=b.msPointer?"MSPointerMove":"pointermove",Vt=b.msPointer?"MSPointerUp":"pointerup",qt=b.msPointer?"MSPointerCancel":"pointercancel",Gt={touchstart:Ft,touchmove:Ut,touchend:Vt,touchcancel:qt},Kt={touchstart:function(t,e){e.MSPOINTER_TYPE_TOUCH&&e.pointerType===e.MSPOINTER_TYPE_TOUCH&&O(e);ee(t,e)},touchmove:ee,touchend:ee,touchcancel:ee},Yt={},Xt=!1;function Jt(t,e,i){return"touchstart"!==e||Xt||(document.addEventListener(Ft,$t,!0),document.addEventListener(Ut,Qt,!0),document.addEventListener(Vt,te,!0),document.addEventListener(qt,te,!0),Xt=!0),Kt[e]?(i=Kt[e].bind(this,i),t.addEventListener(Gt[e],i,!1),i):(console.warn("wrong event specified:",e),u)}function $t(t){Yt[t.pointerId]=t}function Qt(t){Yt[t.pointerId]&&(Yt[t.pointerId]=t)}function te(t){delete Yt[t.pointerId]}function ee(t,e){if(e.pointerType!==(e.MSPOINTER_TYPE_MOUSE||"mouse")){for(var i in e.touches=[],Yt)e.touches.push(Yt[i]);e.changedTouches=[e],t(e)}}var ie=200;function ne(t,i){t.addEventListener("dblclick",i);var n,o=0;function e(t){var e;1!==t.detail?n=t.detail:"mouse"===t.pointerType||t.sourceCapabilities&&!t.sourceCapabilities.firesTouchEvents||((e=Ne(t)).some(function(t){return t instanceof HTMLLabelElement&&t.attributes.for})&&!e.some(function(t){return t instanceof HTMLInputElement||t instanceof HTMLSelectElement})||((e=Date.now())-o<=ie?2===++n&&i(function(t){var e,i,n={};for(i in t)e=t[i],n[i]=e&&e.bind?e.bind(t):e;return(t=n).type="dblclick",n.detail=2,n.isTrusted=!1,n._simulated=!0,n}(t)):n=1,o=e))}return t.addEventListener("click",e),{dblclick:i,simDblclick:e}}var oe,se,re,ae,he,le,ue=we(["transform","webkitTransform","OTransform","MozTransform","msTransform"]),ce=we(["webkitTransition","transition","OTransition","MozTransition","msTransition"]),de="webkitTransition"===ce||"OTransition"===ce?ce+"End":"transitionend";function _e(t){return"string"==typeof t?document.getElementById(t):t}function pe(t,e){var i=t.style[e]||t.currentStyle&&t.currentStyle[e];return"auto"===(i=i&&"auto"!==i||!document.defaultView?i:(t=document.defaultView.getComputedStyle(t,null))?t[e]:null)?null:i}function P(t,e,i){t=document.createElement(t);return t.className=e||"",i&&i.appendChild(t),t}function T(t){var e=t.parentNode;e&&e.removeChild(t)}function me(t){for(;t.firstChild;)t.removeChild(t.firstChild)}function fe(t){var e=t.parentNode;e&&e.lastChild!==t&&e.appendChild(t)}function ge(t){var e=t.parentNode;e&&e.firstChild!==t&&e.insertBefore(t,e.firstChild)}function ve(t,e){return void 0!==t.classList?t.classList.contains(e):0<(t=xe(t)).length&&new RegExp("(^|\\s)"+e+"(\\s|$)").test(t)}function M(t,e){var i;if(void 0!==t.classList)for(var n=F(e),o=0,s=n.length;o<s;o++)t.classList.add(n[o]);else ve(t,e)||ye(t,((i=xe(t))?i+" ":"")+e)}function z(t,e){void 0!==t.classList?t.classList.remove(e):ye(t,W((" "+xe(t)+" ").replace(" "+e+" "," ")))}function ye(t,e){void 0===t.className.baseVal?t.className=e:t.className.baseVal=e}function xe(t){return void 0===(t=t.correspondingElement?t.correspondingElement:t).className.baseVal?t.className:t.className.baseVal}function C(t,e){if("opacity"in t.style)t.style.opacity=e;else if("filter"in t.style){var i=!1,n="DXImageTransform.Microsoft.Alpha";try{i=t.filters.item(n)}catch(t){if(1===e)return}e=Math.round(100*e),i?(i.Enabled=100!==e,i.Opacity=e):t.style.filter+=" progid:"+n+"(opacity="+e+")"}}function we(t){for(var e=document.documentElement.style,i=0;i<t.length;i++)if(t[i]in e)return t[i];return!1}function be(t,e,i){e=e||new p(0,0);t.style[ue]=(b.ie3d?"translate("+e.x+"px,"+e.y+"px)":"translate3d("+e.x+"px,"+e.y+"px,0)")+(i?" scale("+i+")":"")}function Z(t,e){t._leaflet_pos=e,b.any3d?be(t,e):(t.style.left=e.x+"px",t.style.top=e.y+"px")}function Pe(t){return t._leaflet_pos||new p(0,0)}function Le(){S(window,"dragstart",O)}function Te(){k(window,"dragstart",O)}function Me(t){for(;-1===t.tabIndex;)t=t.parentNode;t.style&&(ze(),le=(he=t).style.outlineStyle,t.style.outlineStyle="none",S(window,"keydown",ze))}function ze(){he&&(he.style.outlineStyle=le,le=he=void 0,k(window,"keydown",ze))}function Ce(t){for(;!((t=t.parentNode).offsetWidth&&t.offsetHeight||t===document.body););return t}function Ze(t){var e=t.getBoundingClientRect();return{x:e.width/t.offsetWidth||1,y:e.height/t.offsetHeight||1,boundingClientRect:e}}ae="onselectstart"in document?(re=function(){S(window,"selectstart",O)},function(){k(window,"selectstart",O)}):(se=we(["userSelect","WebkitUserSelect","OUserSelect","MozUserSelect","msUserSelect"]),re=function(){var t;se&&(t=document.documentElement.style,oe=t[se],t[se]="none")},function(){se&&(document.documentElement.style[se]=oe,oe=void 0)});pt={__proto__:null,TRANSFORM:ue,TRANSITION:ce,TRANSITION_END:de,get:_e,getStyle:pe,create:P,remove:T,empty:me,toFront:fe,toBack:ge,hasClass:ve,addClass:M,removeClass:z,setClass:ye,getClass:xe,setOpacity:C,testProp:we,setTransform:be,setPosition:Z,getPosition:Pe,get disableTextSelection(){return re},get enableTextSelection(){return ae},disableImageDrag:Le,enableImageDrag:Te,preventOutline:Me,restoreOutline:ze,getSizedParentNode:Ce,getScale:Ze};function S(t,e,i,n){if(e&&"object"==typeof e)for(var o in e)ke(t,o,e[o],i);else for(var s=0,r=(e=F(e)).length;s<r;s++)ke(t,e[s],i,n);return this}var E="_leaflet_events";function k(t,e,i,n){if(1===arguments.length)Se(t),delete t[E];else if(e&&"object"==typeof e)for(var o in e)Oe(t,o,e[o],i);else if(e=F(e),2===arguments.length)Se(t,function(t){return-1!==G(e,t)});else for(var s=0,r=e.length;s<r;s++)Oe(t,e[s],i,n);return this}function Se(t,e){for(var i in t[E]){var n=i.split(/\d/)[0];e&&!e(n)||Oe(t,n,null,null,i)}}var Ee={mouseenter:"mouseover",mouseleave:"mouseout",wheel:!("onwheel"in window)&&"mousewheel"};function ke(e,t,i,n){var o,s,r=t+h(i)+(n?"_"+h(n):"");e[E]&&e[E][r]||(s=o=function(t){return i.call(n||e,t||window.event)},!b.touchNative&&b.pointer&&0===t.indexOf("touch")?o=Jt(e,t,o):b.touch&&"dblclick"===t?o=ne(e,o):"addEventListener"in e?"touchstart"===t||"touchmove"===t||"wheel"===t||"mousewheel"===t?e.addEventListener(Ee[t]||t,o,!!b.passiveEvents&&{passive:!1}):"mouseenter"===t||"mouseleave"===t?e.addEventListener(Ee[t],o=function(t){t=t||window.event,We(e,t)&&s(t)},!1):e.addEventListener(t,s,!1):e.attachEvent("on"+t,o),e[E]=e[E]||{},e[E][r]=o)}function Oe(t,e,i,n,o){o=o||e+h(i)+(n?"_"+h(n):"");var s,r,i=t[E]&&t[E][o];i&&(!b.touchNative&&b.pointer&&0===e.indexOf("touch")?(n=t,r=i,Gt[s=e]?n.removeEventListener(Gt[s],r,!1):console.warn("wrong event specified:",s)):b.touch&&"dblclick"===e?(n=i,(r=t).removeEventListener("dblclick",n.dblclick),r.removeEventListener("click",n.simDblclick)):"removeEventListener"in t?t.removeEventListener(Ee[e]||e,i,!1):t.detachEvent("on"+e,i),t[E][o]=null)}function Ae(t){return t.stopPropagation?t.stopPropagation():t.originalEvent?t.originalEvent._stopped=!0:t.cancelBubble=!0,this}function Be(t){return ke(t,"wheel",Ae),this}function Ie(t){return S(t,"mousedown touchstart dblclick contextmenu",Ae),t._leaflet_disable_click=!0,this}function O(t){return t.preventDefault?t.preventDefault():t.returnValue=!1,this}function Re(t){return O(t),Ae(t),this}function Ne(t){if(t.composedPath)return t.composedPath();for(var e=[],i=t.target;i;)e.push(i),i=i.parentNode;return e}function De(t,e){var i,n;return e?(n=(i=Ze(e)).boundingClientRect,new p((t.clientX-n.left)/i.x-e.clientLeft,(t.clientY-n.top)/i.y-e.clientTop)):new p(t.clientX,t.clientY)}var je=b.linux&&b.chrome?window.devicePixelRatio:b.mac?3*window.devicePixelRatio:0<window.devicePixelRatio?2*window.devicePixelRatio:1;function He(t){return b.edge?t.wheelDeltaY/2:t.deltaY&&0===t.deltaMode?-t.deltaY/je:t.deltaY&&1===t.deltaMode?20*-t.deltaY:t.deltaY&&2===t.deltaMode?60*-t.deltaY:t.deltaX||t.deltaZ?0:t.wheelDelta?(t.wheelDeltaY||t.wheelDelta)/2:t.detail&&Math.abs(t.detail)<32765?20*-t.detail:t.detail?t.detail/-32765*60:0}function We(t,e){var i=e.relatedTarget;if(!i)return!0;try{for(;i&&i!==t;)i=i.parentNode}catch(t){return!1}return i!==t}var mt={__proto__:null,on:S,off:k,stopPropagation:Ae,disableScrollPropagation:Be,disableClickPropagation:Ie,preventDefault:O,stop:Re,getPropagationPath:Ne,getMousePosition:De,getWheelDelta:He,isExternalTarget:We,addListener:S,removeListener:k},Fe=it.extend({run:function(t,e,i,n){this.stop(),this._el=t,this._inProgress=!0,this._duration=i||.25,this._easeOutPower=1/Math.max(n||.5,.2),this._startPos=Pe(t),this._offset=e.subtract(this._startPos),this._startTime=+new Date,this.fire("start"),this._animate()},stop:function(){this._inProgress&&(this._step(!0),this._complete())},_animate:function(){this._animId=x(this._animate,this),this._step()},_step:function(t){var e=+new Date-this._startTime,i=1e3*this._duration;e<i?this._runFrame(this._easeOut(e/i),t):(this._runFrame(1),this._complete())},_runFrame:function(t,e){t=this._startPos.add(this._offset.multiplyBy(t));e&&t._round(),Z(this._el,t),this.fire("step")},_complete:function(){r(this._animId),this._inProgress=!1,this.fire("end")},_easeOut:function(t){return 1-Math.pow(1-t,this._easeOutPower)}}),A=it.extend({options:{crs:lt,center:void 0,zoom:void 0,minZoom:void 0,maxZoom:void 0,layers:[],maxBounds:void 0,renderer:void 0,zoomAnimation:!0,zoomAnimationThreshold:4,fadeAnimation:!0,markerZoomAnimation:!0,transform3DLimit:8388608,zoomSnap:1,zoomDelta:1,trackResize:!0},initialize:function(t,e){e=c(this,e),this._handlers=[],this._layers={},this._zoomBoundLayers={},this._sizeChanged=!0,this._initContainer(t),this._initLayout(),this._onResize=a(this._onResize,this),this._initEvents(),e.maxBounds&&this.setMaxBounds(e.maxBounds),void 0!==e.zoom&&(this._zoom=this._limitZoom(e.zoom)),e.center&&void 0!==e.zoom&&this.setView(w(e.center),e.zoom,{reset:!0}),this.callInitHooks(),this._zoomAnimated=ce&&b.any3d&&!b.mobileOpera&&this.options.zoomAnimation,this._zoomAnimated&&(this._createAnimProxy(),S(this._proxy,de,this._catchTransitionEnd,this)),this._addLayers(this.options.layers)},setView:function(t,e,i){if((e=void 0===e?this._zoom:this._limitZoom(e),t=this._limitCenter(w(t),e,this.options.maxBounds),i=i||{},this._stop(),this._loaded&&!i.reset&&!0!==i)&&(void 0!==i.animate&&(i.zoom=l({animate:i.animate},i.zoom),i.pan=l({animate:i.animate,duration:i.duration},i.pan)),this._zoom!==e?this._tryAnimatedZoom&&this._tryAnimatedZoom(t,e,i.zoom):this._tryAnimatedPan(t,i.pan)))return clearTimeout(this._sizeTimer),this;return this._resetView(t,e,i.pan&&i.pan.noMoveStart),this},setZoom:function(t,e){return this._loaded?this.setView(this.getCenter(),t,{zoom:e}):(this._zoom=t,this)},zoomIn:function(t,e){return t=t||(b.any3d?this.options.zoomDelta:1),this.setZoom(this._zoom+t,e)},zoomOut:function(t,e){return t=t||(b.any3d?this.options.zoomDelta:1),this.setZoom(this._zoom-t,e)},setZoomAround:function(t,e,i){var n=this.getZoomScale(e),o=this.getSize().divideBy(2),t=(t instanceof p?t:this.latLngToContainerPoint(t)).subtract(o).multiplyBy(1-1/n),n=this.containerPointToLatLng(o.add(t));return this.setView(n,e,{zoom:i})},_getBoundsCenterZoom:function(t,e){e=e||{},t=t.getBounds?t.getBounds():g(t);var i=m(e.paddingTopLeft||e.padding||[0,0]),n=m(e.paddingBottomRight||e.padding||[0,0]),o=this.getBoundsZoom(t,!1,i.add(n));return(o="number"==typeof e.maxZoom?Math.min(e.maxZoom,o):o)===1/0?{center:t.getCenter(),zoom:o}:(e=n.subtract(i).divideBy(2),n=this.project(t.getSouthWest(),o),i=this.project(t.getNorthEast(),o),{center:this.unproject(n.add(i).divideBy(2).add(e),o),zoom:o})},fitBounds:function(t,e){if((t=g(t)).isValid())return t=this._getBoundsCenterZoom(t,e),this.setView(t.center,t.zoom,e);throw new Error("Bounds are not valid.")},fitWorld:function(t){return this.fitBounds([[-90,-180],[90,180]],t)},panTo:function(t,e){return this.setView(t,this._zoom,{pan:e})},panBy:function(t,e){var i;return e=e||{},(t=m(t).round()).x||t.y?(!0===e.animate||this.getSize().contains(t)?(this._panAnim||(this._panAnim=new Fe,this._panAnim.on({step:this._onPanTransitionStep,end:this._onPanTransitionEnd},this)),e.noMoveStart||this.fire("movestart"),!1!==e.animate?(M(this._mapPane,"leaflet-pan-anim"),i=this._getMapPanePos().subtract(t).round(),this._panAnim.run(this._mapPane,i,e.duration||.25,e.easeLinearity)):(this._rawPanBy(t),this.fire("move").fire("moveend"))):this._resetView(this.unproject(this.project(this.getCenter()).add(t)),this.getZoom()),this):this.fire("moveend")},flyTo:function(n,o,t){if(!1===(t=t||{}).animate||!b.any3d)return this.setView(n,o,t);this._stop();var s=this.project(this.getCenter()),r=this.project(n),e=this.getSize(),a=this._zoom,h=(n=w(n),o=void 0===o?a:o,Math.max(e.x,e.y)),i=h*this.getZoomScale(a,o),l=r.distanceTo(s)||1,u=1.42,c=u*u;function d(t){t=(i*i-h*h+(t?-1:1)*c*c*l*l)/(2*(t?i:h)*c*l),t=Math.sqrt(t*t+1)-t;return t<1e-9?-18:Math.log(t)}function _(t){return(Math.exp(t)-Math.exp(-t))/2}function p(t){return(Math.exp(t)+Math.exp(-t))/2}var m=d(0);function f(t){return h*(p(m)*(_(t=m+u*t)/p(t))-_(m))/c}var g=Date.now(),v=(d(1)-m)/u,y=t.duration?1e3*t.duration:1e3*v*.8;return this._moveStart(!0,t.noMoveStart),function t(){var e=(Date.now()-g)/y,i=(1-Math.pow(1-e,1.5))*v;e<=1?(this._flyToFrame=x(t,this),this._move(this.unproject(s.add(r.subtract(s).multiplyBy(f(i)/l)),a),this.getScaleZoom(h/(e=i,h*(p(m)/p(m+u*e))),a),{flyTo:!0})):this._move(n,o)._moveEnd(!0)}.call(this),this},flyToBounds:function(t,e){t=this._getBoundsCenterZoom(t,e);return this.flyTo(t.center,t.zoom,e)},setMaxBounds:function(t){return t=g(t),this.listens("moveend",this._panInsideMaxBounds)&&this.off("moveend",this._panInsideMaxBounds),t.isValid()?(this.options.maxBounds=t,this._loaded&&this._panInsideMaxBounds(),this.on("moveend",this._panInsideMaxBounds)):(this.options.maxBounds=null,this)},setMinZoom:function(t){var e=this.options.minZoom;return this.options.minZoom=t,this._loaded&&e!==t&&(this.fire("zoomlevelschange"),this.getZoom()<this.options.minZoom)?this.setZoom(t):this},setMaxZoom:function(t){var e=this.options.maxZoom;return this.options.maxZoom=t,this._loaded&&e!==t&&(this.fire("zoomlevelschange"),this.getZoom()>this.options.maxZoom)?this.setZoom(t):this},panInsideBounds:function(t,e){this._enforcingBounds=!0;var i=this.getCenter(),t=this._limitCenter(i,this._zoom,g(t));return i.equals(t)||this.panTo(t,e),this._enforcingBounds=!1,this},panInside:function(t,e){var i=m((e=e||{}).paddingTopLeft||e.padding||[0,0]),n=m(e.paddingBottomRight||e.padding||[0,0]),o=this.project(this.getCenter()),t=this.project(t),s=this.getPixelBounds(),i=_([s.min.add(i),s.max.subtract(n)]),s=i.getSize();return i.contains(t)||(this._enforcingBounds=!0,n=t.subtract(i.getCenter()),i=i.extend(t).getSize().subtract(s),o.x+=n.x<0?-i.x:i.x,o.y+=n.y<0?-i.y:i.y,this.panTo(this.unproject(o),e),this._enforcingBounds=!1),this},invalidateSize:function(t){if(!this._loaded)return this;t=l({animate:!1,pan:!0},!0===t?{animate:!0}:t);var e=this.getSize(),i=(this._sizeChanged=!0,this._lastCenter=null,this.getSize()),n=e.divideBy(2).round(),o=i.divideBy(2).round(),n=n.subtract(o);return n.x||n.y?(t.animate&&t.pan?this.panBy(n):(t.pan&&this._rawPanBy(n),this.fire("move"),t.debounceMoveend?(clearTimeout(this._sizeTimer),this._sizeTimer=setTimeout(a(this.fire,this,"moveend"),200)):this.fire("moveend")),this.fire("resize",{oldSize:e,newSize:i})):this},stop:function(){return this.setZoom(this._limitZoom(this._zoom)),this.options.zoomSnap||this.fire("viewreset"),this._stop()},locate:function(t){var e,i;return t=this._locateOptions=l({timeout:1e4,watch:!1},t),"geolocation"in navigator?(e=a(this._handleGeolocationResponse,this),i=a(this._handleGeolocationError,this),t.watch?this._locationWatchId=navigator.geolocation.watchPosition(e,i,t):navigator.geolocation.getCurrentPosition(e,i,t)):this._handleGeolocationError({code:0,message:"Geolocation not supported."}),this},stopLocate:function(){return navigator.geolocation&&navigator.geolocation.clearWatch&&navigator.geolocation.clearWatch(this._locationWatchId),this._locateOptions&&(this._locateOptions.setView=!1),this},_handleGeolocationError:function(t){var e;this._container._leaflet_id&&(e=t.code,t=t.message||(1===e?"permission denied":2===e?"position unavailable":"timeout"),this._locateOptions.setView&&!this._loaded&&this.fitWorld(),this.fire("locationerror",{code:e,message:"Geolocation error: "+t+"."}))},_handleGeolocationResponse:function(t){if(this._container._leaflet_id){var e,i,n=new v(t.coords.latitude,t.coords.longitude),o=n.toBounds(2*t.coords.accuracy),s=this._locateOptions,r=(s.setView&&(e=this.getBoundsZoom(o),this.setView(n,s.maxZoom?Math.min(e,s.maxZoom):e)),{latlng:n,bounds:o,timestamp:t.timestamp});for(i in t.coords)"number"==typeof t.coords[i]&&(r[i]=t.coords[i]);this.fire("locationfound",r)}},addHandler:function(t,e){return e&&(e=this[t]=new e(this),this._handlers.push(e),this.options[t]&&e.enable()),this},remove:function(){if(this._initEvents(!0),this.options.maxBounds&&this.off("moveend",this._panInsideMaxBounds),this._containerId!==this._container._leaflet_id)throw new Error("Map container is being reused by another instance");try{delete this._container._leaflet_id,delete this._containerId}catch(t){this._container._leaflet_id=void 0,this._containerId=void 0}for(var t in void 0!==this._locationWatchId&&this.stopLocate(),this._stop(),T(this._mapPane),this._clearControlPos&&this._clearControlPos(),this._resizeRequest&&(r(this._resizeRequest),this._resizeRequest=null),this._clearHandlers(),this._loaded&&this.fire("unload"),this._layers)this._layers[t].remove();for(t in this._panes)T(this._panes[t]);return this._layers=[],this._panes=[],delete this._mapPane,delete this._renderer,this},createPane:function(t,e){e=P("div","leaflet-pane"+(t?" leaflet-"+t.replace("Pane","")+"-pane":""),e||this._mapPane);return t&&(this._panes[t]=e),e},getCenter:function(){return this._checkIfLoaded(),this._lastCenter&&!this._moved()?this._lastCenter.clone():this.layerPointToLatLng(this._getCenterLayerPoint())},getZoom:function(){return this._zoom},getBounds:function(){var t=this.getPixelBounds();return new s(this.unproject(t.getBottomLeft()),this.unproject(t.getTopRight()))},getMinZoom:function(){return void 0===this.options.minZoom?this._layersMinZoom||0:this.options.minZoom},getMaxZoom:function(){return void 0===this.options.maxZoom?void 0===this._layersMaxZoom?1/0:this._layersMaxZoom:this.options.maxZoom},getBoundsZoom:function(t,e,i){t=g(t),i=m(i||[0,0]);var n=this.getZoom()||0,o=this.getMinZoom(),s=this.getMaxZoom(),r=t.getNorthWest(),t=t.getSouthEast(),i=this.getSize().subtract(i),t=_(this.project(t,n),this.project(r,n)).getSize(),r=b.any3d?this.options.zoomSnap:1,a=i.x/t.x,i=i.y/t.y,t=e?Math.max(a,i):Math.min(a,i),n=this.getScaleZoom(t,n);return r&&(n=Math.round(n/(r/100))*(r/100),n=e?Math.ceil(n/r)*r:Math.floor(n/r)*r),Math.max(o,Math.min(s,n))},getSize:function(){return this._size&&!this._sizeChanged||(this._size=new p(this._container.clientWidth||0,this._container.clientHeight||0),this._sizeChanged=!1),this._size.clone()},getPixelBounds:function(t,e){t=this._getTopLeftPoint(t,e);return new f(t,t.add(this.getSize()))},getPixelOrigin:function(){return this._checkIfLoaded(),this._pixelOrigin},getPixelWorldBounds:function(t){return this.options.crs.getProjectedBounds(void 0===t?this.getZoom():t)},getPane:function(t){return"string"==typeof t?this._panes[t]:t},getPanes:function(){return this._panes},getContainer:function(){return this._container},getZoomScale:function(t,e){var i=this.options.crs;return e=void 0===e?this._zoom:e,i.scale(t)/i.scale(e)},getScaleZoom:function(t,e){var i=this.options.crs,t=(e=void 0===e?this._zoom:e,i.zoom(t*i.scale(e)));return isNaN(t)?1/0:t},project:function(t,e){return e=void 0===e?this._zoom:e,this.options.crs.latLngToPoint(w(t),e)},unproject:function(t,e){return e=void 0===e?this._zoom:e,this.options.crs.pointToLatLng(m(t),e)},layerPointToLatLng:function(t){t=m(t).add(this.getPixelOrigin());return this.unproject(t)},latLngToLayerPoint:function(t){return this.project(w(t))._round()._subtract(this.getPixelOrigin())},wrapLatLng:function(t){return this.options.crs.wrapLatLng(w(t))},wrapLatLngBounds:function(t){return this.options.crs.wrapLatLngBounds(g(t))},distance:function(t,e){return this.options.crs.distance(w(t),w(e))},containerPointToLayerPoint:function(t){return m(t).subtract(this._getMapPanePos())},layerPointToContainerPoint:function(t){return m(t).add(this._getMapPanePos())},containerPointToLatLng:function(t){t=this.containerPointToLayerPoint(m(t));return this.layerPointToLatLng(t)},latLngToContainerPoint:function(t){return this.layerPointToContainerPoint(this.latLngToLayerPoint(w(t)))},mouseEventToContainerPoint:function(t){return De(t,this._container)},mouseEventToLayerPoint:function(t){return this.containerPointToLayerPoint(this.mouseEventToContainerPoint(t))},mouseEventToLatLng:function(t){return this.layerPointToLatLng(this.mouseEventToLayerPoint(t))},_initContainer:function(t){t=this._container=_e(t);if(!t)throw new Error("Map container not found.");if(t._leaflet_id)throw new Error("Map container is already initialized.");S(t,"scroll",this._onScroll,this),this._containerId=h(t)},_initLayout:function(){var t=this._container,e=(this._fadeAnimated=this.options.fadeAnimation&&b.any3d,M(t,"leaflet-container"+(b.touch?" leaflet-touch":"")+(b.retina?" leaflet-retina":"")+(b.ielt9?" leaflet-oldie":"")+(b.safari?" leaflet-safari":"")+(this._fadeAnimated?" leaflet-fade-anim":"")),pe(t,"position"));"absolute"!==e&&"relative"!==e&&"fixed"!==e&&"sticky"!==e&&(t.style.position="relative"),this._initPanes(),this._initControlPos&&this._initControlPos()},_initPanes:function(){var t=this._panes={};this._paneRenderers={},this._mapPane=this.createPane("mapPane",this._container),Z(this._mapPane,new p(0,0)),this.createPane("tilePane"),this.createPane("overlayPane"),this.createPane("shadowPane"),this.createPane("markerPane"),this.createPane("tooltipPane"),this.createPane("popupPane"),this.options.markerZoomAnimation||(M(t.markerPane,"leaflet-zoom-hide"),M(t.shadowPane,"leaflet-zoom-hide"))},_resetView:function(t,e,i){Z(this._mapPane,new p(0,0));var n=!this._loaded,o=(this._loaded=!0,e=this._limitZoom(e),this.fire("viewprereset"),this._zoom!==e);this._moveStart(o,i)._move(t,e)._moveEnd(o),this.fire("viewreset"),n&&this.fire("load")},_moveStart:function(t,e){return t&&this.fire("zoomstart"),e||this.fire("movestart"),this},_move:function(t,e,i,n){void 0===e&&(e=this._zoom);var o=this._zoom!==e;return this._zoom=e,this._lastCenter=t,this._pixelOrigin=this._getNewPixelOrigin(t),n?i&&i.pinch&&this.fire("zoom",i):((o||i&&i.pinch)&&this.fire("zoom",i),this.fire("move",i)),this},_moveEnd:function(t){return t&&this.fire("zoomend"),this.fire("moveend")},_stop:function(){return r(this._flyToFrame),this._panAnim&&this._panAnim.stop(),this},_rawPanBy:function(t){Z(this._mapPane,this._getMapPanePos().subtract(t))},_getZoomSpan:function(){return this.getMaxZoom()-this.getMinZoom()},_panInsideMaxBounds:function(){this._enforcingBounds||this.panInsideBounds(this.options.maxBounds)},_checkIfLoaded:function(){if(!this._loaded)throw new Error("Set map center and zoom first.")},_initEvents:function(t){this._targets={};var e=t?k:S;e((this._targets[h(this._container)]=this)._container,"click dblclick mousedown mouseup mouseover mouseout mousemove contextmenu keypress keydown keyup",this._handleDOMEvent,this),this.options.trackResize&&e(window,"resize",this._onResize,this),b.any3d&&this.options.transform3DLimit&&(t?this.off:this.on).call(this,"moveend",this._onMoveEnd)},_onResize:function(){r(this._resizeRequest),this._resizeRequest=x(function(){this.invalidateSize({debounceMoveend:!0})},this)},_onScroll:function(){this._container.scrollTop=0,this._container.scrollLeft=0},_onMoveEnd:function(){var t=this._getMapPanePos();Math.max(Math.abs(t.x),Math.abs(t.y))>=this.options.transform3DLimit&&this._resetView(this.getCenter(),this.getZoom())},_findEventTargets:function(t,e){for(var i,n=[],o="mouseout"===e||"mouseover"===e,s=t.target||t.srcElement,r=!1;s;){if((i=this._targets[h(s)])&&("click"===e||"preclick"===e)&&this._draggableMoved(i)){r=!0;break}if(i&&i.listens(e,!0)){if(o&&!We(s,t))break;if(n.push(i),o)break}if(s===this._container)break;s=s.parentNode}return n=n.length||r||o||!this.listens(e,!0)?n:[this]},_isClickDisabled:function(t){for(;t&&t!==this._container;){if(t._leaflet_disable_click)return!0;t=t.parentNode}},_handleDOMEvent:function(t){var e,i=t.target||t.srcElement;!this._loaded||i._leaflet_disable_events||"click"===t.type&&this._isClickDisabled(i)||("mousedown"===(e=t.type)&&Me(i),this._fireDOMEvent(t,e))},_mouseEvents:["click","dblclick","mouseover","mouseout","contextmenu"],_fireDOMEvent:function(t,e,i){"click"===t.type&&((a=l({},t)).type="preclick",this._fireDOMEvent(a,a.type,i));var n=this._findEventTargets(t,e);if(i){for(var o=[],s=0;s<i.length;s++)i[s].listens(e,!0)&&o.push(i[s]);n=o.concat(n)}if(n.length){"contextmenu"===e&&O(t);var r,a=n[0],h={originalEvent:t};for("keypress"!==t.type&&"keydown"!==t.type&&"keyup"!==t.type&&(r=a.getLatLng&&(!a._radius||a._radius<=10),h.containerPoint=r?this.latLngToContainerPoint(a.getLatLng()):this.mouseEventToContainerPoint(t),h.layerPoint=this.containerPointToLayerPoint(h.containerPoint),h.latlng=r?a.getLatLng():this.layerPointToLatLng(h.layerPoint)),s=0;s<n.length;s++)if(n[s].fire(e,h,!0),h.originalEvent._stopped||!1===n[s].options.bubblingMouseEvents&&-1!==G(this._mouseEvents,e))return}},_draggableMoved:function(t){return(t=t.dragging&&t.dragging.enabled()?t:this).dragging&&t.dragging.moved()||this.boxZoom&&this.boxZoom.moved()},_clearHandlers:function(){for(var t=0,e=this._handlers.length;t<e;t++)this._handlers[t].disable()},whenReady:function(t,e){return this._loaded?t.call(e||this,{target:this}):this.on("load",t,e),this},_getMapPanePos:function(){return Pe(this._mapPane)||new p(0,0)},_moved:function(){var t=this._getMapPanePos();return t&&!t.equals([0,0])},_getTopLeftPoint:function(t,e){return(t&&void 0!==e?this._getNewPixelOrigin(t,e):this.getPixelOrigin()).subtract(this._getMapPanePos())},_getNewPixelOrigin:function(t,e){var i=this.getSize()._divideBy(2);return this.project(t,e)._subtract(i)._add(this._getMapPanePos())._round()},_latLngToNewLayerPoint:function(t,e,i){i=this._getNewPixelOrigin(i,e);return this.project(t,e)._subtract(i)},_latLngBoundsToNewLayerBounds:function(t,e,i){i=this._getNewPixelOrigin(i,e);return _([this.project(t.getSouthWest(),e)._subtract(i),this.project(t.getNorthWest(),e)._subtract(i),this.project(t.getSouthEast(),e)._subtract(i),this.project(t.getNorthEast(),e)._subtract(i)])},_getCenterLayerPoint:function(){return this.containerPointToLayerPoint(this.getSize()._divideBy(2))},_getCenterOffset:function(t){return this.latLngToLayerPoint(t).subtract(this._getCenterLayerPoint())},_limitCenter:function(t,e,i){var n,o;return!i||(n=this.project(t,e),o=this.getSize().divideBy(2),o=new f(n.subtract(o),n.add(o)),o=this._getBoundsOffset(o,i,e),Math.abs(o.x)<=1&&Math.abs(o.y)<=1)?t:this.unproject(n.add(o),e)},_limitOffset:function(t,e){var i;return e?(i=new f((i=this.getPixelBounds()).min.add(t),i.max.add(t)),t.add(this._getBoundsOffset(i,e))):t},_getBoundsOffset:function(t,e,i){e=_(this.project(e.getNorthEast(),i),this.project(e.getSouthWest(),i)),i=e.min.subtract(t.min),e=e.max.subtract(t.max);return new p(this._rebound(i.x,-e.x),this._rebound(i.y,-e.y))},_rebound:function(t,e){return 0<t+e?Math.round(t-e)/2:Math.max(0,Math.ceil(t))-Math.max(0,Math.floor(e))},_limitZoom:function(t){var e=this.getMinZoom(),i=this.getMaxZoom(),n=b.any3d?this.options.zoomSnap:1;return n&&(t=Math.round(t/n)*n),Math.max(e,Math.min(i,t))},_onPanTransitionStep:function(){this.fire("move")},_onPanTransitionEnd:function(){z(this._mapPane,"leaflet-pan-anim"),this.fire("moveend")},_tryAnimatedPan:function(t,e){t=this._getCenterOffset(t)._trunc();return!(!0!==(e&&e.animate)&&!this.getSize().contains(t))&&(this.panBy(t,e),!0)},_createAnimProxy:function(){var t=this._proxy=P("div","leaflet-proxy leaflet-zoom-animated");this._panes.mapPane.appendChild(t),this.on("zoomanim",function(t){var e=ue,i=this._proxy.style[e];be(this._proxy,this.project(t.center,t.zoom),this.getZoomScale(t.zoom,1)),i===this._proxy.style[e]&&this._animatingZoom&&this._onZoomTransitionEnd()},this),this.on("load moveend",this._animMoveEnd,this),this._on("unload",this._destroyAnimProxy,this)},_destroyAnimProxy:function(){T(this._proxy),this.off("load moveend",this._animMoveEnd,this),delete this._proxy},_animMoveEnd:function(){var t=this.getCenter(),e=this.getZoom();be(this._proxy,this.project(t,e),this.getZoomScale(e,1))},_catchTransitionEnd:function(t){this._animatingZoom&&0<=t.propertyName.indexOf("transform")&&this._onZoomTransitionEnd()},_nothingToAnimate:function(){return!this._container.getElementsByClassName("leaflet-zoom-animated").length},_tryAnimatedZoom:function(t,e,i){if(!this._animatingZoom){if(i=i||{},!this._zoomAnimated||!1===i.animate||this._nothingToAnimate()||Math.abs(e-this._zoom)>this.options.zoomAnimationThreshold)return!1;var n=this.getZoomScale(e),n=this._getCenterOffset(t)._divideBy(1-1/n);if(!0!==i.animate&&!this.getSize().contains(n))return!1;x(function(){this._moveStart(!0,i.noMoveStart||!1)._animateZoom(t,e,!0)},this)}return!0},_animateZoom:function(t,e,i,n){this._mapPane&&(i&&(this._animatingZoom=!0,this._animateToCenter=t,this._animateToZoom=e,M(this._mapPane,"leaflet-zoom-anim")),this.fire("zoomanim",{center:t,zoom:e,noUpdate:n}),this._tempFireZoomEvent||(this._tempFireZoomEvent=this._zoom!==this._animateToZoom),this._move(this._animateToCenter,this._animateToZoom,void 0,!0),setTimeout(a(this._onZoomTransitionEnd,this),250))},_onZoomTransitionEnd:function(){this._animatingZoom&&(this._mapPane&&z(this._mapPane,"leaflet-zoom-anim"),this._animatingZoom=!1,this._move(this._animateToCenter,this._animateToZoom,void 0,!0),this._tempFireZoomEvent&&this.fire("zoom"),delete this._tempFireZoomEvent,this.fire("move"),this._moveEnd(!0))}});function Ue(t){return new B(t)}var B=et.extend({options:{position:"topright"},initialize:function(t){c(this,t)},getPosition:function(){return this.options.position},setPosition:function(t){var e=this._map;return e&&e.removeControl(this),this.options.position=t,e&&e.addControl(this),this},getContainer:function(){return this._container},addTo:function(t){this.remove(),this._map=t;var e=this._container=this.onAdd(t),i=this.getPosition(),t=t._controlCorners[i];return M(e,"leaflet-control"),-1!==i.indexOf("bottom")?t.insertBefore(e,t.firstChild):t.appendChild(e),this._map.on("unload",this.remove,this),this},remove:function(){return this._map&&(T(this._container),this.onRemove&&this.onRemove(this._map),this._map.off("unload",this.remove,this),this._map=null),this},_refocusOnMap:function(t){this._map&&t&&0<t.screenX&&0<t.screenY&&this._map.getContainer().focus()}}),Ve=(A.include({addControl:function(t){return t.addTo(this),this},removeControl:function(t){return t.remove(),this},_initControlPos:function(){var i=this._controlCorners={},n="leaflet-",o=this._controlContainer=P("div",n+"control-container",this._container);function t(t,e){i[t+e]=P("div",n+t+" "+n+e,o)}t("top","left"),t("top","right"),t("bottom","left"),t("bottom","right")},_clearControlPos:function(){for(var t in this._controlCorners)T(this._controlCorners[t]);T(this._controlContainer),delete this._controlCorners,delete this._controlContainer}}),B.extend({options:{collapsed:!0,position:"topright",autoZIndex:!0,hideSingleBase:!1,sortLayers:!1,sortFunction:function(t,e,i,n){return i<n?-1:n<i?1:0}},initialize:function(t,e,i){for(var n in c(this,i),this._layerControlInputs=[],this._layers=[],this._lastZIndex=0,this._handlingClick=!1,this._preventClick=!1,t)this._addLayer(t[n],n);for(n in e)this._addLayer(e[n],n,!0)},onAdd:function(t){this._initLayout(),this._update(),(this._map=t).on("zoomend",this._checkDisabledLayers,this);for(var e=0;e<this._layers.length;e++)this._layers[e].layer.on("add remove",this._onLayerChange,this);return this._container},addTo:function(t){return B.prototype.addTo.call(this,t),this._expandIfNotCollapsed()},onRemove:function(){this._map.off("zoomend",this._checkDisabledLayers,this);for(var t=0;t<this._layers.length;t++)this._layers[t].layer.off("add remove",this._onLayerChange,this)},addBaseLayer:function(t,e){return this._addLayer(t,e),this._map?this._update():this},addOverlay:function(t,e){return this._addLayer(t,e,!0),this._map?this._update():this},removeLayer:function(t){t.off("add remove",this._onLayerChange,this);t=this._getLayer(h(t));return t&&this._layers.splice(this._layers.indexOf(t),1),this._map?this._update():this},expand:function(){M(this._container,"leaflet-control-layers-expanded"),this._section.style.height=null;var t=this._map.getSize().y-(this._container.offsetTop+50);return t<this._section.clientHeight?(M(this._section,"leaflet-control-layers-scrollbar"),this._section.style.height=t+"px"):z(this._section,"leaflet-control-layers-scrollbar"),this._checkDisabledLayers(),this},collapse:function(){return z(this._container,"leaflet-control-layers-expanded"),this},_initLayout:function(){var t="leaflet-control-layers",e=this._container=P("div",t),i=this.options.collapsed,n=(e.setAttribute("aria-haspopup",!0),Ie(e),Be(e),this._section=P("section",t+"-list")),o=(i&&(this._map.on("click",this.collapse,this),S(e,{mouseenter:this._expandSafely,mouseleave:this.collapse},this)),this._layersLink=P("a",t+"-toggle",e));o.href="#",o.title="Layers",o.setAttribute("role","button"),S(o,{keydown:function(t){13===t.keyCode&&this._expandSafely()},click:function(t){O(t),this._expandSafely()}},this),i||this.expand(),this._baseLayersList=P("div",t+"-base",n),this._separator=P("div",t+"-separator",n),this._overlaysList=P("div",t+"-overlays",n),e.appendChild(n)},_getLayer:function(t){for(var e=0;e<this._layers.length;e++)if(this._layers[e]&&h(this._layers[e].layer)===t)return this._layers[e]},_addLayer:function(t,e,i){this._map&&t.on("add remove",this._onLayerChange,this),this._layers.push({layer:t,name:e,overlay:i}),this.options.sortLayers&&this._layers.sort(a(function(t,e){return this.options.sortFunction(t.layer,e.layer,t.name,e.name)},this)),this.options.autoZIndex&&t.setZIndex&&(this._lastZIndex++,t.setZIndex(this._lastZIndex)),this._expandIfNotCollapsed()},_update:function(){if(this._container){me(this._baseLayersList),me(this._overlaysList),this._layerControlInputs=[];for(var t,e,i,n=0,o=0;o<this._layers.length;o++)i=this._layers[o],this._addItem(i),e=e||i.overlay,t=t||!i.overlay,n+=i.overlay?0:1;this.options.hideSingleBase&&(this._baseLayersList.style.display=(t=t&&1<n)?"":"none"),this._separator.style.display=e&&t?"":"none"}return this},_onLayerChange:function(t){this._handlingClick||this._update();var e=this._getLayer(h(t.target)),t=e.overlay?"add"===t.type?"overlayadd":"overlayremove":"add"===t.type?"baselayerchange":null;t&&this._map.fire(t,e)},_createRadioElement:function(t,e){t='<input type="radio" class="leaflet-control-layers-selector" name="'+t+'"'+(e?' checked="checked"':"")+"/>",e=document.createElement("div");return e.innerHTML=t,e.firstChild},_addItem:function(t){var e,i=document.createElement("label"),n=this._map.hasLayer(t.layer),n=(t.overlay?((e=document.createElement("input")).type="checkbox",e.className="leaflet-control-layers-selector",e.defaultChecked=n):e=this._createRadioElement("leaflet-base-layers_"+h(this),n),this._layerControlInputs.push(e),e.layerId=h(t.layer),S(e,"click",this._onInputClick,this),document.createElement("span")),o=(n.innerHTML=" "+t.name,document.createElement("span"));return i.appendChild(o),o.appendChild(e),o.appendChild(n),(t.overlay?this._overlaysList:this._baseLayersList).appendChild(i),this._checkDisabledLayers(),i},_onInputClick:function(){if(!this._preventClick){var t,e,i=this._layerControlInputs,n=[],o=[];this._handlingClick=!0;for(var s=i.length-1;0<=s;s--)t=i[s],e=this._getLayer(t.layerId).layer,t.checked?n.push(e):t.checked||o.push(e);for(s=0;s<o.length;s++)this._map.hasLayer(o[s])&&this._map.removeLayer(o[s]);for(s=0;s<n.length;s++)this._map.hasLayer(n[s])||this._map.addLayer(n[s]);this._handlingClick=!1,this._refocusOnMap()}},_checkDisabledLayers:function(){for(var t,e,i=this._layerControlInputs,n=this._map.getZoom(),o=i.length-1;0<=o;o--)t=i[o],e=this._getLayer(t.layerId).layer,t.disabled=void 0!==e.options.minZoom&&n<e.options.minZoom||void 0!==e.options.maxZoom&&n>e.options.maxZoom},_expandIfNotCollapsed:function(){return this._map&&!this.options.collapsed&&this.expand(),this},_expandSafely:function(){var t=this._section,e=(this._preventClick=!0,S(t,"click",O),this.expand(),this);setTimeout(function(){k(t,"click",O),e._preventClick=!1})}})),qe=B.extend({options:{position:"topleft",zoomInText:'<span aria-hidden="true">+</span>',zoomInTitle:"Zoom in",zoomOutText:'<span aria-hidden="true">&#x2212;</span>',zoomOutTitle:"Zoom out"},onAdd:function(t){var e="leaflet-control-zoom",i=P("div",e+" leaflet-bar"),n=this.options;return this._zoomInButton=this._createButton(n.zoomInText,n.zoomInTitle,e+"-in",i,this._zoomIn),this._zoomOutButton=this._createButton(n.zoomOutText,n.zoomOutTitle,e+"-out",i,this._zoomOut),this._updateDisabled(),t.on("zoomend zoomlevelschange",this._updateDisabled,this),i},onRemove:function(t){t.off("zoomend zoomlevelschange",this._updateDisabled,this)},disable:function(){return this._disabled=!0,this._updateDisabled(),this},enable:function(){return this._disabled=!1,this._updateDisabled(),this},_zoomIn:function(t){!this._disabled&&this._map._zoom<this._map.getMaxZoom()&&this._map.zoomIn(this._map.options.zoomDelta*(t.shiftKey?3:1))},_zoomOut:function(t){!this._disabled&&this._map._zoom>this._map.getMinZoom()&&this._map.zoomOut(this._map.options.zoomDelta*(t.shiftKey?3:1))},_createButton:function(t,e,i,n,o){i=P("a",i,n);return i.innerHTML=t,i.href="#",i.title=e,i.setAttribute("role","button"),i.setAttribute("aria-label",e),Ie(i),S(i,"click",Re),S(i,"click",o,this),S(i,"click",this._refocusOnMap,this),i},_updateDisabled:function(){var t=this._map,e="leaflet-disabled";z(this._zoomInButton,e),z(this._zoomOutButton,e),this._zoomInButton.setAttribute("aria-disabled","false"),this._zoomOutButton.setAttribute("aria-disabled","false"),!this._disabled&&t._zoom!==t.getMinZoom()||(M(this._zoomOutButton,e),this._zoomOutButton.setAttribute("aria-disabled","true")),!this._disabled&&t._zoom!==t.getMaxZoom()||(M(this._zoomInButton,e),this._zoomInButton.setAttribute("aria-disabled","true"))}}),Ge=(A.mergeOptions({zoomControl:!0}),A.addInitHook(function(){this.options.zoomControl&&(this.zoomControl=new qe,this.addControl(this.zoomControl))}),B.extend({options:{position:"bottomleft",maxWidth:100,metric:!0,imperial:!0},onAdd:function(t){var e="leaflet-control-scale",i=P("div",e),n=this.options;return this._addScales(n,e+"-line",i),t.on(n.updateWhenIdle?"moveend":"move",this._update,this),t.whenReady(this._update,this),i},onRemove:function(t){t.off(this.options.updateWhenIdle?"moveend":"move",this._update,this)},_addScales:function(t,e,i){t.metric&&(this._mScale=P("div",e,i)),t.imperial&&(this._iScale=P("div",e,i))},_update:function(){var t=this._map,e=t.getSize().y/2,t=t.distance(t.containerPointToLatLng([0,e]),t.containerPointToLatLng([this.options.maxWidth,e]));this._updateScales(t)},_updateScales:function(t){this.options.metric&&t&&this._updateMetric(t),this.options.imperial&&t&&this._updateImperial(t)},_updateMetric:function(t){var e=this._getRoundNum(t);this._updateScale(this._mScale,e<1e3?e+" m":e/1e3+" km",e/t)},_updateImperial:function(t){var e,i,t=3.2808399*t;5280<t?(i=this._getRoundNum(e=t/5280),this._updateScale(this._iScale,i+" mi",i/e)):(i=this._getRoundNum(t),this._updateScale(this._iScale,i+" ft",i/t))},_updateScale:function(t,e,i){t.style.width=Math.round(this.options.maxWidth*i)+"px",t.innerHTML=e},_getRoundNum:function(t){var e=Math.pow(10,(Math.floor(t)+"").length-1),t=t/e;return e*(t=10<=t?10:5<=t?5:3<=t?3:2<=t?2:1)}})),Ke=B.extend({options:{position:"bottomright",prefix:'<a href="https://leafletjs.com" title="A JavaScript library for interactive maps">'+(b.inlineSvg?'<svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" width="12" height="8" viewBox="0 0 12 8" class="leaflet-attribution-flag"><path fill="#4C7BE1" d="M0 0h12v4H0z"/><path fill="#FFD500" d="M0 4h12v3H0z"/><path fill="#E0BC00" d="M0 7h12v1H0z"/></svg> ':"")+"Leaflet</a>"},initialize:function(t){c(this,t),this._attributions={}},onAdd:function(t){for(var e in(t.attributionControl=this)._container=P("div","leaflet-control-attribution"),Ie(this._container),t._layers)t._layers[e].getAttribution&&this.addAttribution(t._layers[e].getAttribution());return this._update(),t.on("layeradd",this._addAttribution,this),this._container},onRemove:function(t){t.off("layeradd",this._addAttribution,this)},_addAttribution:function(t){t.layer.getAttribution&&(this.addAttribution(t.layer.getAttribution()),t.layer.once("remove",function(){this.removeAttribution(t.layer.getAttribution())},this))},setPrefix:function(t){return this.options.prefix=t,this._update(),this},addAttribution:function(t){return t&&(this._attributions[t]||(this._attributions[t]=0),this._attributions[t]++,this._update()),this},removeAttribution:function(t){return t&&this._attributions[t]&&(this._attributions[t]--,this._update()),this},_update:function(){if(this._map){var t,e=[];for(t in this._attributions)this._attributions[t]&&e.push(t);var i=[];this.options.prefix&&i.push(this.options.prefix),e.length&&i.push(e.join(", ")),this._container.innerHTML=i.join(' <span aria-hidden="true">|</span> ')}}}),n=(A.mergeOptions({attributionControl:!0}),A.addInitHook(function(){this.options.attributionControl&&(new Ke).addTo(this)}),B.Layers=Ve,B.Zoom=qe,B.Scale=Ge,B.Attribution=Ke,Ue.layers=function(t,e,i){return new Ve(t,e,i)},Ue.zoom=function(t){return new qe(t)},Ue.scale=function(t){return new Ge(t)},Ue.attribution=function(t){return new Ke(t)},et.extend({initialize:function(t){this._map=t},enable:function(){return this._enabled||(this._enabled=!0,this.addHooks()),this},disable:function(){return this._enabled&&(this._enabled=!1,this.removeHooks()),this},enabled:function(){return!!this._enabled}})),ft=(n.addTo=function(t,e){return t.addHandler(e,this),this},{Events:e}),Ye=b.touch?"touchstart mousedown":"mousedown",Xe=it.extend({options:{clickTolerance:3},initialize:function(t,e,i,n){c(this,n),this._element=t,this._dragStartTarget=e||t,this._preventOutline=i},enable:function(){this._enabled||(S(this._dragStartTarget,Ye,this._onDown,this),this._enabled=!0)},disable:function(){this._enabled&&(Xe._dragging===this&&this.finishDrag(!0),k(this._dragStartTarget,Ye,this._onDown,this),this._enabled=!1,this._moved=!1)},_onDown:function(t){var e,i;this._enabled&&(this._moved=!1,ve(this._element,"leaflet-zoom-anim")||(t.touches&&1!==t.touches.length?Xe._dragging===this&&this.finishDrag():Xe._dragging||t.shiftKey||1!==t.which&&1!==t.button&&!t.touches||((Xe._dragging=this)._preventOutline&&Me(this._element),Le(),re(),this._moving||(this.fire("down"),i=t.touches?t.touches[0]:t,e=Ce(this._element),this._startPoint=new p(i.clientX,i.clientY),this._startPos=Pe(this._element),this._parentScale=Ze(e),i="mousedown"===t.type,S(document,i?"mousemove":"touchmove",this._onMove,this),S(document,i?"mouseup":"touchend touchcancel",this._onUp,this)))))},_onMove:function(t){var e;this._enabled&&(t.touches&&1<t.touches.length?this._moved=!0:!(e=new p((e=t.touches&&1===t.touches.length?t.touches[0]:t).clientX,e.clientY)._subtract(this._startPoint)).x&&!e.y||Math.abs(e.x)+Math.abs(e.y)<this.options.clickTolerance||(e.x/=this._parentScale.x,e.y/=this._parentScale.y,O(t),this._moved||(this.fire("dragstart"),this._moved=!0,M(document.body,"leaflet-dragging"),this._lastTarget=t.target||t.srcElement,window.SVGElementInstance&&this._lastTarget instanceof window.SVGElementInstance&&(this._lastTarget=this._lastTarget.correspondingUseElement),M(this._lastTarget,"leaflet-drag-target")),this._newPos=this._startPos.add(e),this._moving=!0,this._lastEvent=t,this._updatePosition()))},_updatePosition:function(){var t={originalEvent:this._lastEvent};this.fire("predrag",t),Z(this._element,this._newPos),this.fire("drag",t)},_onUp:function(){this._enabled&&this.finishDrag()},finishDrag:function(t){z(document.body,"leaflet-dragging"),this._lastTarget&&(z(this._lastTarget,"leaflet-drag-target"),this._lastTarget=null),k(document,"mousemove touchmove",this._onMove,this),k(document,"mouseup touchend touchcancel",this._onUp,this),Te(),ae();var e=this._moved&&this._moving;this._moving=!1,Xe._dragging=!1,e&&this.fire("dragend",{noInertia:t,distance:this._newPos.distanceTo(this._startPos)})}});function Je(t,e,i){for(var n,o,s,r,a,h,l,u=[1,4,2,8],c=0,d=t.length;c<d;c++)t[c]._code=si(t[c],e);for(s=0;s<4;s++){for(h=u[s],n=[],c=0,o=(d=t.length)-1;c<d;o=c++)r=t[c],a=t[o],r._code&h?a._code&h||((l=oi(a,r,h,e,i))._code=si(l,e),n.push(l)):(a._code&h&&((l=oi(a,r,h,e,i))._code=si(l,e),n.push(l)),n.push(r));t=n}return t}function $e(t,e){var i,n,o,s,r,a,h;if(!t||0===t.length)throw new Error("latlngs not passed");I(t)||(console.warn("latlngs are not flat! Only the first ring will be used"),t=t[0]);for(var l=w([0,0]),u=g(t),c=(u.getNorthWest().distanceTo(u.getSouthWest())*u.getNorthEast().distanceTo(u.getNorthWest())<1700&&(l=Qe(t)),t.length),d=[],_=0;_<c;_++){var p=w(t[_]);d.push(e.project(w([p.lat-l.lat,p.lng-l.lng])))}for(_=r=a=h=0,i=c-1;_<c;i=_++)n=d[_],o=d[i],s=n.y*o.x-o.y*n.x,a+=(n.x+o.x)*s,h+=(n.y+o.y)*s,r+=3*s;u=0===r?d[0]:[a/r,h/r],u=e.unproject(m(u));return w([u.lat+l.lat,u.lng+l.lng])}function Qe(t){for(var e=0,i=0,n=0,o=0;o<t.length;o++){var s=w(t[o]);e+=s.lat,i+=s.lng,n++}return w([e/n,i/n])}var ti,gt={__proto__:null,clipPolygon:Je,polygonCenter:$e,centroid:Qe};function ei(t,e){if(e&&t.length){var i=t=function(t,e){for(var i=[t[0]],n=1,o=0,s=t.length;n<s;n++)(function(t,e){var i=e.x-t.x,e=e.y-t.y;return i*i+e*e})(t[n],t[o])>e&&(i.push(t[n]),o=n);o<s-1&&i.push(t[s-1]);return i}(t,e=e*e),n=i.length,o=new(typeof Uint8Array!=void 0+""?Uint8Array:Array)(n);o[0]=o[n-1]=1,function t(e,i,n,o,s){var r,a,h,l=0;for(a=o+1;a<=s-1;a++)h=ri(e[a],e[o],e[s],!0),l<h&&(r=a,l=h);n<l&&(i[r]=1,t(e,i,n,o,r),t(e,i,n,r,s))}(i,o,e,0,n-1);var s,r=[];for(s=0;s<n;s++)o[s]&&r.push(i[s]);return r}return t.slice()}function ii(t,e,i){return Math.sqrt(ri(t,e,i,!0))}function ni(t,e,i,n,o){var s,r,a,h=n?ti:si(t,i),l=si(e,i);for(ti=l;;){if(!(h|l))return[t,e];if(h&l)return!1;a=si(r=oi(t,e,s=h||l,i,o),i),s===h?(t=r,h=a):(e=r,l=a)}}function oi(t,e,i,n,o){var s,r,a=e.x-t.x,e=e.y-t.y,h=n.min,n=n.max;return 8&i?(s=t.x+a*(n.y-t.y)/e,r=n.y):4&i?(s=t.x+a*(h.y-t.y)/e,r=h.y):2&i?(s=n.x,r=t.y+e*(n.x-t.x)/a):1&i&&(s=h.x,r=t.y+e*(h.x-t.x)/a),new p(s,r,o)}function si(t,e){var i=0;return t.x<e.min.x?i|=1:t.x>e.max.x&&(i|=2),t.y<e.min.y?i|=4:t.y>e.max.y&&(i|=8),i}function ri(t,e,i,n){var o=e.x,e=e.y,s=i.x-o,r=i.y-e,a=s*s+r*r;return 0<a&&(1<(a=((t.x-o)*s+(t.y-e)*r)/a)?(o=i.x,e=i.y):0<a&&(o+=s*a,e+=r*a)),s=t.x-o,r=t.y-e,n?s*s+r*r:new p(o,e)}function I(t){return!d(t[0])||"object"!=typeof t[0][0]&&void 0!==t[0][0]}function ai(t){return console.warn("Deprecated use of _flat, please use L.LineUtil.isFlat instead."),I(t)}function hi(t,e){var i,n,o,s,r,a;if(!t||0===t.length)throw new Error("latlngs not passed");I(t)||(console.warn("latlngs are not flat! Only the first ring will be used"),t=t[0]);for(var h=w([0,0]),l=g(t),u=(l.getNorthWest().distanceTo(l.getSouthWest())*l.getNorthEast().distanceTo(l.getNorthWest())<1700&&(h=Qe(t)),t.length),c=[],d=0;d<u;d++){var _=w(t[d]);c.push(e.project(w([_.lat-h.lat,_.lng-h.lng])))}for(i=d=0;d<u-1;d++)i+=c[d].distanceTo(c[d+1])/2;if(0===i)a=c[0];else for(n=d=0;d<u-1;d++)if(o=c[d],s=c[d+1],i<(n+=r=o.distanceTo(s))){a=[s.x-(r=(n-i)/r)*(s.x-o.x),s.y-r*(s.y-o.y)];break}l=e.unproject(m(a));return w([l.lat+h.lat,l.lng+h.lng])}var vt={__proto__:null,simplify:ei,pointToSegmentDistance:ii,closestPointOnSegment:function(t,e,i){return ri(t,e,i)},clipSegment:ni,_getEdgeIntersection:oi,_getBitCode:si,_sqClosestPointOnSegment:ri,isFlat:I,_flat:ai,polylineCenter:hi},yt={project:function(t){return new p(t.lng,t.lat)},unproject:function(t){return new v(t.y,t.x)},bounds:new f([-180,-90],[180,90])},xt={R:6378137,R_MINOR:6356752.314245179,bounds:new f([-20037508.34279,-15496570.73972],[20037508.34279,18764656.23138]),project:function(t){var e=Math.PI/180,i=this.R,n=t.lat*e,o=this.R_MINOR/i,o=Math.sqrt(1-o*o),s=o*Math.sin(n),s=Math.tan(Math.PI/4-n/2)/Math.pow((1-s)/(1+s),o/2),n=-i*Math.log(Math.max(s,1e-10));return new p(t.lng*e*i,n)},unproject:function(t){for(var e,i=180/Math.PI,n=this.R,o=this.R_MINOR/n,s=Math.sqrt(1-o*o),r=Math.exp(-t.y/n),a=Math.PI/2-2*Math.atan(r),h=0,l=.1;h<15&&1e-7<Math.abs(l);h++)e=s*Math.sin(a),e=Math.pow((1-e)/(1+e),s/2),a+=l=Math.PI/2-2*Math.atan(r*e)-a;return new v(a*i,t.x*i/n)}},wt={__proto__:null,LonLat:yt,Mercator:xt,SphericalMercator:rt},Pt=l({},st,{code:"EPSG:3395",projection:xt,transformation:ht(bt=.5/(Math.PI*xt.R),.5,-bt,.5)}),li=l({},st,{code:"EPSG:4326",projection:yt,transformation:ht(1/180,1,-1/180,.5)}),Lt=l({},ot,{projection:yt,transformation:ht(1,0,-1,0),scale:function(t){return Math.pow(2,t)},zoom:function(t){return Math.log(t)/Math.LN2},distance:function(t,e){var i=e.lng-t.lng,e=e.lat-t.lat;return Math.sqrt(i*i+e*e)},infinite:!0}),o=(ot.Earth=st,ot.EPSG3395=Pt,ot.EPSG3857=lt,ot.EPSG900913=ut,ot.EPSG4326=li,ot.Simple=Lt,it.extend({options:{pane:"overlayPane",attribution:null,bubblingMouseEvents:!0},addTo:function(t){return t.addLayer(this),this},remove:function(){return this.removeFrom(this._map||this._mapToAdd)},removeFrom:function(t){return t&&t.removeLayer(this),this},getPane:function(t){return this._map.getPane(t?this.options[t]||t:this.options.pane)},addInteractiveTarget:function(t){return this._map._targets[h(t)]=this},removeInteractiveTarget:function(t){return delete this._map._targets[h(t)],this},getAttribution:function(){return this.options.attribution},_layerAdd:function(t){var e,i=t.target;i.hasLayer(this)&&(this._map=i,this._zoomAnimated=i._zoomAnimated,this.getEvents&&(e=this.getEvents(),i.on(e,this),this.once("remove",function(){i.off(e,this)},this)),this.onAdd(i),this.fire("add"),i.fire("layeradd",{layer:this}))}})),ui=(A.include({addLayer:function(t){var e;if(t._layerAdd)return e=h(t),this._layers[e]||((this._layers[e]=t)._mapToAdd=this,t.beforeAdd&&t.beforeAdd(this),this.whenReady(t._layerAdd,t)),this;throw new Error("The provided object is not a Layer.")},removeLayer:function(t){var e=h(t);return this._layers[e]&&(this._loaded&&t.onRemove(this),delete this._layers[e],this._loaded&&(this.fire("layerremove",{layer:t}),t.fire("remove")),t._map=t._mapToAdd=null),this},hasLayer:function(t){return h(t)in this._layers},eachLayer:function(t,e){for(var i in this._layers)t.call(e,this._layers[i]);return this},_addLayers:function(t){for(var e=0,i=(t=t?d(t)?t:[t]:[]).length;e<i;e++)this.addLayer(t[e])},_addZoomLimit:function(t){isNaN(t.options.maxZoom)&&isNaN(t.options.minZoom)||(this._zoomBoundLayers[h(t)]=t,this._updateZoomLevels())},_removeZoomLimit:function(t){t=h(t);this._zoomBoundLayers[t]&&(delete this._zoomBoundLayers[t],this._updateZoomLevels())},_updateZoomLevels:function(){var t,e=1/0,i=-1/0,n=this._getZoomSpan();for(t in this._zoomBoundLayers)var o=this._zoomBoundLayers[t].options,e=void 0===o.minZoom?e:Math.min(e,o.minZoom),i=void 0===o.maxZoom?i:Math.max(i,o.maxZoom);this._layersMaxZoom=i===-1/0?void 0:i,this._layersMinZoom=e===1/0?void 0:e,n!==this._getZoomSpan()&&this.fire("zoomlevelschange"),void 0===this.options.maxZoom&&this._layersMaxZoom&&this.getZoom()>this._layersMaxZoom&&this.setZoom(this._layersMaxZoom),void 0===this.options.minZoom&&this._layersMinZoom&&this.getZoom()<this._layersMinZoom&&this.setZoom(this._layersMinZoom)}}),o.extend({initialize:function(t,e){var i,n;if(c(this,e),this._layers={},t)for(i=0,n=t.length;i<n;i++)this.addLayer(t[i])},addLayer:function(t){var e=this.getLayerId(t);return this._layers[e]=t,this._map&&this._map.addLayer(t),this},removeLayer:function(t){t=t in this._layers?t:this.getLayerId(t);return this._map&&this._layers[t]&&this._map.removeLayer(this._layers[t]),delete this._layers[t],this},hasLayer:function(t){return("number"==typeof t?t:this.getLayerId(t))in this._layers},clearLayers:function(){return this.eachLayer(this.removeLayer,this)},invoke:function(t){var e,i,n=Array.prototype.slice.call(arguments,1);for(e in this._layers)(i=this._layers[e])[t]&&i[t].apply(i,n);return this},onAdd:function(t){this.eachLayer(t.addLayer,t)},onRemove:function(t){this.eachLayer(t.removeLayer,t)},eachLayer:function(t,e){for(var i in this._layers)t.call(e,this._layers[i]);return this},getLayer:function(t){return this._layers[t]},getLayers:function(){var t=[];return this.eachLayer(t.push,t),t},setZIndex:function(t){return this.invoke("setZIndex",t)},getLayerId:h})),ci=ui.extend({addLayer:function(t){return this.hasLayer(t)?this:(t.addEventParent(this),ui.prototype.addLayer.call(this,t),this.fire("layeradd",{layer:t}))},removeLayer:function(t){return this.hasLayer(t)?((t=t in this._layers?this._layers[t]:t).removeEventParent(this),ui.prototype.removeLayer.call(this,t),this.fire("layerremove",{layer:t})):this},setStyle:function(t){return this.invoke("setStyle",t)},bringToFront:function(){return this.invoke("bringToFront")},bringToBack:function(){return this.invoke("bringToBack")},getBounds:function(){var t,e=new s;for(t in this._layers){var i=this._layers[t];e.extend(i.getBounds?i.getBounds():i.getLatLng())}return e}}),di=et.extend({options:{popupAnchor:[0,0],tooltipAnchor:[0,0],crossOrigin:!1},initialize:function(t){c(this,t)},createIcon:function(t){return this._createIcon("icon",t)},createShadow:function(t){return this._createIcon("shadow",t)},_createIcon:function(t,e){var i=this._getIconUrl(t);if(i)return i=this._createImg(i,e&&"IMG"===e.tagName?e:null),this._setIconStyles(i,t),!this.options.crossOrigin&&""!==this.options.crossOrigin||(i.crossOrigin=!0===this.options.crossOrigin?"":this.options.crossOrigin),i;if("icon"===t)throw new Error("iconUrl not set in Icon options (see the docs).");return null},_setIconStyles:function(t,e){var i=this.options,n=i[e+"Size"],n=m(n="number"==typeof n?[n,n]:n),o=m("shadow"===e&&i.shadowAnchor||i.iconAnchor||n&&n.divideBy(2,!0));t.className="leaflet-marker-"+e+" "+(i.className||""),o&&(t.style.marginLeft=-o.x+"px",t.style.marginTop=-o.y+"px"),n&&(t.style.width=n.x+"px",t.style.height=n.y+"px")},_createImg:function(t,e){return(e=e||document.createElement("img")).src=t,e},_getIconUrl:function(t){return b.retina&&this.options[t+"RetinaUrl"]||this.options[t+"Url"]}});var _i=di.extend({options:{iconUrl:"marker-icon.png",iconRetinaUrl:"marker-icon-2x.png",shadowUrl:"marker-shadow.png",iconSize:[25,41],iconAnchor:[12,41],popupAnchor:[1,-34],tooltipAnchor:[16,-28],shadowSize:[41,41]},_getIconUrl:function(t){return"string"!=typeof _i.imagePath&&(_i.imagePath=this._detectIconPath()),(this.options.imagePath||_i.imagePath)+di.prototype._getIconUrl.call(this,t)},_stripUrl:function(t){function e(t,e,i){return(e=e.exec(t))&&e[i]}return(t=e(t,/^url\((['"])?(.+)\1\)$/,2))&&e(t,/^(.*)marker-icon\.png$/,1)},_detectIconPath:function(){var t=P("div","leaflet-default-icon-path",document.body),e=pe(t,"background-image")||pe(t,"backgroundImage");return document.body.removeChild(t),(e=this._stripUrl(e))?e:(t=document.querySelector('link[href$="leaflet.css"]'))?t.href.substring(0,t.href.length-"leaflet.css".length-1):""}}),pi=n.extend({initialize:function(t){this._marker=t},addHooks:function(){var t=this._marker._icon;this._draggable||(this._draggable=new Xe(t,t,!0)),this._draggable.on({dragstart:this._onDragStart,predrag:this._onPreDrag,drag:this._onDrag,dragend:this._onDragEnd},this).enable(),M(t,"leaflet-marker-draggable")},removeHooks:function(){this._draggable.off({dragstart:this._onDragStart,predrag:this._onPreDrag,drag:this._onDrag,dragend:this._onDragEnd},this).disable(),this._marker._icon&&z(this._marker._icon,"leaflet-marker-draggable")},moved:function(){return this._draggable&&this._draggable._moved},_adjustPan:function(t){var e=this._marker,i=e._map,n=this._marker.options.autoPanSpeed,o=this._marker.options.autoPanPadding,s=Pe(e._icon),r=i.getPixelBounds(),a=i.getPixelOrigin(),a=_(r.min._subtract(a).add(o),r.max._subtract(a).subtract(o));a.contains(s)||(o=m((Math.max(a.max.x,s.x)-a.max.x)/(r.max.x-a.max.x)-(Math.min(a.min.x,s.x)-a.min.x)/(r.min.x-a.min.x),(Math.max(a.max.y,s.y)-a.max.y)/(r.max.y-a.max.y)-(Math.min(a.min.y,s.y)-a.min.y)/(r.min.y-a.min.y)).multiplyBy(n),i.panBy(o,{animate:!1}),this._draggable._newPos._add(o),this._draggable._startPos._add(o),Z(e._icon,this._draggable._newPos),this._onDrag(t),this._panRequest=x(this._adjustPan.bind(this,t)))},_onDragStart:function(){this._oldLatLng=this._marker.getLatLng(),this._marker.closePopup&&this._marker.closePopup(),this._marker.fire("movestart").fire("dragstart")},_onPreDrag:function(t){this._marker.options.autoPan&&(r(this._panRequest),this._panRequest=x(this._adjustPan.bind(this,t)))},_onDrag:function(t){var e=this._marker,i=e._shadow,n=Pe(e._icon),o=e._map.layerPointToLatLng(n);i&&Z(i,n),e._latlng=o,t.latlng=o,t.oldLatLng=this._oldLatLng,e.fire("move",t).fire("drag",t)},_onDragEnd:function(t){r(this._panRequest),delete this._oldLatLng,this._marker.fire("moveend").fire("dragend",t)}}),mi=o.extend({options:{icon:new _i,interactive:!0,keyboard:!0,title:"",alt:"Marker",zIndexOffset:0,opacity:1,riseOnHover:!1,riseOffset:250,pane:"markerPane",shadowPane:"shadowPane",bubblingMouseEvents:!1,autoPanOnFocus:!0,draggable:!1,autoPan:!1,autoPanPadding:[50,50],autoPanSpeed:10},initialize:function(t,e){c(this,e),this._latlng=w(t)},onAdd:function(t){this._zoomAnimated=this._zoomAnimated&&t.options.markerZoomAnimation,this._zoomAnimated&&t.on("zoomanim",this._animateZoom,this),this._initIcon(),this.update()},onRemove:function(t){this.dragging&&this.dragging.enabled()&&(this.options.draggable=!0,this.dragging.removeHooks()),delete this.dragging,this._zoomAnimated&&t.off("zoomanim",this._animateZoom,this),this._removeIcon(),this._removeShadow()},getEvents:function(){return{zoom:this.update,viewreset:this.update}},getLatLng:function(){return this._latlng},setLatLng:function(t){var e=this._latlng;return this._latlng=w(t),this.update(),this.fire("move",{oldLatLng:e,latlng:this._latlng})},setZIndexOffset:function(t){return this.options.zIndexOffset=t,this.update()},getIcon:function(){return this.options.icon},setIcon:function(t){return this.options.icon=t,this._map&&(this._initIcon(),this.update()),this._popup&&this.bindPopup(this._popup,this._popup.options),this},getElement:function(){return this._icon},update:function(){var t;return this._icon&&this._map&&(t=this._map.latLngToLayerPoint(this._latlng).round(),this._setPos(t)),this},_initIcon:function(){var t=this.options,e="leaflet-zoom-"+(this._zoomAnimated?"animated":"hide"),i=t.icon.createIcon(this._icon),n=!1,i=(i!==this._icon&&(this._icon&&this._removeIcon(),n=!0,t.title&&(i.title=t.title),"IMG"===i.tagName&&(i.alt=t.alt||"")),M(i,e),t.keyboard&&(i.tabIndex="0",i.setAttribute("role","button")),this._icon=i,t.riseOnHover&&this.on({mouseover:this._bringToFront,mouseout:this._resetZIndex}),this.options.autoPanOnFocus&&S(i,"focus",this._panOnFocus,this),t.icon.createShadow(this._shadow)),o=!1;i!==this._shadow&&(this._removeShadow(),o=!0),i&&(M(i,e),i.alt=""),this._shadow=i,t.opacity<1&&this._updateOpacity(),n&&this.getPane().appendChild(this._icon),this._initInteraction(),i&&o&&this.getPane(t.shadowPane).appendChild(this._shadow)},_removeIcon:function(){this.options.riseOnHover&&this.off({mouseover:this._bringToFront,mouseout:this._resetZIndex}),this.options.autoPanOnFocus&&k(this._icon,"focus",this._panOnFocus,this),T(this._icon),this.removeInteractiveTarget(this._icon),this._icon=null},_removeShadow:function(){this._shadow&&T(this._shadow),this._shadow=null},_setPos:function(t){this._icon&&Z(this._icon,t),this._shadow&&Z(this._shadow,t),this._zIndex=t.y+this.options.zIndexOffset,this._resetZIndex()},_updateZIndex:function(t){this._icon&&(this._icon.style.zIndex=this._zIndex+t)},_animateZoom:function(t){t=this._map._latLngToNewLayerPoint(this._latlng,t.zoom,t.center).round();this._setPos(t)},_initInteraction:function(){var t;this.options.interactive&&(M(this._icon,"leaflet-interactive"),this.addInteractiveTarget(this._icon),pi&&(t=this.options.draggable,this.dragging&&(t=this.dragging.enabled(),this.dragging.disable()),this.dragging=new pi(this),t&&this.dragging.enable()))},setOpacity:function(t){return this.options.opacity=t,this._map&&this._updateOpacity(),this},_updateOpacity:function(){var t=this.options.opacity;this._icon&&C(this._icon,t),this._shadow&&C(this._shadow,t)},_bringToFront:function(){this._updateZIndex(this.options.riseOffset)},_resetZIndex:function(){this._updateZIndex(0)},_panOnFocus:function(){var t,e,i=this._map;i&&(t=(e=this.options.icon.options).iconSize?m(e.iconSize):m(0,0),e=e.iconAnchor?m(e.iconAnchor):m(0,0),i.panInside(this._latlng,{paddingTopLeft:e,paddingBottomRight:t.subtract(e)}))},_getPopupAnchor:function(){return this.options.icon.options.popupAnchor},_getTooltipAnchor:function(){return this.options.icon.options.tooltipAnchor}});var fi=o.extend({options:{stroke:!0,color:"#3388ff",weight:3,opacity:1,lineCap:"round",lineJoin:"round",dashArray:null,dashOffset:null,fill:!1,fillColor:null,fillOpacity:.2,fillRule:"evenodd",interactive:!0,bubblingMouseEvents:!0},beforeAdd:function(t){this._renderer=t.getRenderer(this)},onAdd:function(){this._renderer._initPath(this),this._reset(),this._renderer._addPath(this)},onRemove:function(){this._renderer._removePath(this)},redraw:function(){return this._map&&this._renderer._updatePath(this),this},setStyle:function(t){return c(this,t),this._renderer&&(this._renderer._updateStyle(this),this.options.stroke&&t&&Object.prototype.hasOwnProperty.call(t,"weight")&&this._updateBounds()),this},bringToFront:function(){return this._renderer&&this._renderer._bringToFront(this),this},bringToBack:function(){return this._renderer&&this._renderer._bringToBack(this),this},getElement:function(){return this._path},_reset:function(){this._project(),this._update()},_clickTolerance:function(){return(this.options.stroke?this.options.weight/2:0)+(this._renderer.options.tolerance||0)}}),gi=fi.extend({options:{fill:!0,radius:10},initialize:function(t,e){c(this,e),this._latlng=w(t),this._radius=this.options.radius},setLatLng:function(t){var e=this._latlng;return this._latlng=w(t),this.redraw(),this.fire("move",{oldLatLng:e,latlng:this._latlng})},getLatLng:function(){return this._latlng},setRadius:function(t){return this.options.radius=this._radius=t,this.redraw()},getRadius:function(){return this._radius},setStyle:function(t){var e=t&&t.radius||this._radius;return fi.prototype.setStyle.call(this,t),this.setRadius(e),this},_project:function(){this._point=this._map.latLngToLayerPoint(this._latlng),this._updateBounds()},_updateBounds:function(){var t=this._radius,e=this._radiusY||t,i=this._clickTolerance(),t=[t+i,e+i];this._pxBounds=new f(this._point.subtract(t),this._point.add(t))},_update:function(){this._map&&this._updatePath()},_updatePath:function(){this._renderer._updateCircle(this)},_empty:function(){return this._radius&&!this._renderer._bounds.intersects(this._pxBounds)},_containsPoint:function(t){return t.distanceTo(this._point)<=this._radius+this._clickTolerance()}});var vi=gi.extend({initialize:function(t,e,i){if(c(this,e="number"==typeof e?l({},i,{radius:e}):e),this._latlng=w(t),isNaN(this.options.radius))throw new Error("Circle radius cannot be NaN");this._mRadius=this.options.radius},setRadius:function(t){return this._mRadius=t,this.redraw()},getRadius:function(){return this._mRadius},getBounds:function(){var t=[this._radius,this._radiusY||this._radius];return new s(this._map.layerPointToLatLng(this._point.subtract(t)),this._map.layerPointToLatLng(this._point.add(t)))},setStyle:fi.prototype.setStyle,_project:function(){var t,e,i,n,o,s=this._latlng.lng,r=this._latlng.lat,a=this._map,h=a.options.crs;h.distance===st.distance?(n=Math.PI/180,o=this._mRadius/st.R/n,t=a.project([r+o,s]),e=a.project([r-o,s]),e=t.add(e).divideBy(2),i=a.unproject(e).lat,n=Math.acos((Math.cos(o*n)-Math.sin(r*n)*Math.sin(i*n))/(Math.cos(r*n)*Math.cos(i*n)))/n,!isNaN(n)&&0!==n||(n=o/Math.cos(Math.PI/180*r)),this._point=e.subtract(a.getPixelOrigin()),this._radius=isNaN(n)?0:e.x-a.project([i,s-n]).x,this._radiusY=e.y-t.y):(o=h.unproject(h.project(this._latlng).subtract([this._mRadius,0])),this._point=a.latLngToLayerPoint(this._latlng),this._radius=this._point.x-a.latLngToLayerPoint(o).x),this._updateBounds()}});var yi=fi.extend({options:{smoothFactor:1,noClip:!1},initialize:function(t,e){c(this,e),this._setLatLngs(t)},getLatLngs:function(){return this._latlngs},setLatLngs:function(t){return this._setLatLngs(t),this.redraw()},isEmpty:function(){return!this._latlngs.length},closestLayerPoint:function(t){for(var e=1/0,i=null,n=ri,o=0,s=this._parts.length;o<s;o++)for(var r=this._parts[o],a=1,h=r.length;a<h;a++){var l,u,c=n(t,l=r[a-1],u=r[a],!0);c<e&&(e=c,i=n(t,l,u))}return i&&(i.distance=Math.sqrt(e)),i},getCenter:function(){if(this._map)return hi(this._defaultShape(),this._map.options.crs);throw new Error("Must add layer to map before using getCenter()")},getBounds:function(){return this._bounds},addLatLng:function(t,e){return e=e||this._defaultShape(),t=w(t),e.push(t),this._bounds.extend(t),this.redraw()},_setLatLngs:function(t){this._bounds=new s,this._latlngs=this._convertLatLngs(t)},_defaultShape:function(){return I(this._latlngs)?this._latlngs:this._latlngs[0]},_convertLatLngs:function(t){for(var e=[],i=I(t),n=0,o=t.length;n<o;n++)i?(e[n]=w(t[n]),this._bounds.extend(e[n])):e[n]=this._convertLatLngs(t[n]);return e},_project:function(){var t=new f;this._rings=[],this._projectLatlngs(this._latlngs,this._rings,t),this._bounds.isValid()&&t.isValid()&&(this._rawPxBounds=t,this._updateBounds())},_updateBounds:function(){var t=this._clickTolerance(),t=new p(t,t);this._rawPxBounds&&(this._pxBounds=new f([this._rawPxBounds.min.subtract(t),this._rawPxBounds.max.add(t)]))},_projectLatlngs:function(t,e,i){var n,o,s=t[0]instanceof v,r=t.length;if(s){for(o=[],n=0;n<r;n++)o[n]=this._map.latLngToLayerPoint(t[n]),i.extend(o[n]);e.push(o)}else for(n=0;n<r;n++)this._projectLatlngs(t[n],e,i)},_clipPoints:function(){var t=this._renderer._bounds;if(this._parts=[],this._pxBounds&&this._pxBounds.intersects(t))if(this.options.noClip)this._parts=this._rings;else for(var e,i,n,o,s=this._parts,r=0,a=0,h=this._rings.length;r<h;r++)for(e=0,i=(o=this._rings[r]).length;e<i-1;e++)(n=ni(o[e],o[e+1],t,e,!0))&&(s[a]=s[a]||[],s[a].push(n[0]),n[1]===o[e+1]&&e!==i-2||(s[a].push(n[1]),a++))},_simplifyPoints:function(){for(var t=this._parts,e=this.options.smoothFactor,i=0,n=t.length;i<n;i++)t[i]=ei(t[i],e)},_update:function(){this._map&&(this._clipPoints(),this._simplifyPoints(),this._updatePath())},_updatePath:function(){this._renderer._updatePoly(this)},_containsPoint:function(t,e){var i,n,o,s,r,a,h=this._clickTolerance();if(this._pxBounds&&this._pxBounds.contains(t))for(i=0,s=this._parts.length;i<s;i++)for(n=0,o=(r=(a=this._parts[i]).length)-1;n<r;o=n++)if((e||0!==n)&&ii(t,a[o],a[n])<=h)return!0;return!1}});yi._flat=ai;var xi=yi.extend({options:{fill:!0},isEmpty:function(){return!this._latlngs.length||!this._latlngs[0].length},getCenter:function(){if(this._map)return $e(this._defaultShape(),this._map.options.crs);throw new Error("Must add layer to map before using getCenter()")},_convertLatLngs:function(t){var t=yi.prototype._convertLatLngs.call(this,t),e=t.length;return 2<=e&&t[0]instanceof v&&t[0].equals(t[e-1])&&t.pop(),t},_setLatLngs:function(t){yi.prototype._setLatLngs.call(this,t),I(this._latlngs)&&(this._latlngs=[this._latlngs])},_defaultShape:function(){return(I(this._latlngs[0])?this._latlngs:this._latlngs[0])[0]},_clipPoints:function(){var t=this._renderer._bounds,e=this.options.weight,e=new p(e,e),t=new f(t.min.subtract(e),t.max.add(e));if(this._parts=[],this._pxBounds&&this._pxBounds.intersects(t))if(this.options.noClip)this._parts=this._rings;else for(var i,n=0,o=this._rings.length;n<o;n++)(i=Je(this._rings[n],t,!0)).length&&this._parts.push(i)},_updatePath:function(){this._renderer._updatePoly(this,!0)},_containsPoint:function(t){var e,i,n,o,s,r,a,h,l=!1;if(!this._pxBounds||!this._pxBounds.contains(t))return!1;for(o=0,a=this._parts.length;o<a;o++)for(s=0,r=(h=(e=this._parts[o]).length)-1;s<h;r=s++)i=e[s],n=e[r],i.y>t.y!=n.y>t.y&&t.x<(n.x-i.x)*(t.y-i.y)/(n.y-i.y)+i.x&&(l=!l);return l||yi.prototype._containsPoint.call(this,t,!0)}});var wi=ci.extend({initialize:function(t,e){c(this,e),this._layers={},t&&this.addData(t)},addData:function(t){var e,i,n,o=d(t)?t:t.features;if(o){for(e=0,i=o.length;e<i;e++)((n=o[e]).geometries||n.geometry||n.features||n.coordinates)&&this.addData(n);return this}var s,r=this.options;return(!r.filter||r.filter(t))&&(s=bi(t,r))?(s.feature=Zi(t),s.defaultOptions=s.options,this.resetStyle(s),r.onEachFeature&&r.onEachFeature(t,s),this.addLayer(s)):this},resetStyle:function(t){return void 0===t?this.eachLayer(this.resetStyle,this):(t.options=l({},t.defaultOptions),this._setLayerStyle(t,this.options.style),this)},setStyle:function(e){return this.eachLayer(function(t){this._setLayerStyle(t,e)},this)},_setLayerStyle:function(t,e){t.setStyle&&("function"==typeof e&&(e=e(t.feature)),t.setStyle(e))}});function bi(t,e){var i,n,o,s,r="Feature"===t.type?t.geometry:t,a=r?r.coordinates:null,h=[],l=e&&e.pointToLayer,u=e&&e.coordsToLatLng||Li;if(!a&&!r)return null;switch(r.type){case"Point":return Pi(l,t,i=u(a),e);case"MultiPoint":for(o=0,s=a.length;o<s;o++)i=u(a[o]),h.push(Pi(l,t,i,e));return new ci(h);case"LineString":case"MultiLineString":return n=Ti(a,"LineString"===r.type?0:1,u),new yi(n,e);case"Polygon":case"MultiPolygon":return n=Ti(a,"Polygon"===r.type?1:2,u),new xi(n,e);case"GeometryCollection":for(o=0,s=r.geometries.length;o<s;o++){var c=bi({geometry:r.geometries[o],type:"Feature",properties:t.properties},e);c&&h.push(c)}return new ci(h);case"FeatureCollection":for(o=0,s=r.features.length;o<s;o++){var d=bi(r.features[o],e);d&&h.push(d)}return new ci(h);default:throw new Error("Invalid GeoJSON object.")}}function Pi(t,e,i,n){return t?t(e,i):new mi(i,n&&n.markersInheritOptions&&n)}function Li(t){return new v(t[1],t[0],t[2])}function Ti(t,e,i){for(var n,o=[],s=0,r=t.length;s<r;s++)n=e?Ti(t[s],e-1,i):(i||Li)(t[s]),o.push(n);return o}function Mi(t,e){return void 0!==(t=w(t)).alt?[i(t.lng,e),i(t.lat,e),i(t.alt,e)]:[i(t.lng,e),i(t.lat,e)]}function zi(t,e,i,n){for(var o=[],s=0,r=t.length;s<r;s++)o.push(e?zi(t[s],I(t[s])?0:e-1,i,n):Mi(t[s],n));return!e&&i&&0<o.length&&o.push(o[0].slice()),o}function Ci(t,e){return t.feature?l({},t.feature,{geometry:e}):Zi(e)}function Zi(t){return"Feature"===t.type||"FeatureCollection"===t.type?t:{type:"Feature",properties:{},geometry:t}}Tt={toGeoJSON:function(t){return Ci(this,{type:"Point",coordinates:Mi(this.getLatLng(),t)})}};function Si(t,e){return new wi(t,e)}mi.include(Tt),vi.include(Tt),gi.include(Tt),yi.include({toGeoJSON:function(t){var e=!I(this._latlngs);return Ci(this,{type:(e?"Multi":"")+"LineString",coordinates:zi(this._latlngs,e?1:0,!1,t)})}}),xi.include({toGeoJSON:function(t){var e=!I(this._latlngs),i=e&&!I(this._latlngs[0]),t=zi(this._latlngs,i?2:e?1:0,!0,t);return Ci(this,{type:(i?"Multi":"")+"Polygon",coordinates:t=e?t:[t]})}}),ui.include({toMultiPoint:function(e){var i=[];return this.eachLayer(function(t){i.push(t.toGeoJSON(e).geometry.coordinates)}),Ci(this,{type:"MultiPoint",coordinates:i})},toGeoJSON:function(e){var i,n,t=this.feature&&this.feature.geometry&&this.feature.geometry.type;return"MultiPoint"===t?this.toMultiPoint(e):(i="GeometryCollection"===t,n=[],this.eachLayer(function(t){t.toGeoJSON&&(t=t.toGeoJSON(e),i?n.push(t.geometry):"FeatureCollection"===(t=Zi(t)).type?n.push.apply(n,t.features):n.push(t))}),i?Ci(this,{geometries:n,type:"GeometryCollection"}):{type:"FeatureCollection",features:n})}});var Mt=Si,Ei=o.extend({options:{opacity:1,alt:"",interactive:!1,crossOrigin:!1,errorOverlayUrl:"",zIndex:1,className:""},initialize:function(t,e,i){this._url=t,this._bounds=g(e),c(this,i)},onAdd:function(){this._image||(this._initImage(),this.options.opacity<1&&this._updateOpacity()),this.options.interactive&&(M(this._image,"leaflet-interactive"),this.addInteractiveTarget(this._image)),this.getPane().appendChild(this._image),this._reset()},onRemove:function(){T(this._image),this.options.interactive&&this.removeInteractiveTarget(this._image)},setOpacity:function(t){return this.options.opacity=t,this._image&&this._updateOpacity(),this},setStyle:function(t){return t.opacity&&this.setOpacity(t.opacity),this},bringToFront:function(){return this._map&&fe(this._image),this},bringToBack:function(){return this._map&&ge(this._image),this},setUrl:function(t){return this._url=t,this._image&&(this._image.src=t),this},setBounds:function(t){return this._bounds=g(t),this._map&&this._reset(),this},getEvents:function(){var t={zoom:this._reset,viewreset:this._reset};return this._zoomAnimated&&(t.zoomanim=this._animateZoom),t},setZIndex:function(t){return this.options.zIndex=t,this._updateZIndex(),this},getBounds:function(){return this._bounds},getElement:function(){return this._image},_initImage:function(){var t="IMG"===this._url.tagName,e=this._image=t?this._url:P("img");M(e,"leaflet-image-layer"),this._zoomAnimated&&M(e,"leaflet-zoom-animated"),this.options.className&&M(e,this.options.className),e.onselectstart=u,e.onmousemove=u,e.onload=a(this.fire,this,"load"),e.onerror=a(this._overlayOnError,this,"error"),!this.options.crossOrigin&&""!==this.options.crossOrigin||(e.crossOrigin=!0===this.options.crossOrigin?"":this.options.crossOrigin),this.options.zIndex&&this._updateZIndex(),t?this._url=e.src:(e.src=this._url,e.alt=this.options.alt)},_animateZoom:function(t){var e=this._map.getZoomScale(t.zoom),t=this._map._latLngBoundsToNewLayerBounds(this._bounds,t.zoom,t.center).min;be(this._image,t,e)},_reset:function(){var t=this._image,e=new f(this._map.latLngToLayerPoint(this._bounds.getNorthWest()),this._map.latLngToLayerPoint(this._bounds.getSouthEast())),i=e.getSize();Z(t,e.min),t.style.width=i.x+"px",t.style.height=i.y+"px"},_updateOpacity:function(){C(this._image,this.options.opacity)},_updateZIndex:function(){this._image&&void 0!==this.options.zIndex&&null!==this.options.zIndex&&(this._image.style.zIndex=this.options.zIndex)},_overlayOnError:function(){this.fire("error");var t=this.options.errorOverlayUrl;t&&this._url!==t&&(this._url=t,this._image.src=t)},getCenter:function(){return this._bounds.getCenter()}}),ki=Ei.extend({options:{autoplay:!0,loop:!0,keepAspectRatio:!0,muted:!1,playsInline:!0},_initImage:function(){var t="VIDEO"===this._url.tagName,e=this._image=t?this._url:P("video");if(M(e,"leaflet-image-layer"),this._zoomAnimated&&M(e,"leaflet-zoom-animated"),this.options.className&&M(e,this.options.className),e.onselectstart=u,e.onmousemove=u,e.onloadeddata=a(this.fire,this,"load"),t){for(var i=e.getElementsByTagName("source"),n=[],o=0;o<i.length;o++)n.push(i[o].src);this._url=0<i.length?n:[e.src]}else{d(this._url)||(this._url=[this._url]),!this.options.keepAspectRatio&&Object.prototype.hasOwnProperty.call(e.style,"objectFit")&&(e.style.objectFit="fill"),e.autoplay=!!this.options.autoplay,e.loop=!!this.options.loop,e.muted=!!this.options.muted,e.playsInline=!!this.options.playsInline;for(var s=0;s<this._url.length;s++){var r=P("source");r.src=this._url[s],e.appendChild(r)}}}});var Oi=Ei.extend({_initImage:function(){var t=this._image=this._url;M(t,"leaflet-image-layer"),this._zoomAnimated&&M(t,"leaflet-zoom-animated"),this.options.className&&M(t,this.options.className),t.onselectstart=u,t.onmousemove=u}});var Ai=o.extend({options:{interactive:!1,offset:[0,0],className:"",pane:void 0,content:""},initialize:function(t,e){t&&(t instanceof v||d(t))?(this._latlng=w(t),c(this,e)):(c(this,t),this._source=e),this.options.content&&(this._content=this.options.content)},openOn:function(t){return(t=arguments.length?t:this._source._map).hasLayer(this)||t.addLayer(this),this},close:function(){return this._map&&this._map.removeLayer(this),this},toggle:function(t){return this._map?this.close():(arguments.length?this._source=t:t=this._source,this._prepareOpen(),this.openOn(t._map)),this},onAdd:function(t){this._zoomAnimated=t._zoomAnimated,this._container||this._initLayout(),t._fadeAnimated&&C(this._container,0),clearTimeout(this._removeTimeout),this.getPane().appendChild(this._container),this.update(),t._fadeAnimated&&C(this._container,1),this.bringToFront(),this.options.interactive&&(M(this._container,"leaflet-interactive"),this.addInteractiveTarget(this._container))},onRemove:function(t){t._fadeAnimated?(C(this._container,0),this._removeTimeout=setTimeout(a(T,void 0,this._container),200)):T(this._container),this.options.interactive&&(z(this._container,"leaflet-interactive"),this.removeInteractiveTarget(this._container))},getLatLng:function(){return this._latlng},setLatLng:function(t){return this._latlng=w(t),this._map&&(this._updatePosition(),this._adjustPan()),this},getContent:function(){return this._content},setContent:function(t){return this._content=t,this.update(),this},getElement:function(){return this._container},update:function(){this._map&&(this._container.style.visibility="hidden",this._updateContent(),this._updateLayout(),this._updatePosition(),this._container.style.visibility="",this._adjustPan())},getEvents:function(){var t={zoom:this._updatePosition,viewreset:this._updatePosition};return this._zoomAnimated&&(t.zoomanim=this._animateZoom),t},isOpen:function(){return!!this._map&&this._map.hasLayer(this)},bringToFront:function(){return this._map&&fe(this._container),this},bringToBack:function(){return this._map&&ge(this._container),this},_prepareOpen:function(t){if(!(i=this._source)._map)return!1;if(i instanceof ci){var e,i=null,n=this._source._layers;for(e in n)if(n[e]._map){i=n[e];break}if(!i)return!1;this._source=i}if(!t)if(i.getCenter)t=i.getCenter();else if(i.getLatLng)t=i.getLatLng();else{if(!i.getBounds)throw new Error("Unable to get source layer LatLng.");t=i.getBounds().getCenter()}return this.setLatLng(t),this._map&&this.update(),!0},_updateContent:function(){if(this._content){var t=this._contentNode,e="function"==typeof this._content?this._content(this._source||this):this._content;if("string"==typeof e)t.innerHTML=e;else{for(;t.hasChildNodes();)t.removeChild(t.firstChild);t.appendChild(e)}this.fire("contentupdate")}},_updatePosition:function(){var t,e,i;this._map&&(e=this._map.latLngToLayerPoint(this._latlng),t=m(this.options.offset),i=this._getAnchor(),this._zoomAnimated?Z(this._container,e.add(i)):t=t.add(e).add(i),e=this._containerBottom=-t.y,i=this._containerLeft=-Math.round(this._containerWidth/2)+t.x,this._container.style.bottom=e+"px",this._container.style.left=i+"px")},_getAnchor:function(){return[0,0]}}),Bi=(A.include({_initOverlay:function(t,e,i,n){var o=e;return o instanceof t||(o=new t(n).setContent(e)),i&&o.setLatLng(i),o}}),o.include({_initOverlay:function(t,e,i,n){var o=i;return o instanceof t?(c(o,n),o._source=this):(o=e&&!n?e:new t(n,this)).setContent(i),o}}),Ai.extend({options:{pane:"popupPane",offset:[0,7],maxWidth:300,minWidth:50,maxHeight:null,autoPan:!0,autoPanPaddingTopLeft:null,autoPanPaddingBottomRight:null,autoPanPadding:[5,5],keepInView:!1,closeButton:!0,autoClose:!0,closeOnEscapeKey:!0,className:""},openOn:function(t){return!(t=arguments.length?t:this._source._map).hasLayer(this)&&t._popup&&t._popup.options.autoClose&&t.removeLayer(t._popup),t._popup=this,Ai.prototype.openOn.call(this,t)},onAdd:function(t){Ai.prototype.onAdd.call(this,t),t.fire("popupopen",{popup:this}),this._source&&(this._source.fire("popupopen",{popup:this},!0),this._source instanceof fi||this._source.on("preclick",Ae))},onRemove:function(t){Ai.prototype.onRemove.call(this,t),t.fire("popupclose",{popup:this}),this._source&&(this._source.fire("popupclose",{popup:this},!0),this._source instanceof fi||this._source.off("preclick",Ae))},getEvents:function(){var t=Ai.prototype.getEvents.call(this);return(void 0!==this.options.closeOnClick?this.options.closeOnClick:this._map.options.closePopupOnClick)&&(t.preclick=this.close),this.options.keepInView&&(t.moveend=this._adjustPan),t},_initLayout:function(){var t="leaflet-popup",e=this._container=P("div",t+" "+(this.options.className||"")+" leaflet-zoom-animated"),i=this._wrapper=P("div",t+"-content-wrapper",e);this._contentNode=P("div",t+"-content",i),Ie(e),Be(this._contentNode),S(e,"contextmenu",Ae),this._tipContainer=P("div",t+"-tip-container",e),this._tip=P("div",t+"-tip",this._tipContainer),this.options.closeButton&&((i=this._closeButton=P("a",t+"-close-button",e)).setAttribute("role","button"),i.setAttribute("aria-label","Close popup"),i.href="#close",i.innerHTML='<span aria-hidden="true">&#215;</span>',S(i,"click",function(t){O(t),this.close()},this))},_updateLayout:function(){var t=this._contentNode,e=t.style,i=(e.width="",e.whiteSpace="nowrap",t.offsetWidth),i=Math.min(i,this.options.maxWidth),i=(i=Math.max(i,this.options.minWidth),e.width=i+1+"px",e.whiteSpace="",e.height="",t.offsetHeight),n=this.options.maxHeight,o="leaflet-popup-scrolled";(n&&n<i?(e.height=n+"px",M):z)(t,o),this._containerWidth=this._container.offsetWidth},_animateZoom:function(t){var t=this._map._latLngToNewLayerPoint(this._latlng,t.zoom,t.center),e=this._getAnchor();Z(this._container,t.add(e))},_adjustPan:function(){var t,e,i,n,o,s,r,a;this.options.autoPan&&(this._map._panAnim&&this._map._panAnim.stop(),this._autopanning?this._autopanning=!1:(t=this._map,e=parseInt(pe(this._container,"marginBottom"),10)||0,e=this._container.offsetHeight+e,a=this._containerWidth,(i=new p(this._containerLeft,-e-this._containerBottom))._add(Pe(this._container)),i=t.layerPointToContainerPoint(i),o=m(this.options.autoPanPadding),n=m(this.options.autoPanPaddingTopLeft||o),o=m(this.options.autoPanPaddingBottomRight||o),s=t.getSize(),r=0,i.x+a+o.x>s.x&&(r=i.x+a-s.x+o.x),i.x-r-n.x<(a=0)&&(r=i.x-n.x),i.y+e+o.y>s.y&&(a=i.y+e-s.y+o.y),i.y-a-n.y<0&&(a=i.y-n.y),(r||a)&&(this.options.keepInView&&(this._autopanning=!0),t.fire("autopanstart").panBy([r,a]))))},_getAnchor:function(){return m(this._source&&this._source._getPopupAnchor?this._source._getPopupAnchor():[0,0])}})),Ii=(A.mergeOptions({closePopupOnClick:!0}),A.include({openPopup:function(t,e,i){return this._initOverlay(Bi,t,e,i).openOn(this),this},closePopup:function(t){return(t=arguments.length?t:this._popup)&&t.close(),this}}),o.include({bindPopup:function(t,e){return this._popup=this._initOverlay(Bi,this._popup,t,e),this._popupHandlersAdded||(this.on({click:this._openPopup,keypress:this._onKeyPress,remove:this.closePopup,move:this._movePopup}),this._popupHandlersAdded=!0),this},unbindPopup:function(){return this._popup&&(this.off({click:this._openPopup,keypress:this._onKeyPress,remove:this.closePopup,move:this._movePopup}),this._popupHandlersAdded=!1,this._popup=null),this},openPopup:function(t){return this._popup&&(this instanceof ci||(this._popup._source=this),this._popup._prepareOpen(t||this._latlng)&&this._popup.openOn(this._map)),this},closePopup:function(){return this._popup&&this._popup.close(),this},togglePopup:function(){return this._popup&&this._popup.toggle(this),this},isPopupOpen:function(){return!!this._popup&&this._popup.isOpen()},setPopupContent:function(t){return this._popup&&this._popup.setContent(t),this},getPopup:function(){return this._popup},_openPopup:function(t){var e;this._popup&&this._map&&(Re(t),e=t.layer||t.target,this._popup._source!==e||e instanceof fi?(this._popup._source=e,this.openPopup(t.latlng)):this._map.hasLayer(this._popup)?this.closePopup():this.openPopup(t.latlng))},_movePopup:function(t){this._popup.setLatLng(t.latlng)},_onKeyPress:function(t){13===t.originalEvent.keyCode&&this._openPopup(t)}}),Ai.extend({options:{pane:"tooltipPane",offset:[0,0],direction:"auto",permanent:!1,sticky:!1,opacity:.9},onAdd:function(t){Ai.prototype.onAdd.call(this,t),this.setOpacity(this.options.opacity),t.fire("tooltipopen",{tooltip:this}),this._source&&(this.addEventParent(this._source),this._source.fire("tooltipopen",{tooltip:this},!0))},onRemove:function(t){Ai.prototype.onRemove.call(this,t),t.fire("tooltipclose",{tooltip:this}),this._source&&(this.removeEventParent(this._source),this._source.fire("tooltipclose",{tooltip:this},!0))},getEvents:function(){var t=Ai.prototype.getEvents.call(this);return this.options.permanent||(t.preclick=this.close),t},_initLayout:function(){var t="leaflet-tooltip "+(this.options.className||"")+" leaflet-zoom-"+(this._zoomAnimated?"animated":"hide");this._contentNode=this._container=P("div",t),this._container.setAttribute("role","tooltip"),this._container.setAttribute("id","leaflet-tooltip-"+h(this))},_updateLayout:function(){},_adjustPan:function(){},_setPosition:function(t){var e,i=this._map,n=this._container,o=i.latLngToContainerPoint(i.getCenter()),i=i.layerPointToContainerPoint(t),s=this.options.direction,r=n.offsetWidth,a=n.offsetHeight,h=m(this.options.offset),l=this._getAnchor(),i="top"===s?(e=r/2,a):"bottom"===s?(e=r/2,0):(e="center"===s?r/2:"right"===s?0:"left"===s?r:i.x<o.x?(s="right",0):(s="left",r+2*(h.x+l.x)),a/2);t=t.subtract(m(e,i,!0)).add(h).add(l),z(n,"leaflet-tooltip-right"),z(n,"leaflet-tooltip-left"),z(n,"leaflet-tooltip-top"),z(n,"leaflet-tooltip-bottom"),M(n,"leaflet-tooltip-"+s),Z(n,t)},_updatePosition:function(){var t=this._map.latLngToLayerPoint(this._latlng);this._setPosition(t)},setOpacity:function(t){this.options.opacity=t,this._container&&C(this._container,t)},_animateZoom:function(t){t=this._map._latLngToNewLayerPoint(this._latlng,t.zoom,t.center);this._setPosition(t)},_getAnchor:function(){return m(this._source&&this._source._getTooltipAnchor&&!this.options.sticky?this._source._getTooltipAnchor():[0,0])}})),Ri=(A.include({openTooltip:function(t,e,i){return this._initOverlay(Ii,t,e,i).openOn(this),this},closeTooltip:function(t){return t.close(),this}}),o.include({bindTooltip:function(t,e){return this._tooltip&&this.isTooltipOpen()&&this.unbindTooltip(),this._tooltip=this._initOverlay(Ii,this._tooltip,t,e),this._initTooltipInteractions(),this._tooltip.options.permanent&&this._map&&this._map.hasLayer(this)&&this.openTooltip(),this},unbindTooltip:function(){return this._tooltip&&(this._initTooltipInteractions(!0),this.closeTooltip(),this._tooltip=null),this},_initTooltipInteractions:function(t){var e,i;!t&&this._tooltipHandlersAdded||(e=t?"off":"on",i={remove:this.closeTooltip,move:this._moveTooltip},this._tooltip.options.permanent?i.add=this._openTooltip:(i.mouseover=this._openTooltip,i.mouseout=this.closeTooltip,i.click=this._openTooltip,this._map?this._addFocusListeners():i.add=this._addFocusListeners),this._tooltip.options.sticky&&(i.mousemove=this._moveTooltip),this[e](i),this._tooltipHandlersAdded=!t)},openTooltip:function(t){return this._tooltip&&(this instanceof ci||(this._tooltip._source=this),this._tooltip._prepareOpen(t)&&(this._tooltip.openOn(this._map),this.getElement?this._setAriaDescribedByOnLayer(this):this.eachLayer&&this.eachLayer(this._setAriaDescribedByOnLayer,this))),this},closeTooltip:function(){if(this._tooltip)return this._tooltip.close()},toggleTooltip:function(){return this._tooltip&&this._tooltip.toggle(this),this},isTooltipOpen:function(){return this._tooltip.isOpen()},setTooltipContent:function(t){return this._tooltip&&this._tooltip.setContent(t),this},getTooltip:function(){return this._tooltip},_addFocusListeners:function(){this.getElement?this._addFocusListenersOnLayer(this):this.eachLayer&&this.eachLayer(this._addFocusListenersOnLayer,this)},_addFocusListenersOnLayer:function(t){var e="function"==typeof t.getElement&&t.getElement();e&&(S(e,"focus",function(){this._tooltip._source=t,this.openTooltip()},this),S(e,"blur",this.closeTooltip,this))},_setAriaDescribedByOnLayer:function(t){t="function"==typeof t.getElement&&t.getElement();t&&t.setAttribute("aria-describedby",this._tooltip._container.id)},_openTooltip:function(t){var e;this._tooltip&&this._map&&(this._map.dragging&&this._map.dragging.moving()&&!this._openOnceFlag?(this._openOnceFlag=!0,(e=this)._map.once("moveend",function(){e._openOnceFlag=!1,e._openTooltip(t)})):(this._tooltip._source=t.layer||t.target,this.openTooltip(this._tooltip.options.sticky?t.latlng:void 0)))},_moveTooltip:function(t){var e=t.latlng;this._tooltip.options.sticky&&t.originalEvent&&(t=this._map.mouseEventToContainerPoint(t.originalEvent),t=this._map.containerPointToLayerPoint(t),e=this._map.layerPointToLatLng(t)),this._tooltip.setLatLng(e)}}),di.extend({options:{iconSize:[12,12],html:!1,bgPos:null,className:"leaflet-div-icon"},createIcon:function(t){var t=t&&"DIV"===t.tagName?t:document.createElement("div"),e=this.options;return e.html instanceof Element?(me(t),t.appendChild(e.html)):t.innerHTML=!1!==e.html?e.html:"",e.bgPos&&(e=m(e.bgPos),t.style.backgroundPosition=-e.x+"px "+-e.y+"px"),this._setIconStyles(t,"icon"),t},createShadow:function(){return null}}));di.Default=_i;var Ni=o.extend({options:{tileSize:256,opacity:1,updateWhenIdle:b.mobile,updateWhenZooming:!0,updateInterval:200,zIndex:1,bounds:null,minZoom:0,maxZoom:void 0,maxNativeZoom:void 0,minNativeZoom:void 0,noWrap:!1,pane:"tilePane",className:"",keepBuffer:2},initialize:function(t){c(this,t)},onAdd:function(){this._initContainer(),this._levels={},this._tiles={},this._resetView()},beforeAdd:function(t){t._addZoomLimit(this)},onRemove:function(t){this._removeAllTiles(),T(this._container),t._removeZoomLimit(this),this._container=null,this._tileZoom=void 0},bringToFront:function(){return this._map&&(fe(this._container),this._setAutoZIndex(Math.max)),this},bringToBack:function(){return this._map&&(ge(this._container),this._setAutoZIndex(Math.min)),this},getContainer:function(){return this._container},setOpacity:function(t){return this.options.opacity=t,this._updateOpacity(),this},setZIndex:function(t){return this.options.zIndex=t,this._updateZIndex(),this},isLoading:function(){return this._loading},redraw:function(){var t;return this._map&&(this._removeAllTiles(),(t=this._clampZoom(this._map.getZoom()))!==this._tileZoom&&(this._tileZoom=t,this._updateLevels()),this._update()),this},getEvents:function(){var t={viewprereset:this._invalidateAll,viewreset:this._resetView,zoom:this._resetView,moveend:this._onMoveEnd};return this.options.updateWhenIdle||(this._onMove||(this._onMove=j(this._onMoveEnd,this.options.updateInterval,this)),t.move=this._onMove),this._zoomAnimated&&(t.zoomanim=this._animateZoom),t},createTile:function(){return document.createElement("div")},getTileSize:function(){var t=this.options.tileSize;return t instanceof p?t:new p(t,t)},_updateZIndex:function(){this._container&&void 0!==this.options.zIndex&&null!==this.options.zIndex&&(this._container.style.zIndex=this.options.zIndex)},_setAutoZIndex:function(t){for(var e,i=this.getPane().children,n=-t(-1/0,1/0),o=0,s=i.length;o<s;o++)e=i[o].style.zIndex,i[o]!==this._container&&e&&(n=t(n,+e));isFinite(n)&&(this.options.zIndex=n+t(-1,1),this._updateZIndex())},_updateOpacity:function(){if(this._map&&!b.ielt9){C(this._container,this.options.opacity);var t,e=+new Date,i=!1,n=!1;for(t in this._tiles){var o,s=this._tiles[t];s.current&&s.loaded&&(o=Math.min(1,(e-s.loaded)/200),C(s.el,o),o<1?i=!0:(s.active?n=!0:this._onOpaqueTile(s),s.active=!0))}n&&!this._noPrune&&this._pruneTiles(),i&&(r(this._fadeFrame),this._fadeFrame=x(this._updateOpacity,this))}},_onOpaqueTile:u,_initContainer:function(){this._container||(this._container=P("div","leaflet-layer "+(this.options.className||"")),this._updateZIndex(),this.options.opacity<1&&this._updateOpacity(),this.getPane().appendChild(this._container))},_updateLevels:function(){var t=this._tileZoom,e=this.options.maxZoom;if(void 0!==t){for(var i in this._levels)i=Number(i),this._levels[i].el.children.length||i===t?(this._levels[i].el.style.zIndex=e-Math.abs(t-i),this._onUpdateLevel(i)):(T(this._levels[i].el),this._removeTilesAtZoom(i),this._onRemoveLevel(i),delete this._levels[i]);var n=this._levels[t],o=this._map;return n||((n=this._levels[t]={}).el=P("div","leaflet-tile-container leaflet-zoom-animated",this._container),n.el.style.zIndex=e,n.origin=o.project(o.unproject(o.getPixelOrigin()),t).round(),n.zoom=t,this._setZoomTransform(n,o.getCenter(),o.getZoom()),u(n.el.offsetWidth),this._onCreateLevel(n)),this._level=n}},_onUpdateLevel:u,_onRemoveLevel:u,_onCreateLevel:u,_pruneTiles:function(){if(this._map){var t,e,i,n=this._map.getZoom();if(n>this.options.maxZoom||n<this.options.minZoom)this._removeAllTiles();else{for(t in this._tiles)(i=this._tiles[t]).retain=i.current;for(t in this._tiles)(i=this._tiles[t]).current&&!i.active&&(e=i.coords,this._retainParent(e.x,e.y,e.z,e.z-5)||this._retainChildren(e.x,e.y,e.z,e.z+2));for(t in this._tiles)this._tiles[t].retain||this._removeTile(t)}}},_removeTilesAtZoom:function(t){for(var e in this._tiles)this._tiles[e].coords.z===t&&this._removeTile(e)},_removeAllTiles:function(){for(var t in this._tiles)this._removeTile(t)},_invalidateAll:function(){for(var t in this._levels)T(this._levels[t].el),this._onRemoveLevel(Number(t)),delete this._levels[t];this._removeAllTiles(),this._tileZoom=void 0},_retainParent:function(t,e,i,n){var t=Math.floor(t/2),e=Math.floor(e/2),i=i-1,o=new p(+t,+e),o=(o.z=i,this._tileCoordsToKey(o)),o=this._tiles[o];return o&&o.active?o.retain=!0:(o&&o.loaded&&(o.retain=!0),n<i&&this._retainParent(t,e,i,n))},_retainChildren:function(t,e,i,n){for(var o=2*t;o<2*t+2;o++)for(var s=2*e;s<2*e+2;s++){var r=new p(o,s),r=(r.z=i+1,this._tileCoordsToKey(r)),r=this._tiles[r];r&&r.active?r.retain=!0:(r&&r.loaded&&(r.retain=!0),i+1<n&&this._retainChildren(o,s,i+1,n))}},_resetView:function(t){t=t&&(t.pinch||t.flyTo);this._setView(this._map.getCenter(),this._map.getZoom(),t,t)},_animateZoom:function(t){this._setView(t.center,t.zoom,!0,t.noUpdate)},_clampZoom:function(t){var e=this.options;return void 0!==e.minNativeZoom&&t<e.minNativeZoom?e.minNativeZoom:void 0!==e.maxNativeZoom&&e.maxNativeZoom<t?e.maxNativeZoom:t},_setView:function(t,e,i,n){var o=Math.round(e),o=void 0!==this.options.maxZoom&&o>this.options.maxZoom||void 0!==this.options.minZoom&&o<this.options.minZoom?void 0:this._clampZoom(o),s=this.options.updateWhenZooming&&o!==this._tileZoom;n&&!s||(this._tileZoom=o,this._abortLoading&&this._abortLoading(),this._updateLevels(),this._resetGrid(),void 0!==o&&this._update(t),i||this._pruneTiles(),this._noPrune=!!i),this._setZoomTransforms(t,e)},_setZoomTransforms:function(t,e){for(var i in this._levels)this._setZoomTransform(this._levels[i],t,e)},_setZoomTransform:function(t,e,i){var n=this._map.getZoomScale(i,t.zoom),e=t.origin.multiplyBy(n).subtract(this._map._getNewPixelOrigin(e,i)).round();b.any3d?be(t.el,e,n):Z(t.el,e)},_resetGrid:function(){var t=this._map,e=t.options.crs,i=this._tileSize=this.getTileSize(),n=this._tileZoom,o=this._map.getPixelWorldBounds(this._tileZoom);o&&(this._globalTileRange=this._pxBoundsToTileRange(o)),this._wrapX=e.wrapLng&&!this.options.noWrap&&[Math.floor(t.project([0,e.wrapLng[0]],n).x/i.x),Math.ceil(t.project([0,e.wrapLng[1]],n).x/i.y)],this._wrapY=e.wrapLat&&!this.options.noWrap&&[Math.floor(t.project([e.wrapLat[0],0],n).y/i.x),Math.ceil(t.project([e.wrapLat[1],0],n).y/i.y)]},_onMoveEnd:function(){this._map&&!this._map._animatingZoom&&this._update()},_getTiledPixelBounds:function(t){var e=this._map,i=e._animatingZoom?Math.max(e._animateToZoom,e.getZoom()):e.getZoom(),i=e.getZoomScale(i,this._tileZoom),t=e.project(t,this._tileZoom).floor(),e=e.getSize().divideBy(2*i);return new f(t.subtract(e),t.add(e))},_update:function(t){var e=this._map;if(e){var i=this._clampZoom(e.getZoom());if(void 0===t&&(t=e.getCenter()),void 0!==this._tileZoom){var n,e=this._getTiledPixelBounds(t),o=this._pxBoundsToTileRange(e),s=o.getCenter(),r=[],e=this.options.keepBuffer,a=new f(o.getBottomLeft().subtract([e,-e]),o.getTopRight().add([e,-e]));if(!(isFinite(o.min.x)&&isFinite(o.min.y)&&isFinite(o.max.x)&&isFinite(o.max.y)))throw new Error("Attempted to load an infinite number of tiles");for(n in this._tiles){var h=this._tiles[n].coords;h.z===this._tileZoom&&a.contains(new p(h.x,h.y))||(this._tiles[n].current=!1)}if(1<Math.abs(i-this._tileZoom))this._setView(t,i);else{for(var l=o.min.y;l<=o.max.y;l++)for(var u=o.min.x;u<=o.max.x;u++){var c,d=new p(u,l);d.z=this._tileZoom,this._isValidTile(d)&&((c=this._tiles[this._tileCoordsToKey(d)])?c.current=!0:r.push(d))}if(r.sort(function(t,e){return t.distanceTo(s)-e.distanceTo(s)}),0!==r.length){this._loading||(this._loading=!0,this.fire("loading"));for(var _=document.createDocumentFragment(),u=0;u<r.length;u++)this._addTile(r[u],_);this._level.el.appendChild(_)}}}}},_isValidTile:function(t){var e=this._map.options.crs;if(!e.infinite){var i=this._globalTileRange;if(!e.wrapLng&&(t.x<i.min.x||t.x>i.max.x)||!e.wrapLat&&(t.y<i.min.y||t.y>i.max.y))return!1}return!this.options.bounds||(e=this._tileCoordsToBounds(t),g(this.options.bounds).overlaps(e))},_keyToBounds:function(t){return this._tileCoordsToBounds(this._keyToTileCoords(t))},_tileCoordsToNwSe:function(t){var e=this._map,i=this.getTileSize(),n=t.scaleBy(i),i=n.add(i);return[e.unproject(n,t.z),e.unproject(i,t.z)]},_tileCoordsToBounds:function(t){t=this._tileCoordsToNwSe(t),t=new s(t[0],t[1]);return t=this.options.noWrap?t:this._map.wrapLatLngBounds(t)},_tileCoordsToKey:function(t){return t.x+":"+t.y+":"+t.z},_keyToTileCoords:function(t){var t=t.split(":"),e=new p(+t[0],+t[1]);return e.z=+t[2],e},_removeTile:function(t){var e=this._tiles[t];e&&(T(e.el),delete this._tiles[t],this.fire("tileunload",{tile:e.el,coords:this._keyToTileCoords(t)}))},_initTile:function(t){M(t,"leaflet-tile");var e=this.getTileSize();t.style.width=e.x+"px",t.style.height=e.y+"px",t.onselectstart=u,t.onmousemove=u,b.ielt9&&this.options.opacity<1&&C(t,this.options.opacity)},_addTile:function(t,e){var i=this._getTilePos(t),n=this._tileCoordsToKey(t),o=this.createTile(this._wrapCoords(t),a(this._tileReady,this,t));this._initTile(o),this.createTile.length<2&&x(a(this._tileReady,this,t,null,o)),Z(o,i),this._tiles[n]={el:o,coords:t,current:!0},e.appendChild(o),this.fire("tileloadstart",{tile:o,coords:t})},_tileReady:function(t,e,i){e&&this.fire("tileerror",{error:e,tile:i,coords:t});var n=this._tileCoordsToKey(t);(i=this._tiles[n])&&(i.loaded=+new Date,this._map._fadeAnimated?(C(i.el,0),r(this._fadeFrame),this._fadeFrame=x(this._updateOpacity,this)):(i.active=!0,this._pruneTiles()),e||(M(i.el,"leaflet-tile-loaded"),this.fire("tileload",{tile:i.el,coords:t})),this._noTilesToLoad()&&(this._loading=!1,this.fire("load"),b.ielt9||!this._map._fadeAnimated?x(this._pruneTiles,this):setTimeout(a(this._pruneTiles,this),250)))},_getTilePos:function(t){return t.scaleBy(this.getTileSize()).subtract(this._level.origin)},_wrapCoords:function(t){var e=new p(this._wrapX?H(t.x,this._wrapX):t.x,this._wrapY?H(t.y,this._wrapY):t.y);return e.z=t.z,e},_pxBoundsToTileRange:function(t){var e=this.getTileSize();return new f(t.min.unscaleBy(e).floor(),t.max.unscaleBy(e).ceil().subtract([1,1]))},_noTilesToLoad:function(){for(var t in this._tiles)if(!this._tiles[t].loaded)return!1;return!0}});var Di=Ni.extend({options:{minZoom:0,maxZoom:18,subdomains:"abc",errorTileUrl:"",zoomOffset:0,tms:!1,zoomReverse:!1,detectRetina:!1,crossOrigin:!1,referrerPolicy:!1},initialize:function(t,e){this._url=t,(e=c(this,e)).detectRetina&&b.retina&&0<e.maxZoom?(e.tileSize=Math.floor(e.tileSize/2),e.zoomReverse?(e.zoomOffset--,e.minZoom=Math.min(e.maxZoom,e.minZoom+1)):(e.zoomOffset++,e.maxZoom=Math.max(e.minZoom,e.maxZoom-1)),e.minZoom=Math.max(0,e.minZoom)):e.zoomReverse?e.minZoom=Math.min(e.maxZoom,e.minZoom):e.maxZoom=Math.max(e.minZoom,e.maxZoom),"string"==typeof e.subdomains&&(e.subdomains=e.subdomains.split("")),this.on("tileunload",this._onTileRemove)},setUrl:function(t,e){return this._url===t&&void 0===e&&(e=!0),this._url=t,e||this.redraw(),this},createTile:function(t,e){var i=document.createElement("img");return S(i,"load",a(this._tileOnLoad,this,e,i)),S(i,"error",a(this._tileOnError,this,e,i)),!this.options.crossOrigin&&""!==this.options.crossOrigin||(i.crossOrigin=!0===this.options.crossOrigin?"":this.options.crossOrigin),"string"==typeof this.options.referrerPolicy&&(i.referrerPolicy=this.options.referrerPolicy),i.alt="",i.src=this.getTileUrl(t),i},getTileUrl:function(t){var e={r:b.retina?"@2x":"",s:this._getSubdomain(t),x:t.x,y:t.y,z:this._getZoomForUrl()};return this._map&&!this._map.options.crs.infinite&&(t=this._globalTileRange.max.y-t.y,this.options.tms&&(e.y=t),e["-y"]=t),q(this._url,l(e,this.options))},_tileOnLoad:function(t,e){b.ielt9?setTimeout(a(t,this,null,e),0):t(null,e)},_tileOnError:function(t,e,i){var n=this.options.errorTileUrl;n&&e.getAttribute("src")!==n&&(e.src=n),t(i,e)},_onTileRemove:function(t){t.tile.onload=null},_getZoomForUrl:function(){var t=this._tileZoom,e=this.options.maxZoom;return(t=this.options.zoomReverse?e-t:t)+this.options.zoomOffset},_getSubdomain:function(t){t=Math.abs(t.x+t.y)%this.options.subdomains.length;return this.options.subdomains[t]},_abortLoading:function(){var t,e,i;for(t in this._tiles)this._tiles[t].coords.z!==this._tileZoom&&((i=this._tiles[t].el).onload=u,i.onerror=u,i.complete||(i.src=K,e=this._tiles[t].coords,T(i),delete this._tiles[t],this.fire("tileabort",{tile:i,coords:e})))},_removeTile:function(t){var e=this._tiles[t];if(e)return e.el.setAttribute("src",K),Ni.prototype._removeTile.call(this,t)},_tileReady:function(t,e,i){if(this._map&&(!i||i.getAttribute("src")!==K))return Ni.prototype._tileReady.call(this,t,e,i)}});function ji(t,e){return new Di(t,e)}var Hi=Di.extend({defaultWmsParams:{service:"WMS",request:"GetMap",layers:"",styles:"",format:"image/jpeg",transparent:!1,version:"1.1.1"},options:{crs:null,uppercase:!1},initialize:function(t,e){this._url=t;var i,n=l({},this.defaultWmsParams);for(i in e)i in this.options||(n[i]=e[i]);var t=(e=c(this,e)).detectRetina&&b.retina?2:1,o=this.getTileSize();n.width=o.x*t,n.height=o.y*t,this.wmsParams=n},onAdd:function(t){this._crs=this.options.crs||t.options.crs,this._wmsVersion=parseFloat(this.wmsParams.version);var e=1.3<=this._wmsVersion?"crs":"srs";this.wmsParams[e]=this._crs.code,Di.prototype.onAdd.call(this,t)},getTileUrl:function(t){var e=this._tileCoordsToNwSe(t),i=this._crs,i=_(i.project(e[0]),i.project(e[1])),e=i.min,i=i.max,e=(1.3<=this._wmsVersion&&this._crs===li?[e.y,e.x,i.y,i.x]:[e.x,e.y,i.x,i.y]).join(","),i=Di.prototype.getTileUrl.call(this,t);return i+U(this.wmsParams,i,this.options.uppercase)+(this.options.uppercase?"&BBOX=":"&bbox=")+e},setParams:function(t,e){return l(this.wmsParams,t),e||this.redraw(),this}});Di.WMS=Hi,ji.wms=function(t,e){return new Hi(t,e)};var Wi=o.extend({options:{padding:.1},initialize:function(t){c(this,t),h(this),this._layers=this._layers||{}},onAdd:function(){this._container||(this._initContainer(),M(this._container,"leaflet-zoom-animated")),this.getPane().appendChild(this._container),this._update(),this.on("update",this._updatePaths,this)},onRemove:function(){this.off("update",this._updatePaths,this),this._destroyContainer()},getEvents:function(){var t={viewreset:this._reset,zoom:this._onZoom,moveend:this._update,zoomend:this._onZoomEnd};return this._zoomAnimated&&(t.zoomanim=this._onAnimZoom),t},_onAnimZoom:function(t){this._updateTransform(t.center,t.zoom)},_onZoom:function(){this._updateTransform(this._map.getCenter(),this._map.getZoom())},_updateTransform:function(t,e){var i=this._map.getZoomScale(e,this._zoom),n=this._map.getSize().multiplyBy(.5+this.options.padding),o=this._map.project(this._center,e),n=n.multiplyBy(-i).add(o).subtract(this._map._getNewPixelOrigin(t,e));b.any3d?be(this._container,n,i):Z(this._container,n)},_reset:function(){for(var t in this._update(),this._updateTransform(this._center,this._zoom),this._layers)this._layers[t]._reset()},_onZoomEnd:function(){for(var t in this._layers)this._layers[t]._project()},_updatePaths:function(){for(var t in this._layers)this._layers[t]._update()},_update:function(){var t=this.options.padding,e=this._map.getSize(),i=this._map.containerPointToLayerPoint(e.multiplyBy(-t)).round();this._bounds=new f(i,i.add(e.multiplyBy(1+2*t)).round()),this._center=this._map.getCenter(),this._zoom=this._map.getZoom()}}),Fi=Wi.extend({options:{tolerance:0},getEvents:function(){var t=Wi.prototype.getEvents.call(this);return t.viewprereset=this._onViewPreReset,t},_onViewPreReset:function(){this._postponeUpdatePaths=!0},onAdd:function(){Wi.prototype.onAdd.call(this),this._draw()},_initContainer:function(){var t=this._container=document.createElement("canvas");S(t,"mousemove",this._onMouseMove,this),S(t,"click dblclick mousedown mouseup contextmenu",this._onClick,this),S(t,"mouseout",this._handleMouseOut,this),t._leaflet_disable_events=!0,this._ctx=t.getContext("2d")},_destroyContainer:function(){r(this._redrawRequest),delete this._ctx,T(this._container),k(this._container),delete this._container},_updatePaths:function(){if(!this._postponeUpdatePaths){for(var t in this._redrawBounds=null,this._layers)this._layers[t]._update();this._redraw()}},_update:function(){var t,e,i,n;this._map._animatingZoom&&this._bounds||(Wi.prototype._update.call(this),t=this._bounds,e=this._container,i=t.getSize(),n=b.retina?2:1,Z(e,t.min),e.width=n*i.x,e.height=n*i.y,e.style.width=i.x+"px",e.style.height=i.y+"px",b.retina&&this._ctx.scale(2,2),this._ctx.translate(-t.min.x,-t.min.y),this.fire("update"))},_reset:function(){Wi.prototype._reset.call(this),this._postponeUpdatePaths&&(this._postponeUpdatePaths=!1,this._updatePaths())},_initPath:function(t){this._updateDashArray(t);t=(this._layers[h(t)]=t)._order={layer:t,prev:this._drawLast,next:null};this._drawLast&&(this._drawLast.next=t),this._drawLast=t,this._drawFirst=this._drawFirst||this._drawLast},_addPath:function(t){this._requestRedraw(t)},_removePath:function(t){var e=t._order,i=e.next,e=e.prev;i?i.prev=e:this._drawLast=e,e?e.next=i:this._drawFirst=i,delete t._order,delete this._layers[h(t)],this._requestRedraw(t)},_updatePath:function(t){this._extendRedrawBounds(t),t._project(),t._update(),this._requestRedraw(t)},_updateStyle:function(t){this._updateDashArray(t),this._requestRedraw(t)},_updateDashArray:function(t){if("string"==typeof t.options.dashArray){for(var e,i=t.options.dashArray.split(/[, ]+/),n=[],o=0;o<i.length;o++){if(e=Number(i[o]),isNaN(e))return;n.push(e)}t.options._dashArray=n}else t.options._dashArray=t.options.dashArray},_requestRedraw:function(t){this._map&&(this._extendRedrawBounds(t),this._redrawRequest=this._redrawRequest||x(this._redraw,this))},_extendRedrawBounds:function(t){var e;t._pxBounds&&(e=(t.options.weight||0)+1,this._redrawBounds=this._redrawBounds||new f,this._redrawBounds.extend(t._pxBounds.min.subtract([e,e])),this._redrawBounds.extend(t._pxBounds.max.add([e,e])))},_redraw:function(){this._redrawRequest=null,this._redrawBounds&&(this._redrawBounds.min._floor(),this._redrawBounds.max._ceil()),this._clear(),this._draw(),this._redrawBounds=null},_clear:function(){var t,e=this._redrawBounds;e?(t=e.getSize(),this._ctx.clearRect(e.min.x,e.min.y,t.x,t.y)):(this._ctx.save(),this._ctx.setTransform(1,0,0,1,0,0),this._ctx.clearRect(0,0,this._container.width,this._container.height),this._ctx.restore())},_draw:function(){var t,e,i=this._redrawBounds;this._ctx.save(),i&&(e=i.getSize(),this._ctx.beginPath(),this._ctx.rect(i.min.x,i.min.y,e.x,e.y),this._ctx.clip()),this._drawing=!0;for(var n=this._drawFirst;n;n=n.next)t=n.layer,(!i||t._pxBounds&&t._pxBounds.intersects(i))&&t._updatePath();this._drawing=!1,this._ctx.restore()},_updatePoly:function(t,e){if(this._drawing){var i,n,o,s,r=t._parts,a=r.length,h=this._ctx;if(a){for(h.beginPath(),i=0;i<a;i++){for(n=0,o=r[i].length;n<o;n++)s=r[i][n],h[n?"lineTo":"moveTo"](s.x,s.y);e&&h.closePath()}this._fillStroke(h,t)}}},_updateCircle:function(t){var e,i,n,o;this._drawing&&!t._empty()&&(e=t._point,i=this._ctx,n=Math.max(Math.round(t._radius),1),1!=(o=(Math.max(Math.round(t._radiusY),1)||n)/n)&&(i.save(),i.scale(1,o)),i.beginPath(),i.arc(e.x,e.y/o,n,0,2*Math.PI,!1),1!=o&&i.restore(),this._fillStroke(i,t))},_fillStroke:function(t,e){var i=e.options;i.fill&&(t.globalAlpha=i.fillOpacity,t.fillStyle=i.fillColor||i.color,t.fill(i.fillRule||"evenodd")),i.stroke&&0!==i.weight&&(t.setLineDash&&t.setLineDash(e.options&&e.options._dashArray||[]),t.globalAlpha=i.opacity,t.lineWidth=i.weight,t.strokeStyle=i.color,t.lineCap=i.lineCap,t.lineJoin=i.lineJoin,t.stroke())},_onClick:function(t){for(var e,i,n=this._map.mouseEventToLayerPoint(t),o=this._drawFirst;o;o=o.next)(e=o.layer).options.interactive&&e._containsPoint(n)&&(("click"===t.type||"preclick"===t.type)&&this._map._draggableMoved(e)||(i=e));this._fireEvent(!!i&&[i],t)},_onMouseMove:function(t){var e;!this._map||this._map.dragging.moving()||this._map._animatingZoom||(e=this._map.mouseEventToLayerPoint(t),this._handleMouseHover(t,e))},_handleMouseOut:function(t){var e=this._hoveredLayer;e&&(z(this._container,"leaflet-interactive"),this._fireEvent([e],t,"mouseout"),this._hoveredLayer=null,this._mouseHoverThrottled=!1)},_handleMouseHover:function(t,e){if(!this._mouseHoverThrottled){for(var i,n,o=this._drawFirst;o;o=o.next)(i=o.layer).options.interactive&&i._containsPoint(e)&&(n=i);n!==this._hoveredLayer&&(this._handleMouseOut(t),n&&(M(this._container,"leaflet-interactive"),this._fireEvent([n],t,"mouseover"),this._hoveredLayer=n)),this._fireEvent(!!this._hoveredLayer&&[this._hoveredLayer],t),this._mouseHoverThrottled=!0,setTimeout(a(function(){this._mouseHoverThrottled=!1},this),32)}},_fireEvent:function(t,e,i){this._map._fireDOMEvent(e,i||e.type,t)},_bringToFront:function(t){var e,i,n=t._order;n&&(e=n.next,i=n.prev,e&&((e.prev=i)?i.next=e:e&&(this._drawFirst=e),n.prev=this._drawLast,(this._drawLast.next=n).next=null,this._drawLast=n,this._requestRedraw(t)))},_bringToBack:function(t){var e,i,n=t._order;n&&(e=n.next,(i=n.prev)&&((i.next=e)?e.prev=i:i&&(this._drawLast=i),n.prev=null,n.next=this._drawFirst,this._drawFirst.prev=n,this._drawFirst=n,this._requestRedraw(t)))}});function Ui(t){return b.canvas?new Fi(t):null}var Vi=function(){try{return document.namespaces.add("lvml","urn:schemas-microsoft-com:vml"),function(t){return document.createElement("<lvml:"+t+' class="lvml">')}}catch(t){}return function(t){return document.createElement("<"+t+' xmlns="urn:schemas-microsoft.com:vml" class="lvml">')}}(),zt={_initContainer:function(){this._container=P("div","leaflet-vml-container")},_update:function(){this._map._animatingZoom||(Wi.prototype._update.call(this),this.fire("update"))},_initPath:function(t){var e=t._container=Vi("shape");M(e,"leaflet-vml-shape "+(this.options.className||"")),e.coordsize="1 1",t._path=Vi("path"),e.appendChild(t._path),this._updateStyle(t),this._layers[h(t)]=t},_addPath:function(t){var e=t._container;this._container.appendChild(e),t.options.interactive&&t.addInteractiveTarget(e)},_removePath:function(t){var e=t._container;T(e),t.removeInteractiveTarget(e),delete this._layers[h(t)]},_updateStyle:function(t){var e=t._stroke,i=t._fill,n=t.options,o=t._container;o.stroked=!!n.stroke,o.filled=!!n.fill,n.stroke?(e=e||(t._stroke=Vi("stroke")),o.appendChild(e),e.weight=n.weight+"px",e.color=n.color,e.opacity=n.opacity,n.dashArray?e.dashStyle=d(n.dashArray)?n.dashArray.join(" "):n.dashArray.replace(/( *, *)/g," "):e.dashStyle="",e.endcap=n.lineCap.replace("butt","flat"),e.joinstyle=n.lineJoin):e&&(o.removeChild(e),t._stroke=null),n.fill?(i=i||(t._fill=Vi("fill")),o.appendChild(i),i.color=n.fillColor||n.color,i.opacity=n.fillOpacity):i&&(o.removeChild(i),t._fill=null)},_updateCircle:function(t){var e=t._point.round(),i=Math.round(t._radius),n=Math.round(t._radiusY||i);this._setPath(t,t._empty()?"M0 0":"AL "+e.x+","+e.y+" "+i+","+n+" 0,23592600")},_setPath:function(t,e){t._path.v=e},_bringToFront:function(t){fe(t._container)},_bringToBack:function(t){ge(t._container)}},qi=b.vml?Vi:ct,Gi=Wi.extend({_initContainer:function(){this._container=qi("svg"),this._container.setAttribute("pointer-events","none"),this._rootGroup=qi("g"),this._container.appendChild(this._rootGroup)},_destroyContainer:function(){T(this._container),k(this._container),delete this._container,delete this._rootGroup,delete this._svgSize},_update:function(){var t,e,i;this._map._animatingZoom&&this._bounds||(Wi.prototype._update.call(this),e=(t=this._bounds).getSize(),i=this._container,this._svgSize&&this._svgSize.equals(e)||(this._svgSize=e,i.setAttribute("width",e.x),i.setAttribute("height",e.y)),Z(i,t.min),i.setAttribute("viewBox",[t.min.x,t.min.y,e.x,e.y].join(" ")),this.fire("update"))},_initPath:function(t){var e=t._path=qi("path");t.options.className&&M(e,t.options.className),t.options.interactive&&M(e,"leaflet-interactive"),this._updateStyle(t),this._layers[h(t)]=t},_addPath:function(t){this._rootGroup||this._initContainer(),this._rootGroup.appendChild(t._path),t.addInteractiveTarget(t._path)},_removePath:function(t){T(t._path),t.removeInteractiveTarget(t._path),delete this._layers[h(t)]},_updatePath:function(t){t._project(),t._update()},_updateStyle:function(t){var e=t._path,t=t.options;e&&(t.stroke?(e.setAttribute("stroke",t.color),e.setAttribute("stroke-opacity",t.opacity),e.setAttribute("stroke-width",t.weight),e.setAttribute("stroke-linecap",t.lineCap),e.setAttribute("stroke-linejoin",t.lineJoin),t.dashArray?e.setAttribute("stroke-dasharray",t.dashArray):e.removeAttribute("stroke-dasharray"),t.dashOffset?e.setAttribute("stroke-dashoffset",t.dashOffset):e.removeAttribute("stroke-dashoffset")):e.setAttribute("stroke","none"),t.fill?(e.setAttribute("fill",t.fillColor||t.color),e.setAttribute("fill-opacity",t.fillOpacity),e.setAttribute("fill-rule",t.fillRule||"evenodd")):e.setAttribute("fill","none"))},_updatePoly:function(t,e){this._setPath(t,dt(t._parts,e))},_updateCircle:function(t){var e=t._point,i=Math.max(Math.round(t._radius),1),n="a"+i+","+(Math.max(Math.round(t._radiusY),1)||i)+" 0 1,0 ",e=t._empty()?"M0 0":"M"+(e.x-i)+","+e.y+n+2*i+",0 "+n+2*-i+",0 ";this._setPath(t,e)},_setPath:function(t,e){t._path.setAttribute("d",e)},_bringToFront:function(t){fe(t._path)},_bringToBack:function(t){ge(t._path)}});function Ki(t){return b.svg||b.vml?new Gi(t):null}b.vml&&Gi.include(zt),A.include({getRenderer:function(t){t=(t=t.options.renderer||this._getPaneRenderer(t.options.pane)||this.options.renderer||this._renderer)||(this._renderer=this._createRenderer());return this.hasLayer(t)||this.addLayer(t),t},_getPaneRenderer:function(t){var e;return"overlayPane"!==t&&void 0!==t&&(void 0===(e=this._paneRenderers[t])&&(e=this._createRenderer({pane:t}),this._paneRenderers[t]=e),e)},_createRenderer:function(t){return this.options.preferCanvas&&Ui(t)||Ki(t)}});var Yi=xi.extend({initialize:function(t,e){xi.prototype.initialize.call(this,this._boundsToLatLngs(t),e)},setBounds:function(t){return this.setLatLngs(this._boundsToLatLngs(t))},_boundsToLatLngs:function(t){return[(t=g(t)).getSouthWest(),t.getNorthWest(),t.getNorthEast(),t.getSouthEast()]}});Gi.create=qi,Gi.pointsToPath=dt,wi.geometryToLayer=bi,wi.coordsToLatLng=Li,wi.coordsToLatLngs=Ti,wi.latLngToCoords=Mi,wi.latLngsToCoords=zi,wi.getFeature=Ci,wi.asFeature=Zi,A.mergeOptions({boxZoom:!0});var _t=n.extend({initialize:function(t){this._map=t,this._container=t._container,this._pane=t._panes.overlayPane,this._resetStateTimeout=0,t.on("unload",this._destroy,this)},addHooks:function(){S(this._container,"mousedown",this._onMouseDown,this)},removeHooks:function(){k(this._container,"mousedown",this._onMouseDown,this)},moved:function(){return this._moved},_destroy:function(){T(this._pane),delete this._pane},_resetState:function(){this._resetStateTimeout=0,this._moved=!1},_clearDeferredResetState:function(){0!==this._resetStateTimeout&&(clearTimeout(this._resetStateTimeout),this._resetStateTimeout=0)},_onMouseDown:function(t){if(!t.shiftKey||1!==t.which&&1!==t.button)return!1;this._clearDeferredResetState(),this._resetState(),re(),Le(),this._startPoint=this._map.mouseEventToContainerPoint(t),S(document,{contextmenu:Re,mousemove:this._onMouseMove,mouseup:this._onMouseUp,keydown:this._onKeyDown},this)},_onMouseMove:function(t){this._moved||(this._moved=!0,this._box=P("div","leaflet-zoom-box",this._container),M(this._container,"leaflet-crosshair"),this._map.fire("boxzoomstart")),this._point=this._map.mouseEventToContainerPoint(t);var t=new f(this._point,this._startPoint),e=t.getSize();Z(this._box,t.min),this._box.style.width=e.x+"px",this._box.style.height=e.y+"px"},_finish:function(){this._moved&&(T(this._box),z(this._container,"leaflet-crosshair")),ae(),Te(),k(document,{contextmenu:Re,mousemove:this._onMouseMove,mouseup:this._onMouseUp,keydown:this._onKeyDown},this)},_onMouseUp:function(t){1!==t.which&&1!==t.button||(this._finish(),this._moved&&(this._clearDeferredResetState(),this._resetStateTimeout=setTimeout(a(this._resetState,this),0),t=new s(this._map.containerPointToLatLng(this._startPoint),this._map.containerPointToLatLng(this._point)),this._map.fitBounds(t).fire("boxzoomend",{boxZoomBounds:t})))},_onKeyDown:function(t){27===t.keyCode&&(this._finish(),this._clearDeferredResetState(),this._resetState())}}),Ct=(A.addInitHook("addHandler","boxZoom",_t),A.mergeOptions({doubleClickZoom:!0}),n.extend({addHooks:function(){this._map.on("dblclick",this._onDoubleClick,this)},removeHooks:function(){this._map.off("dblclick",this._onDoubleClick,this)},_onDoubleClick:function(t){var e=this._map,i=e.getZoom(),n=e.options.zoomDelta,i=t.originalEvent.shiftKey?i-n:i+n;"center"===e.options.doubleClickZoom?e.setZoom(i):e.setZoomAround(t.containerPoint,i)}})),Zt=(A.addInitHook("addHandler","doubleClickZoom",Ct),A.mergeOptions({dragging:!0,inertia:!0,inertiaDeceleration:3400,inertiaMaxSpeed:1/0,easeLinearity:.2,worldCopyJump:!1,maxBoundsViscosity:0}),n.extend({addHooks:function(){var t;this._draggable||(t=this._map,this._draggable=new Xe(t._mapPane,t._container),this._draggable.on({dragstart:this._onDragStart,drag:this._onDrag,dragend:this._onDragEnd},this),this._draggable.on("predrag",this._onPreDragLimit,this),t.options.worldCopyJump&&(this._draggable.on("predrag",this._onPreDragWrap,this),t.on("zoomend",this._onZoomEnd,this),t.whenReady(this._onZoomEnd,this))),M(this._map._container,"leaflet-grab leaflet-touch-drag"),this._draggable.enable(),this._positions=[],this._times=[]},removeHooks:function(){z(this._map._container,"leaflet-grab"),z(this._map._container,"leaflet-touch-drag"),this._draggable.disable()},moved:function(){return this._draggable&&this._draggable._moved},moving:function(){return this._draggable&&this._draggable._moving},_onDragStart:function(){var t,e=this._map;e._stop(),this._map.options.maxBounds&&this._map.options.maxBoundsViscosity?(t=g(this._map.options.maxBounds),this._offsetLimit=_(this._map.latLngToContainerPoint(t.getNorthWest()).multiplyBy(-1),this._map.latLngToContainerPoint(t.getSouthEast()).multiplyBy(-1).add(this._map.getSize())),this._viscosity=Math.min(1,Math.max(0,this._map.options.maxBoundsViscosity))):this._offsetLimit=null,e.fire("movestart").fire("dragstart"),e.options.inertia&&(this._positions=[],this._times=[])},_onDrag:function(t){var e,i;this._map.options.inertia&&(e=this._lastTime=+new Date,i=this._lastPos=this._draggable._absPos||this._draggable._newPos,this._positions.push(i),this._times.push(e),this._prunePositions(e)),this._map.fire("move",t).fire("drag",t)},_prunePositions:function(t){for(;1<this._positions.length&&50<t-this._times[0];)this._positions.shift(),this._times.shift()},_onZoomEnd:function(){var t=this._map.getSize().divideBy(2),e=this._map.latLngToLayerPoint([0,0]);this._initialWorldOffset=e.subtract(t).x,this._worldWidth=this._map.getPixelWorldBounds().getSize().x},_viscousLimit:function(t,e){return t-(t-e)*this._viscosity},_onPreDragLimit:function(){var t,e;this._viscosity&&this._offsetLimit&&(t=this._draggable._newPos.subtract(this._draggable._startPos),e=this._offsetLimit,t.x<e.min.x&&(t.x=this._viscousLimit(t.x,e.min.x)),t.y<e.min.y&&(t.y=this._viscousLimit(t.y,e.min.y)),t.x>e.max.x&&(t.x=this._viscousLimit(t.x,e.max.x)),t.y>e.max.y&&(t.y=this._viscousLimit(t.y,e.max.y)),this._draggable._newPos=this._draggable._startPos.add(t))},_onPreDragWrap:function(){var t=this._worldWidth,e=Math.round(t/2),i=this._initialWorldOffset,n=this._draggable._newPos.x,o=(n-e+i)%t+e-i,n=(n+e+i)%t-e-i,t=Math.abs(o+i)<Math.abs(n+i)?o:n;this._draggable._absPos=this._draggable._newPos.clone(),this._draggable._newPos.x=t},_onDragEnd:function(t){var e,i,n,o,s=this._map,r=s.options,a=!r.inertia||t.noInertia||this._times.length<2;s.fire("dragend",t),!a&&(this._prunePositions(+new Date),t=this._lastPos.subtract(this._positions[0]),a=(this._lastTime-this._times[0])/1e3,e=r.easeLinearity,a=(t=t.multiplyBy(e/a)).distanceTo([0,0]),i=Math.min(r.inertiaMaxSpeed,a),t=t.multiplyBy(i/a),n=i/(r.inertiaDeceleration*e),(o=t.multiplyBy(-n/2).round()).x||o.y)?(o=s._limitOffset(o,s.options.maxBounds),x(function(){s.panBy(o,{duration:n,easeLinearity:e,noMoveStart:!0,animate:!0})})):s.fire("moveend")}})),St=(A.addInitHook("addHandler","dragging",Zt),A.mergeOptions({keyboard:!0,keyboardPanDelta:80}),n.extend({keyCodes:{left:[37],right:[39],down:[40],up:[38],zoomIn:[187,107,61,171],zoomOut:[189,109,54,173]},initialize:function(t){this._map=t,this._setPanDelta(t.options.keyboardPanDelta),this._setZoomDelta(t.options.zoomDelta)},addHooks:function(){var t=this._map._container;t.tabIndex<=0&&(t.tabIndex="0"),S(t,{focus:this._onFocus,blur:this._onBlur,mousedown:this._onMouseDown},this),this._map.on({focus:this._addHooks,blur:this._removeHooks},this)},removeHooks:function(){this._removeHooks(),k(this._map._container,{focus:this._onFocus,blur:this._onBlur,mousedown:this._onMouseDown},this),this._map.off({focus:this._addHooks,blur:this._removeHooks},this)},_onMouseDown:function(){var t,e,i;this._focused||(i=document.body,t=document.documentElement,e=i.scrollTop||t.scrollTop,i=i.scrollLeft||t.scrollLeft,this._map._container.focus(),window.scrollTo(i,e))},_onFocus:function(){this._focused=!0,this._map.fire("focus")},_onBlur:function(){this._focused=!1,this._map.fire("blur")},_setPanDelta:function(t){for(var e=this._panKeys={},i=this.keyCodes,n=0,o=i.left.length;n<o;n++)e[i.left[n]]=[-1*t,0];for(n=0,o=i.right.length;n<o;n++)e[i.right[n]]=[t,0];for(n=0,o=i.down.length;n<o;n++)e[i.down[n]]=[0,t];for(n=0,o=i.up.length;n<o;n++)e[i.up[n]]=[0,-1*t]},_setZoomDelta:function(t){for(var e=this._zoomKeys={},i=this.keyCodes,n=0,o=i.zoomIn.length;n<o;n++)e[i.zoomIn[n]]=t;for(n=0,o=i.zoomOut.length;n<o;n++)e[i.zoomOut[n]]=-t},_addHooks:function(){S(document,"keydown",this._onKeyDown,this)},_removeHooks:function(){k(document,"keydown",this._onKeyDown,this)},_onKeyDown:function(t){if(!(t.altKey||t.ctrlKey||t.metaKey)){var e,i,n=t.keyCode,o=this._map;if(n in this._panKeys)o._panAnim&&o._panAnim._inProgress||(i=this._panKeys[n],t.shiftKey&&(i=m(i).multiplyBy(3)),o.options.maxBounds&&(i=o._limitOffset(m(i),o.options.maxBounds)),o.options.worldCopyJump?(e=o.wrapLatLng(o.unproject(o.project(o.getCenter()).add(i))),o.panTo(e)):o.panBy(i));else if(n in this._zoomKeys)o.setZoom(o.getZoom()+(t.shiftKey?3:1)*this._zoomKeys[n]);else{if(27!==n||!o._popup||!o._popup.options.closeOnEscapeKey)return;o.closePopup()}Re(t)}}})),Et=(A.addInitHook("addHandler","keyboard",St),A.mergeOptions({scrollWheelZoom:!0,wheelDebounceTime:40,wheelPxPerZoomLevel:60}),n.extend({addHooks:function(){S(this._map._container,"wheel",this._onWheelScroll,this),this._delta=0},removeHooks:function(){k(this._map._container,"wheel",this._onWheelScroll,this)},_onWheelScroll:function(t){var e=He(t),i=this._map.options.wheelDebounceTime,e=(this._delta+=e,this._lastMousePos=this._map.mouseEventToContainerPoint(t),this._startTime||(this._startTime=+new Date),Math.max(i-(+new Date-this._startTime),0));clearTimeout(this._timer),this._timer=setTimeout(a(this._performZoom,this),e),Re(t)},_performZoom:function(){var t=this._map,e=t.getZoom(),i=this._map.options.zoomSnap||0,n=(t._stop(),this._delta/(4*this._map.options.wheelPxPerZoomLevel)),n=4*Math.log(2/(1+Math.exp(-Math.abs(n))))/Math.LN2,i=i?Math.ceil(n/i)*i:n,n=t._limitZoom(e+(0<this._delta?i:-i))-e;this._delta=0,this._startTime=null,n&&("center"===t.options.scrollWheelZoom?t.setZoom(e+n):t.setZoomAround(this._lastMousePos,e+n))}})),kt=(A.addInitHook("addHandler","scrollWheelZoom",Et),A.mergeOptions({tapHold:b.touchNative&&b.safari&&b.mobile,tapTolerance:15}),n.extend({addHooks:function(){S(this._map._container,"touchstart",this._onDown,this)},removeHooks:function(){k(this._map._container,"touchstart",this._onDown,this)},_onDown:function(t){var e;clearTimeout(this._holdTimeout),1===t.touches.length&&(e=t.touches[0],this._startPos=this._newPos=new p(e.clientX,e.clientY),this._holdTimeout=setTimeout(a(function(){this._cancel(),this._isTapValid()&&(S(document,"touchend",O),S(document,"touchend touchcancel",this._cancelClickPrevent),this._simulateEvent("contextmenu",e))},this),600),S(document,"touchend touchcancel contextmenu",this._cancel,this),S(document,"touchmove",this._onMove,this))},_cancelClickPrevent:function t(){k(document,"touchend",O),k(document,"touchend touchcancel",t)},_cancel:function(){clearTimeout(this._holdTimeout),k(document,"touchend touchcancel contextmenu",this._cancel,this),k(document,"touchmove",this._onMove,this)},_onMove:function(t){t=t.touches[0];this._newPos=new p(t.clientX,t.clientY)},_isTapValid:function(){return this._newPos.distanceTo(this._startPos)<=this._map.options.tapTolerance},_simulateEvent:function(t,e){t=new MouseEvent(t,{bubbles:!0,cancelable:!0,view:window,screenX:e.screenX,screenY:e.screenY,clientX:e.clientX,clientY:e.clientY});t._simulated=!0,e.target.dispatchEvent(t)}})),Ot=(A.addInitHook("addHandler","tapHold",kt),A.mergeOptions({touchZoom:b.touch,bounceAtZoomLimits:!0}),n.extend({addHooks:function(){M(this._map._container,"leaflet-touch-zoom"),S(this._map._container,"touchstart",this._onTouchStart,this)},removeHooks:function(){z(this._map._container,"leaflet-touch-zoom"),k(this._map._container,"touchstart",this._onTouchStart,this)},_onTouchStart:function(t){var e,i,n=this._map;!t.touches||2!==t.touches.length||n._animatingZoom||this._zooming||(e=n.mouseEventToContainerPoint(t.touches[0]),i=n.mouseEventToContainerPoint(t.touches[1]),this._centerPoint=n.getSize()._divideBy(2),this._startLatLng=n.containerPointToLatLng(this._centerPoint),"center"!==n.options.touchZoom&&(this._pinchStartLatLng=n.containerPointToLatLng(e.add(i)._divideBy(2))),this._startDist=e.distanceTo(i),this._startZoom=n.getZoom(),this._moved=!1,this._zooming=!0,n._stop(),S(document,"touchmove",this._onTouchMove,this),S(document,"touchend touchcancel",this._onTouchEnd,this),O(t))},_onTouchMove:function(t){if(t.touches&&2===t.touches.length&&this._zooming){var e=this._map,i=e.mouseEventToContainerPoint(t.touches[0]),n=e.mouseEventToContainerPoint(t.touches[1]),o=i.distanceTo(n)/this._startDist;if(this._zoom=e.getScaleZoom(o,this._startZoom),!e.options.bounceAtZoomLimits&&(this._zoom<e.getMinZoom()&&o<1||this._zoom>e.getMaxZoom()&&1<o)&&(this._zoom=e._limitZoom(this._zoom)),"center"===e.options.touchZoom){if(this._center=this._startLatLng,1==o)return}else{i=i._add(n)._divideBy(2)._subtract(this._centerPoint);if(1==o&&0===i.x&&0===i.y)return;this._center=e.unproject(e.project(this._pinchStartLatLng,this._zoom).subtract(i),this._zoom)}this._moved||(e._moveStart(!0,!1),this._moved=!0),r(this._animRequest);n=a(e._move,e,this._center,this._zoom,{pinch:!0,round:!1},void 0);this._animRequest=x(n,this,!0),O(t)}},_onTouchEnd:function(){this._moved&&this._zooming?(this._zooming=!1,r(this._animRequest),k(document,"touchmove",this._onTouchMove,this),k(document,"touchend touchcancel",this._onTouchEnd,this),this._map.options.zoomAnimation?this._map._animateZoom(this._center,this._map._limitZoom(this._zoom),!0,this._map.options.zoomSnap):this._map._resetView(this._center,this._map._limitZoom(this._zoom))):this._zooming=!1}})),Xi=(A.addInitHook("addHandler","touchZoom",Ot),A.BoxZoom=_t,A.DoubleClickZoom=Ct,A.Drag=Zt,A.Keyboard=St,A.ScrollWheelZoom=Et,A.TapHold=kt,A.TouchZoom=Ot,t.Bounds=f,t.Browser=b,t.CRS=ot,t.Canvas=Fi,t.Circle=vi,t.CircleMarker=gi,t.Class=et,t.Control=B,t.DivIcon=Ri,t.DivOverlay=Ai,t.DomEvent=mt,t.DomUtil=pt,t.Draggable=Xe,t.Evented=it,t.FeatureGroup=ci,t.GeoJSON=wi,t.GridLayer=Ni,t.Handler=n,t.Icon=di,t.ImageOverlay=Ei,t.LatLng=v,t.LatLngBounds=s,t.Layer=o,t.LayerGroup=ui,t.LineUtil=vt,t.Map=A,t.Marker=mi,t.Mixin=ft,t.Path=fi,t.Point=p,t.PolyUtil=gt,t.Polygon=xi,t.Polyline=yi,t.Popup=Bi,t.PosAnimation=Fe,t.Projection=wt,t.Rectangle=Yi,t.Renderer=Wi,t.SVG=Gi,t.SVGOverlay=Oi,t.TileLayer=Di,t.Tooltip=Ii,t.Transformation=at,t.Util=tt,t.VideoOverlay=ki,t.bind=a,t.bounds=_,t.canvas=Ui,t.circle=function(t,e,i){return new vi(t,e,i)},t.circleMarker=function(t,e){return new gi(t,e)},t.control=Ue,t.divIcon=function(t){return new Ri(t)},t.extend=l,t.featureGroup=function(t,e){return new ci(t,e)},t.geoJSON=Si,t.geoJson=Mt,t.gridLayer=function(t){return new Ni(t)},t.icon=function(t){return new di(t)},t.imageOverlay=function(t,e,i){return new Ei(t,e,i)},t.latLng=w,t.latLngBounds=g,t.layerGroup=function(t,e){return new ui(t,e)},t.map=function(t,e){return new A(t,e)},t.marker=function(t,e){return new mi(t,e)},t.point=m,t.polygon=function(t,e){return new xi(t,e)},t.polyline=function(t,e){return new yi(t,e)},t.popup=function(t,e){return new Bi(t,e)},t.rectangle=function(t,e){return new Yi(t,e)},t.setOptions=c,t.stamp=h,t.svg=Ki,t.svgOverlay=function(t,e,i){return new Oi(t,e,i)},t.tileLayer=ji,t.tooltip=function(t,e){return new Ii(t,e)},t.transformation=ht,t.version="1.9.4",t.videoOverlay=function(t,e,i){return new ki(t,e,i)},window.L);t.noConflict=function(){return window.L=Xi,this},window.L=t});
//# sourceMappingURL=leaflet.js.map
LEAFLET_JS
cat > "$APP/static/leaflet.css" <<'LEAFLET_CSS'
/* required styles */

.leaflet-pane,
.leaflet-tile,
.leaflet-marker-icon,
.leaflet-marker-shadow,
.leaflet-tile-container,
.leaflet-pane > svg,
.leaflet-pane > canvas,
.leaflet-zoom-box,
.leaflet-image-layer,
.leaflet-layer {
	position: absolute;
	left: 0;
	top: 0;
	}
.leaflet-container {
	overflow: hidden;
	}
.leaflet-tile,
.leaflet-marker-icon,
.leaflet-marker-shadow {
	-webkit-user-select: none;
	   -moz-user-select: none;
	        user-select: none;
	  -webkit-user-drag: none;
	}
/* Prevents IE11 from highlighting tiles in blue */
.leaflet-tile::selection {
	background: transparent;
}
/* Safari renders non-retina tile on retina better with this, but Chrome is worse */
.leaflet-safari .leaflet-tile {
	image-rendering: -webkit-optimize-contrast;
	}
/* hack that prevents hw layers "stretching" when loading new tiles */
.leaflet-safari .leaflet-tile-container {
	width: 1600px;
	height: 1600px;
	-webkit-transform-origin: 0 0;
	}
.leaflet-marker-icon,
.leaflet-marker-shadow {
	display: block;
	}
/* .leaflet-container svg: reset svg max-width decleration shipped in Joomla! (joomla.org) 3.x */
/* .leaflet-container img: map is broken in FF if you have max-width: 100% on tiles */
.leaflet-container .leaflet-overlay-pane svg {
	max-width: none !important;
	max-height: none !important;
	}
.leaflet-container .leaflet-marker-pane img,
.leaflet-container .leaflet-shadow-pane img,
.leaflet-container .leaflet-tile-pane img,
.leaflet-container img.leaflet-image-layer,
.leaflet-container .leaflet-tile {
	max-width: none !important;
	max-height: none !important;
	width: auto;
	padding: 0;
	}

.leaflet-container img.leaflet-tile {
	/* See: https://bugs.chromium.org/p/chromium/issues/detail?id=600120 */
	mix-blend-mode: plus-lighter;
}

.leaflet-container.leaflet-touch-zoom {
	-ms-touch-action: pan-x pan-y;
	touch-action: pan-x pan-y;
	}
.leaflet-container.leaflet-touch-drag {
	-ms-touch-action: pinch-zoom;
	/* Fallback for FF which doesn't support pinch-zoom */
	touch-action: none;
	touch-action: pinch-zoom;
}
.leaflet-container.leaflet-touch-drag.leaflet-touch-zoom {
	-ms-touch-action: none;
	touch-action: none;
}
.leaflet-container {
	-webkit-tap-highlight-color: transparent;
}
.leaflet-container a {
	-webkit-tap-highlight-color: rgba(51, 181, 229, 0.4);
}
.leaflet-tile {
	filter: inherit;
	visibility: hidden;
	}
.leaflet-tile-loaded {
	visibility: inherit;
	}
.leaflet-zoom-box {
	width: 0;
	height: 0;
	-moz-box-sizing: border-box;
	     box-sizing: border-box;
	z-index: 800;
	}
/* workaround for https://bugzilla.mozilla.org/show_bug.cgi?id=888319 */
.leaflet-overlay-pane svg {
	-moz-user-select: none;
	}

.leaflet-pane         { z-index: 400; }

.leaflet-tile-pane    { z-index: 200; }
.leaflet-overlay-pane { z-index: 400; }
.leaflet-shadow-pane  { z-index: 500; }
.leaflet-marker-pane  { z-index: 600; }
.leaflet-tooltip-pane   { z-index: 650; }
.leaflet-popup-pane   { z-index: 700; }

.leaflet-map-pane canvas { z-index: 100; }
.leaflet-map-pane svg    { z-index: 200; }

.leaflet-vml-shape {
	width: 1px;
	height: 1px;
	}
.lvml {
	behavior: url(#default#VML);
	display: inline-block;
	position: absolute;
	}


/* control positioning */

.leaflet-control {
	position: relative;
	z-index: 800;
	pointer-events: visiblePainted; /* IE 9-10 doesn't have auto */
	pointer-events: auto;
	}
.leaflet-top,
.leaflet-bottom {
	position: absolute;
	z-index: 1000;
	pointer-events: none;
	}
.leaflet-top {
	top: 0;
	}
.leaflet-right {
	right: 0;
	}
.leaflet-bottom {
	bottom: 0;
	}
.leaflet-left {
	left: 0;
	}
.leaflet-control {
	float: left;
	clear: both;
	}
.leaflet-right .leaflet-control {
	float: right;
	}
.leaflet-top .leaflet-control {
	margin-top: 10px;
	}
.leaflet-bottom .leaflet-control {
	margin-bottom: 10px;
	}
.leaflet-left .leaflet-control {
	margin-left: 10px;
	}
.leaflet-right .leaflet-control {
	margin-right: 10px;
	}


/* zoom and fade animations */

.leaflet-fade-anim .leaflet-popup {
	opacity: 0;
	-webkit-transition: opacity 0.2s linear;
	   -moz-transition: opacity 0.2s linear;
	        transition: opacity 0.2s linear;
	}
.leaflet-fade-anim .leaflet-map-pane .leaflet-popup {
	opacity: 1;
	}
.leaflet-zoom-animated {
	-webkit-transform-origin: 0 0;
	    -ms-transform-origin: 0 0;
	        transform-origin: 0 0;
	}
svg.leaflet-zoom-animated {
	will-change: transform;
}

.leaflet-zoom-anim .leaflet-zoom-animated {
	-webkit-transition: -webkit-transform 0.25s cubic-bezier(0,0,0.25,1);
	   -moz-transition:    -moz-transform 0.25s cubic-bezier(0,0,0.25,1);
	        transition:         transform 0.25s cubic-bezier(0,0,0.25,1);
	}
.leaflet-zoom-anim .leaflet-tile,
.leaflet-pan-anim .leaflet-tile {
	-webkit-transition: none;
	   -moz-transition: none;
	        transition: none;
	}

.leaflet-zoom-anim .leaflet-zoom-hide {
	visibility: hidden;
	}


/* cursors */

.leaflet-interactive {
	cursor: pointer;
	}
.leaflet-grab {
	cursor: -webkit-grab;
	cursor:    -moz-grab;
	cursor:         grab;
	}
.leaflet-crosshair,
.leaflet-crosshair .leaflet-interactive {
	cursor: crosshair;
	}
.leaflet-popup-pane,
.leaflet-control {
	cursor: auto;
	}
.leaflet-dragging .leaflet-grab,
.leaflet-dragging .leaflet-grab .leaflet-interactive,
.leaflet-dragging .leaflet-marker-draggable {
	cursor: move;
	cursor: -webkit-grabbing;
	cursor:    -moz-grabbing;
	cursor:         grabbing;
	}

/* marker & overlays interactivity */
.leaflet-marker-icon,
.leaflet-marker-shadow,
.leaflet-image-layer,
.leaflet-pane > svg path,
.leaflet-tile-container {
	pointer-events: none;
	}

.leaflet-marker-icon.leaflet-interactive,
.leaflet-image-layer.leaflet-interactive,
.leaflet-pane > svg path.leaflet-interactive,
svg.leaflet-image-layer.leaflet-interactive path {
	pointer-events: visiblePainted; /* IE 9-10 doesn't have auto */
	pointer-events: auto;
	}

/* visual tweaks */

.leaflet-container {
	background: #ddd;
	outline-offset: 1px;
	}
.leaflet-container a {
	color: #0078A8;
	}
.leaflet-zoom-box {
	border: 2px dotted #38f;
	background: rgba(255,255,255,0.5);
	}


/* general typography */
.leaflet-container {
	font-family: "Helvetica Neue", Arial, Helvetica, sans-serif;
	font-size: 12px;
	font-size: 0.75rem;
	line-height: 1.5;
	}


/* general toolbar styles */

.leaflet-bar {
	box-shadow: 0 1px 5px rgba(0,0,0,0.65);
	border-radius: 4px;
	}
.leaflet-bar a {
	background-color: #fff;
	border-bottom: 1px solid #ccc;
	width: 26px;
	height: 26px;
	line-height: 26px;
	display: block;
	text-align: center;
	text-decoration: none;
	color: black;
	}
.leaflet-bar a,
.leaflet-control-layers-toggle {
	background-position: 50% 50%;
	background-repeat: no-repeat;
	display: block;
	}
.leaflet-bar a:hover,
.leaflet-bar a:focus {
	background-color: #f4f4f4;
	}
.leaflet-bar a:first-child {
	border-top-left-radius: 4px;
	border-top-right-radius: 4px;
	}
.leaflet-bar a:last-child {
	border-bottom-left-radius: 4px;
	border-bottom-right-radius: 4px;
	border-bottom: none;
	}
.leaflet-bar a.leaflet-disabled {
	cursor: default;
	background-color: #f4f4f4;
	color: #bbb;
	}

.leaflet-touch .leaflet-bar a {
	width: 30px;
	height: 30px;
	line-height: 30px;
	}
.leaflet-touch .leaflet-bar a:first-child {
	border-top-left-radius: 2px;
	border-top-right-radius: 2px;
	}
.leaflet-touch .leaflet-bar a:last-child {
	border-bottom-left-radius: 2px;
	border-bottom-right-radius: 2px;
	}

/* zoom control */

.leaflet-control-zoom-in,
.leaflet-control-zoom-out {
	font: bold 18px 'Lucida Console', Monaco, monospace;
	text-indent: 1px;
	}

.leaflet-touch .leaflet-control-zoom-in, .leaflet-touch .leaflet-control-zoom-out  {
	font-size: 22px;
	}


/* layers control */

.leaflet-control-layers {
	box-shadow: 0 1px 5px rgba(0,0,0,0.4);
	background: #fff;
	border-radius: 5px;
	}
.leaflet-control-layers-toggle {
	background-image: url(images/layers.png);
	width: 36px;
	height: 36px;
	}
.leaflet-retina .leaflet-control-layers-toggle {
	background-image: url(images/layers-2x.png);
	background-size: 26px 26px;
	}
.leaflet-touch .leaflet-control-layers-toggle {
	width: 44px;
	height: 44px;
	}
.leaflet-control-layers .leaflet-control-layers-list,
.leaflet-control-layers-expanded .leaflet-control-layers-toggle {
	display: none;
	}
.leaflet-control-layers-expanded .leaflet-control-layers-list {
	display: block;
	position: relative;
	}
.leaflet-control-layers-expanded {
	padding: 6px 10px 6px 6px;
	color: #333;
	background: #fff;
	}
.leaflet-control-layers-scrollbar {
	overflow-y: scroll;
	overflow-x: hidden;
	padding-right: 5px;
	}
.leaflet-control-layers-selector {
	margin-top: 2px;
	position: relative;
	top: 1px;
	}
.leaflet-control-layers label {
	display: block;
	font-size: 13px;
	font-size: 1.08333em;
	}
.leaflet-control-layers-separator {
	height: 0;
	border-top: 1px solid #ddd;
	margin: 5px -10px 5px -6px;
	}

/* Default icon URLs */
.leaflet-default-icon-path { /* used only in path-guessing heuristic, see L.Icon.Default */
	background-image: url(images/marker-icon.png);
	}


/* attribution and scale controls */

.leaflet-container .leaflet-control-attribution {
	background: #fff;
	background: rgba(255, 255, 255, 0.8);
	margin: 0;
	}
.leaflet-control-attribution,
.leaflet-control-scale-line {
	padding: 0 5px;
	color: #333;
	line-height: 1.4;
	}
.leaflet-control-attribution a {
	text-decoration: none;
	}
.leaflet-control-attribution a:hover,
.leaflet-control-attribution a:focus {
	text-decoration: underline;
	}
.leaflet-attribution-flag {
	display: inline !important;
	vertical-align: baseline !important;
	width: 1em;
	height: 0.6669em;
	}
.leaflet-left .leaflet-control-scale {
	margin-left: 5px;
	}
.leaflet-bottom .leaflet-control-scale {
	margin-bottom: 5px;
	}
.leaflet-control-scale-line {
	border: 2px solid #777;
	border-top: none;
	line-height: 1.1;
	padding: 2px 5px 1px;
	white-space: nowrap;
	-moz-box-sizing: border-box;
	     box-sizing: border-box;
	background: rgba(255, 255, 255, 0.8);
	text-shadow: 1px 1px #fff;
	}
.leaflet-control-scale-line:not(:first-child) {
	border-top: 2px solid #777;
	border-bottom: none;
	margin-top: -2px;
	}
.leaflet-control-scale-line:not(:first-child):not(:last-child) {
	border-bottom: 2px solid #777;
	}

.leaflet-touch .leaflet-control-attribution,
.leaflet-touch .leaflet-control-layers,
.leaflet-touch .leaflet-bar {
	box-shadow: none;
	}
.leaflet-touch .leaflet-control-layers,
.leaflet-touch .leaflet-bar {
	border: 2px solid rgba(0,0,0,0.2);
	background-clip: padding-box;
	}


/* popup */

.leaflet-popup {
	position: absolute;
	text-align: center;
	margin-bottom: 20px;
	}
.leaflet-popup-content-wrapper {
	padding: 1px;
	text-align: left;
	border-radius: 12px;
	}
.leaflet-popup-content {
	margin: 13px 24px 13px 20px;
	line-height: 1.3;
	font-size: 13px;
	font-size: 1.08333em;
	min-height: 1px;
	}
.leaflet-popup-content p {
	margin: 17px 0;
	margin: 1.3em 0;
	}
.leaflet-popup-tip-container {
	width: 40px;
	height: 20px;
	position: absolute;
	left: 50%;
	margin-top: -1px;
	margin-left: -20px;
	overflow: hidden;
	pointer-events: none;
	}
.leaflet-popup-tip {
	width: 17px;
	height: 17px;
	padding: 1px;

	margin: -10px auto 0;
	pointer-events: auto;

	-webkit-transform: rotate(45deg);
	   -moz-transform: rotate(45deg);
	    -ms-transform: rotate(45deg);
	        transform: rotate(45deg);
	}
.leaflet-popup-content-wrapper,
.leaflet-popup-tip {
	background: white;
	color: #333;
	box-shadow: 0 3px 14px rgba(0,0,0,0.4);
	}
.leaflet-container a.leaflet-popup-close-button {
	position: absolute;
	top: 0;
	right: 0;
	border: none;
	text-align: center;
	width: 24px;
	height: 24px;
	font: 16px/24px Tahoma, Verdana, sans-serif;
	color: #757575;
	text-decoration: none;
	background: transparent;
	}
.leaflet-container a.leaflet-popup-close-button:hover,
.leaflet-container a.leaflet-popup-close-button:focus {
	color: #585858;
	}
.leaflet-popup-scrolled {
	overflow: auto;
	}

.leaflet-oldie .leaflet-popup-content-wrapper {
	-ms-zoom: 1;
	}
.leaflet-oldie .leaflet-popup-tip {
	width: 24px;
	margin: 0 auto;

	-ms-filter: "progid:DXImageTransform.Microsoft.Matrix(M11=0.70710678, M12=0.70710678, M21=-0.70710678, M22=0.70710678)";
	filter: progid:DXImageTransform.Microsoft.Matrix(M11=0.70710678, M12=0.70710678, M21=-0.70710678, M22=0.70710678);
	}

.leaflet-oldie .leaflet-control-zoom,
.leaflet-oldie .leaflet-control-layers,
.leaflet-oldie .leaflet-popup-content-wrapper,
.leaflet-oldie .leaflet-popup-tip {
	border: 1px solid #999;
	}


/* div icon */

.leaflet-div-icon {
	background: #fff;
	border: 1px solid #666;
	}


/* Tooltip */
/* Base styles for the element that has a tooltip */
.leaflet-tooltip {
	position: absolute;
	padding: 6px;
	background-color: #fff;
	border: 1px solid #fff;
	border-radius: 3px;
	color: #222;
	white-space: nowrap;
	-webkit-user-select: none;
	-moz-user-select: none;
	-ms-user-select: none;
	user-select: none;
	pointer-events: none;
	box-shadow: 0 1px 3px rgba(0,0,0,0.4);
	}
.leaflet-tooltip.leaflet-interactive {
	cursor: pointer;
	pointer-events: auto;
	}
.leaflet-tooltip-top:before,
.leaflet-tooltip-bottom:before,
.leaflet-tooltip-left:before,
.leaflet-tooltip-right:before {
	position: absolute;
	pointer-events: none;
	border: 6px solid transparent;
	background: transparent;
	content: "";
	}

/* Directions */

.leaflet-tooltip-bottom {
	margin-top: 6px;
}
.leaflet-tooltip-top {
	margin-top: -6px;
}
.leaflet-tooltip-bottom:before,
.leaflet-tooltip-top:before {
	left: 50%;
	margin-left: -6px;
	}
.leaflet-tooltip-top:before {
	bottom: 0;
	margin-bottom: -12px;
	border-top-color: #fff;
	}
.leaflet-tooltip-bottom:before {
	top: 0;
	margin-top: -12px;
	margin-left: -6px;
	border-bottom-color: #fff;
	}
.leaflet-tooltip-left {
	margin-left: -6px;
}
.leaflet-tooltip-right {
	margin-left: 6px;
}
.leaflet-tooltip-left:before,
.leaflet-tooltip-right:before {
	top: 50%;
	margin-top: -6px;
	}
.leaflet-tooltip-left:before {
	right: 0;
	margin-right: -12px;
	border-left-color: #fff;
	}
.leaflet-tooltip-right:before {
	left: 0;
	margin-left: -12px;
	border-right-color: #fff;
	}

/* Printing */

@media print {
	/* Prevent printers from removing background-images of controls. */
	.leaflet-control {
		-webkit-print-color-adjust: exact;
		print-color-adjust: exact;
		}
	}

LEAFLET_CSS
cat > "$APP/index.html" <<'TURTLETAK_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TurtleTAK Hub Edition</title>
<style>
:root{--bg:#0f1411;--panel:#17201a;--line:#2a3a2f;--text:#dfe8e1;--dim:#8fa396;--acc:#6fcf4a;--warn:#f2b631;--crit:#ff5c5c;--info:#4fb3ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;background:#0a0e0b;border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{font-size:17px;margin:0;letter-spacing:.5px}
header h1 b{color:var(--acc)}
header .ed{color:var(--dim);font-size:12px}
.pill{padding:2px 9px;border-radius:10px;font-size:12px;border:1px solid var(--line);white-space:nowrap}
.pill.ok{color:#0a0e0b;background:var(--acc);border-color:var(--acc)}
.pill.bad{color:#fff;background:#8a2a2a;border-color:#a33}
.pill.mid{color:#0a0e0b;background:var(--warn);border-color:var(--warn)}
nav{display:flex;gap:2px;padding:0 10px;background:#0a0e0b;border-bottom:1px solid var(--line);overflow-x:auto}
nav button{background:none;border:0;color:var(--dim);padding:10px 14px;cursor:pointer;font-size:14px;border-bottom:2px solid transparent;white-space:nowrap}
nav button.on{color:var(--text);border-bottom-color:var(--acc)}
nav .n{background:var(--crit);color:#fff;border-radius:8px;padding:0 6px;font-size:11px;margin-left:4px}
main{padding:14px;max-width:1200px;margin:auto}
section{display:none}section.on{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px}
.card h3{margin:0 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim)}
.kv{display:grid;grid-template-columns:auto 1fr;gap:3px 12px}.kv div:nth-child(odd){color:var(--dim)}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:500}
button.b,.b{background:#24402c;color:var(--text);border:1px solid #356b43;border-radius:6px;padding:6px 12px;cursor:pointer;font-size:13px}
button.b:hover{background:#2e5537}button.b.red{background:#4a2020;border-color:#7a3030}
input,select,textarea{background:#0c110e;color:var(--text);border:1px solid var(--line);border-radius:5px;padding:6px 8px;font:inherit}
input:focus,select:focus,textarea:focus{outline:1px solid var(--acc)}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.dim{color:var(--dim)}.warn{color:var(--warn)}.crit{color:var(--crit)}.ok{color:var(--acc)}
.alert{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px 12px;margin-bottom:6px}
.alert.lvl-critical{border-left:4px solid var(--crit)}.alert.lvl-warning{border-left:4px solid var(--warn)}.alert.lvl-info{border-left:4px solid var(--info)}
input[type=file]{max-width:100%}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;margin-bottom:8px}
.seg button{background:#0c110e;color:var(--dim);border:0;padding:6px 12px;cursor:pointer}.seg button.on{background:#24402c;color:var(--text)}
.frm{display:grid;grid-template-columns:minmax(150px,190px) minmax(0,420px);gap:6px 10px;align-items:center;margin:8px 0}
details{margin:6px 0}
#map{height:62vh;border-radius:8px;border:1px solid var(--line);background:#0c110e}
.chatlog{height:52vh;overflow-y:auto;background:#0c110e;border:1px solid var(--line);border-radius:8px;padding:8px}
.msg{white-space:pre-wrap;margin:4px 0;padding:6px 10px;border-radius:8px;max-width:80%;background:#1f2b23}
.msg.out{margin-left:auto;background:#244a2f}.msg .h{font-size:11px;color:var(--dim)}
pre{white-space:pre-wrap;background:#0c110e;border:1px solid var(--line);border-radius:6px;padding:8px;font-size:12px;max-height:60vh;overflow:auto}
.cfg{display:grid;grid-template-columns:minmax(160px,220px) 1fr;gap:4px 10px;align-items:center}
.cfg h4{grid-column:1/3;margin:14px 0 2px;color:var(--acc);font-size:13px}
.toast{position:fixed;bottom:16px;right:16px;background:#24402c;border:1px solid var(--acc);padding:9px 14px;border-radius:6px;display:none;max-width:80vw;z-index:9999}
.toast.err{background:#4a2020;border-color:var(--crit)}
#login{max-width:340px;margin:12vh auto;text-align:center}
.tag{font-size:11px;padding:1px 6px;border-radius:4px;background:#2a3a2f}.tag.new{background:var(--warn);color:#111}
footer{color:var(--dim);font-size:12px;text-align:center;padding:20px}
</style>
</head>
<body>
<div id="login" style="display:none" class="card">
  <h2>Turtle<b style="color:var(--acc)">TAK</b></h2><p class="dim">Hub Edition web console</p>
  <form onsubmit="login(event)"><input type="password" id="pw" placeholder="Password" autofocus style="width:100%"><br><br>
  <button class="b" style="width:100%">Sign in</button></form>
  <p class="dim" style="font-size:12px">First password: Hub notifications (bell icon) or /root/turtletak/web-password.txt</p>
</div>
<div id="app" style="display:none">
<header>
  <h1>Turtle<b>TAK</b></h1><span class="ed" id="ed">Hub Edition</span>
  <span class="pill" id="p-tak">TAK</span><span class="pill" id="p-rj">RJ45</span><span class="pill" id="p-loc">Location</span>
  <span style="flex:1"></span><span class="dim" id="h-cs"></span>
  <button class="b" onclick="logout()">Sign out</button>
</header>
<nav id="nav"></nav>
<main>
<section id="t-status">
  <div class="grid">
    <div class="card"><h3>TAK Server</h3><div class="kv" id="k-tak"></div>
      <div class="row"><button class="b" onclick="act('reconnect')">Reconnect</button><button class="b" onclick="act('send_sa')">Send position now</button></div></div>
    <div class="card"><h3>Network</h3><div class="kv" id="k-net"></div></div>
    <div class="card"><h3>Location</h3><div class="kv" id="k-loc"></div></div>
    <div class="card"><h3>Hub</h3><div class="kv" id="k-hub"></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>What TAK sees (marker remarks)</h3><pre id="remarks"></pre></div>
</section>
<section id="t-map">
  <div class="row"><select id="mp-src" onchange="setCfg({MAP_SOURCE:this.value});mapSource(this.value)"></select>
    <label class="dim">Save to zoom</label><select id="mp-z"><option>13</option><option>14</option><option selected>15</option><option>16</option></select>
    <button class="b" onclick="saveArea()">Save this area offline</button><button class="b" onclick="act('tiles_stop')">Stop</button>
    <button class="b red" onclick="if(confirm('Delete every saved map tile on the Hub?'))act('tiles_clear')">Clear saved maps</button><span class="dim" id="mp-st"></span></div>
  <div id="map"></div>
  <p class="dim" id="mapnote">Click the map to place the Hub there (manual location). Map tiles come through the Hub and are kept there, so places you have viewed or saved work without internet. USGS maps cover the US.</p>
  <div class="card"><h3>Contacts (range and bearing from the Hub)</h3><table id="tb-contacts"></table></div>
</section>
<section id="t-chat">
  <div class="chatlog" id="chatlog"></div>
  <form class="row" onsubmit="sendChat(event)">
    <select id="chat-to"><option value="">All Chat Rooms</option></select>
    <input id="chat-text" style="flex:1;min-width:200px" placeholder="Message" maxlength="1000">
    <button class="b">Send</button>
  </form>
  <p class="dim">Others can direct-message the Hub: <b>status</b>, <b>where</b>, <b>scan</b>, <b>alerts</b>, <b>help</b>.</p>
</section>
<section id="t-alerts">
  <div class="card" style="margin-bottom:12px"><h3>Alert settings</h3>
    <div class="row" id="al-kinds"></div>
    <div class="frm"><label>Map marker from</label><select id="al-marker"><option value="info">info</option><option value="warning">warning</option><option value="critical">critical</option></select>
      <label>Chat line from</label><select id="al-chat"><option value="info">info</option><option value="warning">warning</option><option value="critical">critical</option></select>
      <label>Quiet hours</label><div class="row" style="margin:0"><input id="al-quiet" placeholder="e.g. 22-06 (blank = off)" size="16"><label><input type="checkbox" id="al-qcrit"> critical alerts still go out</label></div></div>
    <p class="dim">In quiet hours alerts are still logged, marked on the map and shown in the Hub's notifications, but there are no chat lines or LED flashes.</p>
    <div class="row"><button class="b" onclick="saveAlertCfg()">Save alert settings</button><span class="dim" id="al-qnow"></span></div></div>
  <div class="row"><button class="b" onclick="act('test_alert')">Send test alert</button><button class="b red" onclick="if(confirm('Clear the alert list on the Hub?'))act('clear_alerts')">Clear list</button></div>
  <div id="alertlist"></div>
</section>
<section id="t-network">
  <div class="grid"><div class="card"><h3>Watch</h3><div class="kv" id="k-watch"></div>
    <div class="row"><button class="b" onclick="act('scan')">Sweep now</button><button class="b" onclick="act('dhcp')">Check DHCP now</button>
    <button class="b" onclick="if(confirm('Mark every device seen as known (update the baseline)?'))act('accept')">Accept all as known</button></div></div>
    <div class="card"><h3>Site survey data package</h3><p class="dim">Device list, baseline, alerts and a summary, as a TAK data package with a survey marker at the Hub.</p>
      <div class="row"><select id="sv-to"><option value="">Send to everyone</option><option value="upload">Upload to the server only</option></select><button class="b" onclick="act('send_survey',{to:$('sv-to').value})">Send to TAK</button><a class="b" href="/api/survey" style="text-decoration:none">Download</a></div></div></div>
  <p class="dim">Name devices so alerts use the name. <b>Watch</b> a device (camera, NVR, door controller) to get a <b>Device missing</b> alert when it stops answering.</p>
  <div class="card" style="margin-top:12px"><h3>Devices on the RJ45 network</h3><table id="tb-hosts"></table></div>
</section>
<section id="t-bridge">
  <div class="grid">
    <div class="card"><h3>Mesh SA bridge</h3><div class="kv" id="k-bridge"></div>
      <div class="row"><label><input type="checkbox" id="br-up" onchange="setCfg({BRIDGE_UP:this.checked?'1':'0'})"> LAN mesh &rarr; TAK Server</label></div>
      <div class="row"><label><input type="checkbox" id="br-down" onchange="setCfg({BRIDGE_DOWN:this.checked?'1':'0'})"> TAK Server &rarr; LAN mesh</label></div>
      <p class="dim">Puts ATAK devices on a closed LAN (default mesh 239.2.3.1:6969, chat 224.10.10.1:17012) on your TAK Server, and the server's traffic back onto the LAN. XML and TAK protocol v1 (protobuf) are both understood.</p></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>Devices heard on the mesh</h3><table id="tb-mesh"></table></div>
</section>
<section id="t-settings">
  <div class="row"><button class="b" onclick="saveCfg()">Save settings</button><span class="dim">Secrets show blank; leave them blank to keep them.</span></div>
  <div class="card"><div class="cfg" id="cfgform"></div></div>
  <div class="row"><button class="b" onclick="saveCfg()">Save settings</button></div>
</section>
<section id="t-setup">
  <div class="grid">
    <div class="card" style="grid-column:1/-1"><h3>1. TAK Server connection</h3>
      <div class="seg" id="seg"><button class="on" onclick="pane('cp',this)">Connection package</button><button onclick="pane('cr',this)">Certificates</button><button onclick="pane('en',this)">Enroll</button></div>
      <div id="p-cp" class="pane">
        <p>The <b>.zip</b> data package from your TAK Server admin. Server, port, protocol and both certificates come from it, with the passwords stored inside it.</p>
        <div class="row"><input type="file" id="cp-file" accept=".zip"></div>
        <details><summary class="dim">Package asks for passwords?</summary>
          <div class="frm"><label>Client certificate password</label><input type="password" id="cp-cpw" placeholder="blank = from the package" autocomplete="off">
          <label>Truststore password</label><input type="password" id="cp-tpw" placeholder="blank = from the package" autocomplete="off"></div></details>
        <div class="row"><button class="b" onclick="importPkg()">Import and connect</button></div>
      </div>
      <div id="p-cr" class="pane" style="display:none">
        <p>Same as ATAK's <i>Add Server</i>: the server, then the <b>client certificate</b> and the <b>truststore</b>, each with its own password.</p>
        <div class="frm">
          <label>Server address</label><input id="cr-host" placeholder="takserver.example.com">
          <label>Port / protocol</label><div class="row" style="margin:0"><input id="cr-port" size="6" placeholder="8089"><select id="cr-proto"><option value="tls">SSL/TLS</option><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
          <label>Client certificate</label><input type="file" id="cr-client" accept=".p12,.pfx,.pem">
          <label>Client password</label><input type="password" id="cr-cpw" placeholder="default atakatak" autocomplete="off">
          <label>Truststore (CA)</label><input type="file" id="cr-trust" accept=".p12,.pfx,.pem">
          <label>Truststore password</label><input type="password" id="cr-tpw" placeholder="default atakatak" autocomplete="off">
        </div>
        <div class="row"><button class="b" onclick="saveCerts()">Save and connect</button><span class="dim">Leave a file empty to keep the one already loaded.</span></div>
      </div>
      <div id="p-en" class="pane" style="display:none">
        <p>Get a certificate from the TAK Server with your TAK username and password (certificate enrollment, port 8446 by default). Uses the server address from Settings or the Certificates tab. Takes up to a minute on the Hub.</p>
        <div class="frm"><label>Server address</label><input id="en-host" placeholder="takserver.example.com">
          <label>Username</label><input id="en-u" autocomplete="off"><label>Password</label><input id="en-p" type="password" autocomplete="new-password"></div>
        <div class="row"><button class="b" onclick="enroll()">Enroll and connect</button></div>
      </div>
      <div class="kv" id="k-certs" style="margin-top:10px"></div>
      <div class="row"><button class="b" onclick="diag()">Test connection</button><button class="b" onclick="act('reconnect')">Reconnect</button><button class="b" onclick="if(confirm('Put back the certificates that were loaded before the last import or enrollment?'))act('restore_certs')">Restore previous certificates</button></div>
      <pre id="diag" style="display:none"></pre>
    </div>
    <div class="card"><h3>2. Location</h3>
      <div class="row"><input id="lat" placeholder="Latitude" size="11"><input id="lon" placeholder="Longitude" size="11"><input id="site" placeholder="Save as site (optional)" size="16"><button class="b" onclick="setPos()">Set</button></div>
      <p class="dim">Auto mode uses, in order: USB GPS on the dynamic port, your ATAK position (MY_ATAK), the saved SITE, the manual lat/lon, then public-IP location (rough).</p>
      <table id="tb-sites"></table></div>
    <div class="card"><h3>3. Uplinks</h3>
      <p>Out-of-band Wi-Fi (WIFI_SSID / WIFI_KEY in Settings) and WireGuard. Upload a <b>wg.conf</b> to bring up the Hub's WireGuard client:</p>
      <div class="row"><input type="file" id="up-wg" accept=".conf"><button class="b" onclick="upload('up-wg')">Upload wg.conf</button><button class="b" onclick="act('uplinks')">Re-apply uplinks</button></div></div>
    <div class="card"><h3>4. Clone to another Hub</h3>
      <p>Download this Hub's settings, certificates, sites, device names and baselines as one <b>.turtletak</b> file, then load it on another Hub. The other Hub keeps its own web password and gets its own UID and callsign.</p>
      <div class="row"><a class="b" href="/api/export" style="text-decoration:none">Download clone package</a></div>
      <p class="warn" style="font-size:12px">It contains your TAK certificates and Wi-Fi key - keep it private.</p>
      <div class="row"><input type="file" id="cl-file" accept=".turtletak"><input id="cl-cs" placeholder="Callsign for this Hub" size="18"><button class="b" onclick="cloneImport()">Load clone package</button></div></div>
    <div class="card"><h3>5. Hub</h3>
      <div class="row"><label><input type="checkbox" id="boot" onchange="act('boot',{on:this.checked})"> Run TurtleTAK at boot</label></div>
      <div class="row"><label><input type="checkbox" id="ledon" onchange="setCfg({LED:this.checked?'1':'0'})"> Use the LED (off = stealth)</label></div>
      <div class="row"><input type="password" id="newpw" placeholder="New web password (8+)" autocomplete="new-password"><button class="b" onclick="setPw()">Change password</button></div>
      <h3 style="margin-top:12px">Setup check</h3><div class="kv" id="k-check"></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>Log</h3><div class="row"><button class="b" onclick="loadLog()">Refresh</button></div><pre id="log"></pre></div>
</section>
</main>
<footer>TurtleTAK Hub Edition <span id="ver"></span> &middot; SECT0101 &middot; Use only on networks you own or are authorized to monitor.</footer>
</div>
<div class="toast" id="toast"></div>
<script>
const TABS=[["status","Status"],["map","Map"],["chat","Chat"],["alerts","Alerts"],["network","Network"],["bridge","Mesh Bridge"],["settings","Settings"],["setup","Setup"]];
let ST=null,tab=localStorageGet("tt_tab")||"status",map=null,layers=null,chatSig="",cfgLoaded=false,seenAlerts=+(localStorageGet("tt_seen")||0);
function localStorageGet(k){try{return localStorage.getItem(k)}catch(e){return null}}
function localStorageSet(k,v){try{localStorage.setItem(k,v)}catch(e){}}
const $=id=>document.getElementById(id);
const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function toast(m,err){const t=$("toast");t.textContent=m;t.className="toast"+(err?" err":"");t.style.display="block";clearTimeout(t._h);t._h=setTimeout(()=>t.style.display="none",4500)}
async function api(path,opt={}){opt.headers=Object.assign({"X-TT":"1"},opt.headers||{});opt.credentials="same-origin";
  const r=await fetch(path,opt);if(r.status==401){showLogin();throw new Error("sign in")}
  const ct=r.headers.get("content-type")||"";const d=ct.includes("json")?await r.json():await r.text();
  if(!r.ok)throw new Error(d.error||r.statusText);return d}
function showLogin(){$("app").style.display="none";$("login").style.display="block"}
async function login(e){e.preventDefault();try{await api("/api/login",{method:"POST",body:JSON.stringify({password:$("pw").value})});$("pw").value="";$("login").style.display="none";$("app").style.display="block";await refresh();go(tab)}catch(x){toast(x.message,1)}}
async function logout(){try{await api("/api/logout",{method:"POST"})}catch(e){}showLogin()}
async function act(a,extra={}){try{const d=await api("/api/action",{method:"POST",body:JSON.stringify(Object.assign({action:a},extra))});toast(d.msg||"done");refresh()}catch(e){toast(e.message,1)}}
async function setCfg(o){try{const d=await api("/api/cfg",{method:"POST",body:JSON.stringify(o)});toast(d.msg);cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
function nav(){$("nav").innerHTML=TABS.map(([k,l])=>`<button class="${k==tab?"on":""}" onclick="go('${k}')">${l}${k=="alerts"?'<span class="n" id="n-al" style="display:none"></span>':""}</button>`).join("");
  document.querySelectorAll("section").forEach(s=>s.classList.toggle("on",s.id=="t-"+tab))}
function syncChecks(){api("/api/cfg").then(c=>{const g=k=>(c.find(r=>r.key==k)||{}).value;const hst=g("TAK_HOST")||"";if(!/example\.com$/.test(hst)){$("cr-host").value=hst;$("en-host").value=hst}$("cr-port").value=g("TAK_PORT")||"";$("cr-proto").value=g("TAK_PROTO")||"tls";$("boot").checked=g("RUN_AT_BOOT")=="1";$("ledon").checked=g("LED")!="0"}).catch(()=>{})}
function go(k){tab=k;if(k=="setup")syncChecks();if(k=="alerts"&&ST)loadAlertCfg();localStorageSet("tt_tab",k);nav();if(k=="map")setTimeout(initMap,50);if(k=="settings")loadCfg();if(k=="setup")loadLog();if(k=="alerts"&&ST&&ST.alerts.length){seenAlerts=ST.alerts[0].time;localStorageSet("tt_seen",seenAlerts)}render()}
const ago=s=>{s=Math.max(0,Math.round(s));return s<90?s+"s":s<5400?Math.round(s/60)+"m":s<172800?Math.floor(s/3600)+"h"+String(Math.floor(s%3600/60)).padStart(2,"0"):Math.floor(s/86400)+"d"};
const tm=t=>new Date(t*1000).toLocaleString();
const kv=(id,rows)=>$(id).innerHTML=rows.filter(r=>r).map(([k,v])=>`<div>${esc(k)}</div><div>${v}</div>`).join("");
function pill(id,cls,txt){const p=$(id);p.className="pill "+cls;p.textContent=txt}
function render(){if(!ST)return;const s=ST,st=s.status||{},t=s.tak,p=s.pos;
  $("ver").textContent=s.version;$("h-cs").textContent=s.callsign;
  pill("p-tak",t.state=="connected"?"ok":t.state=="connecting"?"mid":"bad","TAK "+t.state);
  pill("p-rj",st.rj45_link?"ok":"bad",st.rj45_link?"RJ45 link":"RJ45 no link");
  pill("p-loc",p.lat==null?"bad":p.ce>1000?"mid":"ok","Loc: "+p.src);
  const na=s.alerts.filter(a=>a.time>seenAlerts&&a.level!="info").length,n=$("n-al");if(n){n.textContent=na;n.style.display=na?"inline":"none"}
  if(tab=="status"){kv("k-tak",[["Server",esc(t.host+":"+t.port+" ("+t.proto+")")],["State",`<span class="${t.state=="connected"?"ok":"warn"}">${esc(t.state)}</span> for ${ago(s.now-t.since)}`],t.error?["Error",`<span class="crit">${esc(t.error)}</span>`]:null,["Sent / received",t.tx+" / "+t.rx],s.cert&&s.cert.days!=null?["Certificate expires",`<span class="${s.cert.days<0?"crit":s.cert.days<=30?"warn":"ok"}">${new Date(s.cert.expires*1000).toLocaleDateString()} (${s.cert.days<0?"EXPIRED":s.cert.days+" days"})</span>`]:null,["Queued",t.queued],["Callsign",esc(s.callsign)],["UID",esc(s.uid)]]);
    kv("k-net",[["Uplink",esc(st.uplink+(st.gateway?" via "+st.gateway:""))],["RJ45",esc((st.rj45||"?")+" "+(st.rj45_link?"link ":"NO LINK ")+(st.rj45_ip||""))],["Wi-Fi client",esc(st.wifi_client||"off")],["VPN",esc(st.vpn||"none")],st.netbird?["NetBird",esc(st.netbird)]:null,["Public IP",esc((st.public_ip||"?")+" "+(st.isp||""))],["Target (USB-C) leases",st.target_leases]]);
    kv("k-loc",[["Source",esc(p.src)],["Position",p.lat==null?"unknown":p.lat.toFixed(6)+", "+p.lon.toFixed(6)],["Accuracy",p.ce>=9999999?"?":"+/- "+Math.round(p.ce)+" m"],["GPS",esc(s.gps.device?(s.gps.device+(s.gps.fix?" fix, "+s.gps.sats+" sats":" no fix")):"none")]]);
    kv("k-hub",[["Uptime",ago(st.uptime||0)],["TurtleTAK up",ago(s.uptime)],["Load",esc(st.load)],["Memory free",Math.round((st.mem_free_kb||0)/1024)+" of "+Math.round((st.mem_total_kb||0)/1024)+" MB"],["OS",esc(st.os)],["Python",esc(st.python)]]);
    $("remarks").textContent=s.status_text}
  if(tab=="map"){const t2=s.tiles||{},sel=$("mp-src");if(!sel.options.length){sel.innerHTML=Object.entries(t2.sources||{}).map(([k,v])=>`<option value="${k}">${esc(v)}</option>`).join("");sel.value=t2.source}
    const j=t2.job;$("mp-st").textContent=(j&&j.running?`Saving ${j.done}/${j.total} tiles... `:j?`Last save: ${j.saved} new, ${j.failed} failed${j.error?" - "+j.error:""}. `:"")+`Saved maps: ${t2.mb} of ${t2.limit_mb} MB`+(t2.root&&t2.root.indexOf("/usb")>=0?" (USB)":"");drawMap();$("tb-contacts").innerHTML="<tr><th>Callsign</th><th>Team</th><th>Range</th><th>Bearing</th><th>Seen</th><th>Via</th></tr>"+s.contacts.map(c=>`<tr><td>${esc(c.callsign)}</td><td>${esc(c.team)}</td><td>${c.dist==null?"":c.dist<1000?c.dist+" m":(c.dist/1000).toFixed(1)+" km"}</td><td>${c.brg==null?"":c.brg+"&deg;"}</td><td>${ago(c.age)} ago</td><td>${esc(c.source)}</td></tr>`).join("")}
  if(tab=="chat"){const sig=s.chat.length+":"+(s.chat.length?s.chat[s.chat.length-1].id:"");if(sig!=chatSig){chatSig=sig;const l=$("chatlog");l.innerHTML=s.chat.map(m=>`<div class="msg ${m.dir}"><div class="h">${esc(m.from)} &rarr; ${esc(m.room)} &middot; ${tm(m.time)}${m.dir=="out"&&m.sent===false?" &middot; queued":""}</div>${esc(m.text)}</div>`).join("")||'<p class="dim">No messages yet.</p>';l.scrollTop=l.scrollHeight}
    const sel=$("chat-to"),cur=sel.value,names=[...new Set(s.contacts.filter(c=>c.type.startsWith("a-f-G-U")||c.source=="mesh").map(c=>c.callsign))].sort();
    if(sel._n!=names.join("|")){sel._n=names.join("|");sel.innerHTML='<option value="">All Chat Rooms</option>'+names.map(n=>`<option>${esc(n)}</option>`).join("");sel.value=cur}}
  if(tab=="alerts"){$("al-qnow").textContent=s.quiet?"Quiet hours now":"";$("alertlist").innerHTML=s.alerts.map(a=>`<div class="alert lvl-${a.level}"><b>${esc(a.title)}</b> <span class="dim">${tm(a.time)} &middot; ${esc(a.kind)}</span><br>${esc(a.detail)}</div>`).join("")||'<p class="dim">No alerts.</p>'}
  if(tab=="network"){const n=s.net;kv("k-watch",[["Interface",esc((n.iface||"?")+" "+(n.my_ip||""))],["Subnet",esc(n.subnet||"")],["Gateway",esc((n.gateway||"")+" "+(n.gateway_mac||""))],["State",esc(n.state||"waiting")],["Devices",(n.count||0)+" seen, "+(n.new||0)+" new"],["Baseline",n.baseline?(n.baseline_count+" known devices"):"none yet"],["Last sweep",n.last_sweep?ago(s.now-n.last_sweep)+" ago ("+esc(n.method)+", "+n.took+" s)":"pending"],["DHCP servers",esc(n.dhcp||"not checked yet")]]);
    const tb=$("tb-hosts"),sig=JSON.stringify(s.hosts.map(h=>[h.mac,h.ip,h.known,h.name,h.watch,h.missing,Math.round((s.now-h.last)/60)]));
    if(tb._sig!=sig&&!tb.contains(document.activeElement)){tb._sig=sig;tb.innerHTML="<tr><th>IP</th><th>Name</th><th>Watch</th><th>MAC</th><th>Vendor</th><th></th><th>Last seen</th></tr>"+s.hosts.map(h=>`<tr><td>${esc(h.ip)}</td><td><input value="${esc(h.name)}" placeholder="name" size="14" onchange="act('set_device',{mac:'${h.mac}',name:this.value})"></td><td><input type="checkbox" ${h.watch?"checked":""} onchange="act('set_device',{mac:'${h.mac}',watch:this.checked})"></td><td>${esc(h.mac)}</td><td>${esc(h.vendor)}</td><td>${h.missing?'<span class="tag" style="background:var(--crit);color:#fff">MISSING</span>':h.known?'<span class="tag">known</span>':'<span class="tag new">NEW</span>'}</td><td>${ago(s.now-h.last)} ago</td></tr>`).join("")}
    const sv=$("sv-to"),names=[...new Set(s.contacts.filter(c=>c.type.startsWith("a-f-G-U")).map(c=>c.callsign))].sort();if(sv._n!=names.join("|")){const cur=sv.value;sv._n=names.join("|");sv.innerHTML='<option value="">Send to everyone</option><option value="upload">Upload to the server only</option>'+names.map(n=>`<option>${esc(n)}</option>`).join("");sv.value=cur}}
  if(tab=="bridge"){const b=s.bridge;$("br-up").checked=b.up;$("br-down").checked=b.down;kv("k-bridge",[["Interfaces",esc((b.ifaces||[]).join(", ")||"off")],["Heard on mesh",b.up_rx],["Forwarded up",b.up_tx],["Repeated down",b.down_tx],b.error?["Error",`<span class="crit">${esc(b.error)}</span>`]:null]);
    $("tb-mesh").innerHTML="<tr><th>Callsign</th><th>IP</th><th>Type</th><th>Last heard</th></tr>"+Object.entries(b.devices||{}).map(([u,d])=>`<tr><td>${esc(d.callsign)}</td><td>${esc(d.ip)}</td><td>${esc(d.type)}</td><td>${ago(s.now-d.last)} ago</td></tr>`).join("")}
  if(tab=="setup"){kv("k-certs",[["Server",esc(t.host+":"+t.port+" ("+t.proto+")")],["Client certificate",s.certs["client.pem"]?'<span class="ok">loaded</span>':'<span class="warn">not loaded</span>'],s.cert&&s.cert.days!=null?["Certificate expires",`<span class="${s.cert.days<0?"crit":s.cert.days<=30?"warn":"ok"}">${new Date(s.cert.expires*1000).toLocaleDateString()} (${s.cert.days<0?"EXPIRED":s.cert.days+" days"})</span>`]:null,["Truststore",s.certs["ca.pem"]?'<span class="ok">loaded</span>':'<span class="dim">not loaded (server not verified)</span>'],st.dns?["DNS lookup",esc(st.dns)]:null,["Status",t.state=="connected"?'<span class="ok">connected</span>':`<span class="warn">${esc(t.state)} ${esc(t.error)}</span>`]]);
    const tl=st.tools||{};kv("k-check",[["TAK",t.state=="connected"?'<span class="ok">connected</span>':`<span class="warn">${esc(t.state)} ${esc(t.error)}</span>`],["openssl",tl.openssl?'<span class="ok">yes</span>':'<span class="dim">no - not needed (built in)</span>'],["nmap",tl.nmap?'<span class="ok">yes</span>':'<span class="dim">no - ping sweep instead</span>'],["wg",tl.wg?"yes":"no"],["RJ45 interface",esc(st.rj45||"not found")],["Interfaces",esc(Object.entries(st.ifaces||{}).map(([k,v])=>k+(v.ipv4&&v.ipv4.length?" "+v.ipv4.join(","):"")).join(" | "))]]);
    $("tb-sites").innerHTML=s.sites.length?"<tr><th>Site</th><th>Lat</th><th>Lon</th><th></th></tr>"+s.sites.map(x=>`<tr><td>${esc(x.name)}</td><td>${x.lat.toFixed(5)}</td><td>${x.lon.toFixed(5)}</td><td><button class="b" onclick="setCfg({SITE:'${esc(x.name).replace(/'/g,"")}',LOC_MODE:'site'})">Use</button></td></tr>`).join(""):""}
}
function initMap(){if(map||!window.L){if(!window.L){const sc=document.createElement("script");sc.src="/static/leaflet.js";sc.onload=initMap;sc.onerror=()=>$("mapnote").textContent="Map library could not load - the contact table below still works.";document.head.appendChild(sc);const ln=document.createElement("link");ln.rel="stylesheet";ln.href="/static/leaflet.css";document.head.appendChild(ln)}return}
  map=L.map("map");mapSource((ST&&ST.tiles&&ST.tiles.source)||"usgs_topo");
  layers=L.layerGroup().addTo(map);const p=ST&&ST.pos;map.setView(p&&p.lat!=null?[p.lat,p.lon]:[20,0],p&&p.lat!=null?16:2);
  map.on("click",e=>{if(confirm("Place the Hub at "+e.latlng.lat.toFixed(6)+", "+e.latlng.lng.toFixed(6)+"? (manual location)"))act("set_pos",{lat:e.latlng.lat,lon:e.latlng.lng})});drawMap()}
function dot(c){return L.divIcon({className:"",html:`<div style="width:14px;height:14px;border-radius:50%;background:${c};border:2px solid #000"></div>`,iconSize:[14,14],iconAnchor:[7,7]})}
function drawMap(){if(!map||!ST)return;layers.clearLayers();const p=ST.pos;
  if(p.lat!=null){L.marker([p.lat,p.lon],{icon:dot("#6fcf4a")}).bindTooltip(ST.callsign+" (Hub)",{permanent:true,direction:"right"}).addTo(layers);if(p.ce<5000)L.circle([p.lat,p.lon],{radius:p.ce,color:"#6fcf4a",weight:1,fillOpacity:.05}).addTo(layers)}
  ST.contacts.forEach(c=>{const col=c.type.startsWith("a-h")?"#ff5c5c":c.type.startsWith("a-u")?"#f2b631":c.type.startsWith("a-n")?"#7de07d":"#4fb3ff";L.marker([c.lat,c.lon],{icon:dot(col)}).bindTooltip(esc(c.callsign)).addTo(layers)})}
async function sendChat(e){e.preventDefault();const t=$("chat-text").value.trim();if(!t)return;await act("chat",{text:t,to:$("chat-to").value});$("chat-text").value=""}
async function loadCfg(){if(cfgLoaded)return;try{const c=await api("/api/cfg");cfgLoaded=true;$("cfgform").innerHTML=c.map(r=>r.section?`<h4>${esc(r.key.replace(/^#\s*/,""))}</h4>`:`<label for="c-${r.key}">${esc(r.key)}</label><input id="c-${r.key}" data-k="${r.key}" ${r.key=="UID"?"readonly title=\"Set once from the device\"":""} ${r.secret?'type="password" placeholder="'+(r.set?"(set - blank keeps it)":"")+'"':""} value="${esc(r.value)}">`).join("")}catch(e){toast(e.message,1)}}
async function saveCfg(){const o={};document.querySelectorAll("#cfgform input").forEach(i=>{if(i.type=="password"&&i.value==="")return;o[i.dataset.k]=i.value});await setCfg(o)}
function pane(k,btn){["cp","cr","en"].forEach(x=>$("p-"+x).style.display=x==k?"block":"none");document.querySelectorAll("#seg button").forEach(b=>b.classList.toggle("on",b==btn))}
async function sendFile(f,hdrs){const h=Object.assign({"X-Filename":f.name,"Content-Type":"application/octet-stream"},hdrs||{});for(const k in h)h[k]=encodeURIComponent(h[k]);return api("/api/upload",{method:"POST",headers:h,body:await f.arrayBuffer()})}
async function importPkg(){const f=$("cp-file").files[0];if(!f)return toast("Choose the .zip first",1);const h={};if($("cp-cpw").value)h["X-Client-Password"]=$("cp-cpw").value;if($("cp-tpw").value)h["X-CA-Password"]=$("cp-tpw").value;
  try{const d=await sendFile(f,h);toast(d.msg);$("cp-file").value="";$("cp-cpw").value="";$("cp-tpw").value="";refresh()}catch(e){toast(e.message,1)}}
async function saveCerts(){try{const cfg={};if($("cr-host").value.trim())cfg.TAK_HOST=$("cr-host").value.trim();if($("cr-port").value.trim())cfg.TAK_PORT=$("cr-port").value.trim();cfg.TAK_PROTO=$("cr-proto").value;
  for(const [id,kind,pw] of [["cr-client","client","cr-cpw"],["cr-trust","ca","cr-tpw"]]){const f=$(id).files[0];if(!f)continue;const h={"X-Cert-Kind":kind};if($(pw).value)h["X-Cert-Password"]=$(pw).value;await sendFile(f,h);$(id).value="";$(pw).value=""}
  await api("/api/cfg",{method:"POST",body:JSON.stringify(cfg)});toast("Saved - connecting");cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
async function upload(id){const f=$(id).files[0];if(!f)return toast("Choose a file first",1);try{const d=await api("/api/upload",{method:"POST",headers:{"X-Filename":f.name,"Content-Type":"application/octet-stream"},body:await f.arrayBuffer()});toast(d.msg);$(id).value="";refresh()}catch(e){toast(e.message,1)}}
function setPos(){act("set_pos",{lat:$("lat").value,lon:$("lon").value,site:$("site").value})}
async function enroll(){if($("en-host").value.trim())await setCfg({TAK_HOST:$("en-host").value.trim()});toast("Enrolling - this can take up to a minute");await act("enroll",{user:$("en-u").value,password:$("en-p").value});$("en-p").value=""}
function setPw(){act("set_password",{password:$("newpw").value});$("newpw").value=""}
async function diag(){const d=$("diag");d.style.display="block";d.textContent="Testing...";try{const r=await api("/api/action",{method:"POST",body:JSON.stringify({action:"diagnose"})});d.textContent=r.msg}catch(e){d.textContent=e.message}}
let tileLayer=null;
function mapSource(src){if(!map)return;if(tileLayer)map.removeLayer(tileLayer);const osm=src=="osm";tileLayer=L.tileLayer("/tiles/"+src+"/{z}/{x}/{y}",{maxZoom:osm?19:16,attribution:osm?"&copy; OpenStreetMap contributors":"USGS The National Map"}).addTo(map)}
function bnds(){const b=map.getBounds();return {s:b.getSouth(),w:b.getWest(),n:b.getNorth(),e:b.getEast()}}
async function saveArea(){if(!map)return toast("Open the map first",1);const src=$("mp-src").value,zmax=+$("mp-z").value,zmin=Math.max(1,map.getZoom()-4);
  try{const r=await api("/api/action",{method:"POST",body:JSON.stringify({action:"tiles_plan",src,bounds:bnds(),zmin,zmax})});if(!confirm("Save "+r.msg+" of this view (zoom "+zmin+"-"+zmax+") on the Hub?"))return;act("tiles_download",{src,bounds:bnds(),zmin,zmax})}catch(e){toast(e.message,1)}}
async function cloneImport(){const f=$("cl-file").files[0];if(!f)return toast("Choose the .turtletak file",1);if(!$("cl-cs").value.trim())return toast("Give this Hub its own callsign",1);
  if(!confirm("Load "+f.name+" onto this Hub? Its TAK settings, certificates, sites and device names are replaced."))return;try{const d=await sendFile(f,{"X-Callsign":$("cl-cs").value.trim()});toast(d.msg);$("cl-file").value="";cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
async function loadAlertCfg(){try{const c=await api("/api/cfg"),g=k=>(c.find(r=>r.key==k)||{}).value||"";const on=g("ALERTS_ON").split(",");
  $("al-kinds").innerHTML=(ST.alert_kinds||[]).map(([k,l])=>`<label style="margin-right:12px"><input type="checkbox" class="al-k" value="${k}" ${on.includes(k)?"checked":""}> ${esc(l)}</label>`).join("");
  $("al-marker").value=g("MARKER_MIN_LEVEL")||"warning";$("al-chat").value=g("CHAT_MIN_LEVEL")||"info";$("al-quiet").value=g("QUIET_HOURS");$("al-qcrit").checked=g("QUIET_CRITICAL")!="0"}catch(e){}}
function saveAlertCfg(){setCfg({ALERTS_ON:[...document.querySelectorAll(".al-k:checked")].map(i=>i.value).join(","),MARKER_MIN_LEVEL:$("al-marker").value,CHAT_MIN_LEVEL:$("al-chat").value,QUIET_HOURS:$("al-quiet").value.trim(),QUIET_CRITICAL:$("al-qcrit").checked?"1":"0"})}
async function loadLog(){try{$("log").textContent=await api("/api/log");$("log").scrollTop=1e9}catch(e){}}
async function refresh(){try{ST=await api("/api/state");$("login").style.display="none";$("app").style.display="block";
  render()}catch(e){}}
(async()=>{nav();await refresh();if(ST)go(tab);else showLogin()})();
setInterval(refresh,4000);
</script>
</body>
</html>
TURTLETAK_HTML

LED SETUP 2>/dev/null
cd "$APP" || exit 1
echo $$ > "$BASE/turtletak.pid"
# exec keeps the PID, so the Hub's payload stop ends the service too
exec "$PY" -u "$APP/turtletak.py" >> "$BASE/logs/console.log" 2>&1
