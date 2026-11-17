#!/usr/bin/env bash
# cozylife_provision.sh — Connect a CozyLife smart plug to your Wi-Fi WITHOUT the CozyLife app.
#
# Protocol (captured from the official app), TCP 5555 on 192.168.4.1, JSON terminated by CRLF:
#   1) {"pv":0,"cmd":0,"sn":"<ms>","msg":{}}                                   -> device info
#   2) {"pv":0,"cmd":1,"sn":"<ms>","msg":{"ssid","passwd","user_token","domain","lat","lng"}}
#      -> {"cmd":1,"msg":{"dev_id":"..."},"res":0} on success, "res":1 if rejected
# Afterwards the plug is discovered on the home network via UDP broadcast on port 6095.
#
# See README.md for details.
set -uo pipefail

VERSION="1.0.0"
DEBUG=0
TOKEN="${COZY_TOKEN:-}"
DOMAIN="${COZY_DOMAIN:-api-eu}"
WAIT_AP=60
WAIT_JOIN=90
POSITIONAL=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [PLUG_SSID] [HOME_SSID]

Provision a CozyLife plug (in pairing / AP mode) with your home Wi-Fi credentials,
without the CozyLife app or a cloud account.

Arguments:
  PLUG_SSID         Plug access point name (default: first visible CozyLife_*)
  HOME_SSID         Home Wi-Fi network, 2.4 GHz (default: network you are connected to now)

Options:
  -d, --debug       Print raw protocol frames, network details and discovery replies
  -t, --token TOK   user_token to send (default: random fake token, no cloud binding)
      --domain DOM  Cloud domain sent to the plug (default: api-eu)
      --wait-ap S   Seconds to wait for the plug AP to appear (default: $WAIT_AP)
      --wait-join S Seconds to wait for the plug to join the home network (default: $WAIT_JOIN)
  -h, --help        Show this help
  -V, --version     Show version

The Wi-Fi password is read interactively (not echoed, not stored in shell history).
Environment: COZY_PASS (password, non-interactive), COZY_TOKEN, COZY_DOMAIN.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--debug) DEBUG=1 ;;
    -t|--token) TOKEN="${2:?--token needs a value}"; shift ;;
    --domain) DOMAIN="${2:?--domain needs a value}"; shift ;;
    --wait-ap) WAIT_AP="${2:?}"; shift ;;
    --wait-join) WAIT_JOIN="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "$VERSION"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done
PLUG_ARG="${POSITIONAL[0]:-}"

info()  { echo "$*"; }
debug() { [[ $DEBUG -eq 1 ]] && echo "[debug] $*" >&2; return 0; }
die()   { echo "ERROR: $*" >&2; exit 1; }

for bin in nmcli python3 ip; do command -v "$bin" >/dev/null || die "'$bin' is required"; done

IFACE="$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1; exit}')"
[[ -z "$IFACE" ]] && die "no Wi-Fi interface found"
PREV_CONN="$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v i="$IFACE" '$2==i{print $1; exit}')"
HOME_SSID="${POSITIONAL[1]:-$(nmcli -t -f ACTIVE,SSID dev wifi list ifname "$IFACE" | awk -F: '$1=="yes"{print $2; exit}')}"
TMP_CON="cozylife-provision-tmp"
DEV="192.168.4.1"
debug "interface=$IFACE previous_connection='$PREV_CONN' home_ssid='$HOME_SSID' domain=$DOMAIN"

[[ -z "$HOME_SSID" ]] && die "cannot detect home network, pass it: $(basename "$0") CozyLife_XXXX MyWiFi"
if [[ -n "${COZY_PASS:-}" ]]; then
  HOME_PASS="$COZY_PASS"
else
  read -rsp "Wi-Fi password for '$HOME_SSID': " HOME_PASS; echo
fi
[[ -z "$HOME_PASS" ]] && die "empty password"

info "== Looking for the plug in pairing mode (up to ${WAIT_AP}s; if it is not blinking, hold the button ~5 s) =="
AP_SSID=""
for ((t=0; t<WAIT_AP; t+=5)); do
  nmcli dev wifi rescan ifname "$IFACE" 2>/dev/null; sleep 5
  LIST="$(nmcli -t -f SSID dev wifi list ifname "$IFACE")"
  if [[ -n "$PLUG_ARG" ]]; then grep -qxF "$PLUG_ARG" <<<"$LIST" && AP_SSID="$PLUG_ARG"
  else AP_SSID="$(grep -m1 '^CozyLife' <<<"$LIST")"; fi
  [[ -n "$AP_SSID" ]] && break
  info "  ...not visible yet ($((t+5)) s)"
  debug "visible networks: $(grep -v '^$' <<<"$LIST" | sort -u | paste -sd, -)"
done
[[ -z "$AP_SSID" ]] && die "network ${PLUG_ARG:-CozyLife_*} not found: the plug is not in pairing mode"
info "Plug: $AP_SSID  ->  home network: $HOME_SSID"

restore() {
  nmcli con delete "$TMP_CON" >/dev/null 2>&1 || true
  if [[ -n "$PREV_CONN" ]]; then
    nmcli con up "$PREV_CONN" >/dev/null 2>&1 && info "Reconnected to: $PREV_CONN"
  fi
}
trap restore EXIT

nmcli con delete "$TMP_CON" >/dev/null 2>&1 || true
# Dedicated DHCP-only profile: never reuse saved profiles that may carry static IPs.
nmcli con add type wifi ifname "$IFACE" con-name "$TMP_CON" ssid "$AP_SSID" \
  ipv4.method auto ipv6.method disabled connection.autoconnect no >/dev/null \
  && nmcli con up "$TMP_CON" >/dev/null || die "could not connect to $AP_SSID"
sleep 3
debug "local address: $(ip -4 -o addr show "$IFACE" | awk '{print $4}' | paste -sd' ' -)"
debug "routes: $(ip route show dev "$IFACE" | paste -sd';' -)"

info "== Sending Wi-Fi configuration =="
OUT="$(HOME_SSID="$HOME_SSID" HOME_PASS="$HOME_PASS" COZY_TOKEN="$TOKEN" COZY_DOMAIN="$DOMAIN" \
       DEV="$DEV" DEBUG="$DEBUG" python3 -I - <<'EOF'
import json, os, random, socket, string, sys, time
DEBUG = os.environ["DEBUG"] == "1"
PASS = os.environ["HOME_PASS"]

def dbg(direction, data):
    if DEBUG:
        text = data.decode(errors="replace").strip()
        if PASS:
            text = text.replace(json.dumps(PASS)[1:-1], "********")
        print(f"[debug] {direction} {text}", file=sys.stderr)

def frame(cmd, msg):
    return (json.dumps({"pv": 0, "sn": str(int(time.time() * 1000)), "msg": msg, "cmd": cmd},
                       separators=(",", ":")) + "\r\n").encode()

def send(s, data):
    dbg(">>", data); s.sendall(data)

def recv_line(s):
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    dbg("<<", buf)
    return buf.decode(errors="replace").strip()

fake = "de_" + "".join(random.choices(string.ascii_letters + string.digits, k=27))
tokens = [os.environ["COZY_TOKEN"]] if os.environ["COZY_TOKEN"] else [fake, "0" * 30]
for tok in tokens:
    s = socket.create_connection((os.environ["DEV"], 5555), timeout=8)
    send(s, frame(0, {}))
    print("INFO", recv_line(s))
    send(s, frame(1, {"lng": "0", "ssid": os.environ["HOME_SSID"], "lat": "0",
                      "user_token": tok, "domain": os.environ["COZY_DOMAIN"], "passwd": PASS}))
    try:
        r = recv_line(s)
    except socket.timeout:
        r = "(no reply: the plug may already be rebooting)"
    s.close()
    print(f"CFG token={tok[:3]}...({len(tok)} chars) -> {r}")
    if '"res":0' in r or not r.startswith("{"):
        break
    time.sleep(1)
EOF
)"
debug "plug replies:"; [[ $DEBUG -eq 1 ]] && sed 's/^/[debug]   /' <<<"$OUT" >&2

MAC="$(grep -o '"mac":"[0-9a-f]*"' <<<"$OUT" | head -n1 | cut -d'"' -f4)"
FW="$(grep -o '"sv":"[^"]*"' <<<"$OUT" | head -n1 | cut -d'"' -f4)"
PID="$(grep -o '"pid":"[^"]*"' <<<"$OUT" | head -n1 | cut -d'"' -f4)"
[[ -z "$MAC" ]] && die "no answer from the plug on $DEV:5555 (run with --debug)"
info "Plug info: pid=$PID firmware=$FW mac=$MAC"

if grep -q '^CFG.*"res":0' <<<"$OUT"; then
  info ">> Configuration accepted by the plug."
elif grep -q '^CFG.*no reply' <<<"$OUT"; then
  info ">> No reply to the configuration command, checking the home network anyway."
else
  die "the plug REJECTED the configuration (res:1). Try --token with a real CozyLife user_token, or run with --debug"
fi

restore; trap - EXIT
info "== Waiting for the plug to join the home network (up to ${WAIT_JOIN}s) =="
FOUND=""
for ((t=0; t<WAIT_JOIN; t+=10)); do
  sleep 10
  FOUND="$(MAC="$MAC" DEBUG="$DEBUG" python3 -I - <<'EOF'
import json, os, socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.settimeout(1)
probe = json.dumps({"pv": 0, "cmd": 0, "sn": str(int(time.time() * 1000)), "msg": {}}).encode()
s.sendto(probe, ("255.255.255.255", 6095))
end = time.time() + 3
while time.time() < end:
    try:
        d, a = s.recvfrom(4096)
    except socket.timeout:
        continue
    if os.environ["DEBUG"] == "1":
        print(f"[debug] UDP reply from {a[0]}: {d.decode(errors='replace')}", file=sys.stderr)
    try:
        m = json.loads(d).get("msg", {})
    except ValueError:
        continue
    if m.get("mac") == os.environ["MAC"]:
        print(a[0], m.get("did", ""), m.get("pid", ""))
        break
EOF
)"
  [[ -n "$FOUND" ]] && break
  info "  ...not yet ($((t+10)) s)"
done

if [[ -n "$FOUND" ]]; then
  read -r IP DID PID <<<"$FOUND"
  cat <<EOF

✅ Plug connected!
   IP:  $IP
   did: $DID
   pid: $PID
   MAC: $MAC   -> create a DHCP reservation for this MAC on your router.

   Test it:
     printf '{"pv":0,"cmd":3,"sn":"1","msg":{"attr":[1],"data":{"1":0}}}\r\n' | nc -w2 $IP 5555   # off
     printf '{"pv":0,"cmd":3,"sn":"1","msg":{"attr":[1],"data":{"1":1}}}\r\n' | nc -w2 $IP 5555   # on
EOF
else
  info "Plug not found via UDP discovery. Check your router's client list for MAC $MAC."
  info "If the plug is still blinking, the SSID or password is wrong (2.4 GHz networks only)."
  exit 3
fi
