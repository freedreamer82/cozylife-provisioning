# cozylife-provision

Connect a **CozyLife** Wi-Fi smart plug to your home network **without the CozyLife app** and without a cloud account, from a Linux machine, so you can control it locally (e.g. from Home Assistant).

CozyLife devices normally require the official app for the first Wi-Fi setup. This project re-implements the app's AP-mode pairing step: a single JSON command sent to the plug over its own access point.

> Tested with a CozyLife plug `pid u24dee`, firmware `1.0.4`, hardware `0.0.1`. Other CozyLife models probably use the same pairing protocol, but this has not been verified. Reports are welcome.

## Requirements

- Linux with **NetworkManager** (`nmcli`) and a Wi-Fi adapter
- `python3` (standard library only), `iproute2` (`ip`)
- A **2.4 GHz** home Wi-Fi network (the plug does not support 5 GHz)

## Usage

1. Put the plug in **pairing mode**: hold the button for about 5 seconds until the LED blinks. An open Wi-Fi network named `CozyLife_XXXX` appears.
2. While connected to your home Wi-Fi, run:

```bash
./cozylife_provision.sh
```

The script will:

1. ask for your Wi-Fi password (not echoed, not stored in shell history);
2. wait for the `CozyLife_*` network to appear and connect to it with a temporary DHCP-only profile;
3. send the Wi-Fi credentials to the plug;
4. switch back to your previous network and remove the temporary profile;
5. discover the plug on your home network and print its IP and MAC address.

Example output:

```
Plug: CozyLife_JTVW  ->  home network: MyWiFi
== Sending Wi-Fi configuration ==
Plug info: pid=u24dee firmware=1.0.4 mac=80646fXXXXXX
>> Configuration accepted by the plug.
Reconnected to: MyWiFi
== Waiting for the plug to join the home network (up to 90s) ==

✅ Plug connected!
   IP:  192.168.1.113
   ...
```

### Options

```
./cozylife_provision.sh [options] [PLUG_SSID] [HOME_SSID]

  PLUG_SSID         Plug access point name (default: first visible CozyLife_*)
  HOME_SSID         Home Wi-Fi network (default: network you are connected to now)

  -d, --debug       Print raw protocol frames (password masked), network details
                    and UDP discovery replies
  -t, --token TOK   user_token to send (default: random fake token, no cloud binding)
      --domain DOM  Cloud domain sent to the plug (default: api-eu)
      --wait-ap S   Seconds to wait for the plug AP to appear (default: 60)
      --wait-join S Seconds to wait for the plug to join the home network (default: 90)
  -h, --help        Show help
  -V, --version     Show version
```

Environment variables: `COZY_PASS` (password, for non-interactive use), `COZY_TOKEN`, `COZY_DOMAIN`.

Exit codes: `0` success, `1` error or plug rejected the configuration, `3` configuration accepted but plug not found on the home network.

### Tips

- **Reserve the IP**: create a DHCP reservation on your router for the plug's MAC address so its IP never changes.
- **Block internet access** for the plug on your router if you want it fully local.
- If the plug is still blinking after provisioning, the SSID or password is wrong, or the network is 5 GHz only.

## Home Assistant

Once the plug is on your network, add it with a local CozyLife integration, using the IP printed by the script, for example:

- [yangqian/hass-cozylife](https://github.com/yangqian/hass-cozylife)
- [soulripper13/cozylife_local](https://github.com/soulripper13/cozylife_local)

## Protocol

Everything is plain JSON, one message per line, terminated by `\r\n`.

### Pairing (AP mode)

In pairing mode the plug runs an open access point at `192.168.4.1` with a DHCP server (clients get `192.168.4.x`). It listens on:

| Port | Use |
|------|-----|
| TCP 5555 | commands (info, query, set, **Wi-Fi config**) |
| UDP 6095 | discovery |
| TCP 80 | HTTP server; `/config` accepts only `POST` but the app does not use it |

The official app sends exactly two messages on **TCP 5555**:

**1. Device info** (request, then reply):

```json
{"pv":0,"sn":"1794926581481","msg":{},"cmd":0}
```

```json
{"pv":0,"cmd":0,"sn":"1794926581481","msg":{"did":"1814...","dtp":"02","pid":"u24dee","mac":"80646f...","ip":"192.168.4.1","rssi":0,"sv":"1.0.4","hv":"0.0.1"},"res":0}
```

**2. Wi-Fi configuration** (request, then reply on success):

```json
{"pv":0,"sn":"1794926581509","msg":{"lng":"0","ssid":"MyWiFi","lat":"0","user_token":"de_XXXXXXXXXXXXXXXXXXXXXXXXXXX","domain":"api-eu","passwd":"secret"},"cmd":1}
```

```json
{"pv":0,"sn":"1794927787135","cmd":1,"msg":{"dev_id":"1814..."},"res":0}
```

- `sn` is a timestamp in milliseconds; the plug echoes it back.
- `res` is `0` on success, `1` if rejected.
- `user_token` is the app's account token, used to bind the device to a cloud account. The plug **rejects an empty token** (`res:1`) but accepts a **fake token with the same format** (`de_` + 27 alphanumeric characters). This script sends a random one by default, so the plug is not linked to any account.
- `domain` is the cloud region (`api-eu` for Europe).

### Local control (after pairing)

| Command | Meaning | Example |
|---------|---------|---------|
| `cmd 0` | device info | `{"pv":0,"cmd":0,"sn":"1","msg":{}}` |
| `cmd 2` | query attributes (`[0]` = all) | `{"pv":0,"cmd":2,"sn":"1","msg":{"attr":[0]}}` |
| `cmd 3` | set attributes | `{"pv":0,"cmd":3,"sn":"1","msg":{"attr":[1],"data":{"1":1}}}` |

Attributes reported by this plug: `1` (on/off), `2`, `26`, `28`.

Discovery: send `{"pv":0,"cmd":0,"sn":"<ms>","msg":{}}` as a UDP broadcast to port `6095`; every CozyLife device answers with its info, including `ip` and `mac`.

## How the protocol was found

There was no public documentation of the pairing step. To capture it, the laptop pretended to be the plug: it created an open access point with the same name (`CozyLife_XXXX`) at `192.168.4.1` and logged everything sent to TCP 5555, UDP 6095 and HTTP 80. The real plug was unplugged, and the official app was used once to "pair" with the fake plug, which revealed the two messages above.

## Known issues

- **Local TCP control after pairing with a fake token: under investigation.** In the first test the plug joined the home network and answered UDP discovery, but did not reply to TCP 5555 commands. Possible causes: the plug firmware disables local control until it registers with the cloud, or a known firmware bug where the TCP listener stops working until a power cycle (see [lacherogwu/homeassistant-cozylife](https://github.com/lacherogwu/homeassistant-cozylife)).
- The script requires NetworkManager. During provisioning your machine is briefly disconnected from your home network.

## Disclaimer

Not affiliated with CozyLife. Use at your own risk.
