# Digi EX50 DAL Admin CLI — interface map

A map of the EX50's scriptable surface (Digi Accelerated Linux, DAL), captured live over SSH during bench bring-up. This is the automation reference behind [ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md) ("its configuration stays in IaC") and the future EX50 Ansible role. For *how to reach* the CLI, see [runbooks/ex50-console-access.md](runbooks/ex50-console-access.md); for the cutover it feeds, see [runbooks/garage-relocation-cutover.md](runbooks/garage-relocation-cutover.md).

Last updated: 2026-07-03 · Captured from firmware **25.11.10.42** (schema version 1276) over SSH key auth. Bench unit, WAN down.

> Unit-identifying values (MAC, serial, DRM device ID, EUI-64 link-local address) are deliberately omitted — this is a public repo and the EX50 is the border device. They live only in the local bench notes / operator's records.

---

## Device facts

| | |
|---|---|
| Model / SKU | Digi EX50 / `EX50-WXS6-GLB` (WiFi 6, global) |
| Firmware (active / alt) | **`25.11.10.42`** / `25.8.1.6` · bootloader `23.6.1.117` |
| WireGuard gate | **Met** — firmware ≥ 24.3.28.88 (Checkpoint E unblocked) |
| Ethernet | `lan` (up, 1000Mb/s on the bench switch — port is 2.5GbE capable), `wan` (down) |
| Default LAN | `192.168.2.1/24` + IPv6 ULA (factory default) |

---

## The interaction model (how it's scriptable)

The DAL **Admin CLI** is the same over SSH and serial. Three usable modes, all over `ssh admin@<ex50>`:

1. **Single command** — `ssh admin@<ex50> "show config"`. Best for read-only state capture.
2. **Piped multi-line stdin — scriptable, no PTY** — `printf 'config\nset ...\nsave\nexit\n' | ssh admin@<ex50>`. **This is the IaC apply mechanism.** DAL executes each line as a CLI command. Confirmed working.
3. **Interactive PTY** — `ssh -tt admin@<ex50>`. Only mode where `?` help and Tab-completion work (they return `# ERROR` in modes 1–2).

**Config safety model (verified):** config-mode edits are **staged**; they apply/persist **only on `save`**. Exiting config mode without `save` **discards** all staged changes — so schema exploration (`add`/`show` then `exit`) is non-destructive. This is what makes scripted probing safe.

**Command verbs:** `show` (read), `set <path> <value>`, `add <path> <name|end> [value]` (list/array nodes), `del <path>` (unset), `save`. Paths are space-delimited walks of the config tree, e.g. `network interface lan ipv4 address`.

### The config artifact for IaC

- **`show config`** prints only the **delta from factory defaults**, as replayable `add`/`set`/`del` commands (this unit's delta is ~20 lines). This is the minimal, version-controllable representation — the thing an Ansible role renders and pushes.
- **`config` → `show <path>`** prints the *full* subtree including every default — schema introspection, not for storage.
- Round-trip: capture `show config` → template it → apply via piped stdin (mode 2) → `save`. Full-image backup/restore exists separately (`system` domain) but the delta-replay path is the IaC one.
- **Secrets note:** `show config` embeds obfuscated secrets (e.g. WiFi PSK as `$ob1$…`, reversible). This repo is public — any committed config sample must be redacted; render real values through 1Password/ESO at apply time, never commit them.

---

## Capability map — 10 top-level domains

Everything below is scriptable via the CLI. **Bold** = load-bearing for the cutover.

| Domain | Children (this firmware) | Notes |
|---|---|---|
| **`network`** | `interface` (lan/wan/modem/hotspot/loopback/setupip/wan_bonding), `bridge`/`device`, **`vlan`** (supported, unset), `wifi` (radio + ap), `modem` (cellular/SIM), routes, per-interface **`dhcp_server`** + `dhcpv6_server`, `dns`, SureLink, `wan_bonding`, ULA/IPv6 | The bulk of the cutover. Interfaces bind to a **device** (`lan` → a bridge device) and a **zone** (`lan` → `internal`). VLANs are added under `network` (currently `no vlan`). |
| **`firewall`** | **`filter`** (zone-based rules), **`dnat`** (port forwarding, unset), `custom` (raw nftables), `qos`, `portal` (captive) | Zone model: `internal` / `external` / `hotspot` / `any`. Segmentation (ADR-046) = zone assignment + filter policy. |
| **`vpn`** | `ipsec`, `l2tp`, `openvpn`, **`wireguard`**, `iptunnel`, `l2tpeth`, `macsec`, `nemo` | WireGuard path is **`vpn wireguard client <name>`** (Checkpoint E). Currently `no wireguard`. |
| `service` | `ssh`, `web_admin`, `telnet` (off), `dns` (forwarder), `ntp`, `snmp`, `mdns`, `location` (GPS), `iperf`, `ping` | Management + network services. SSH ACL currently includes `wan` (see security notes). |
| `auth` | `user`, `group`, `method` (auth order), `ssh_key`, **`allow_shell`** (root DAL shell toggle), `idle_timeout`, `ldap`, `radius`, `tacacs+`, `serial` | `allow_shell` gates the underlying Linux shell (ADR-044's "root DAL shell reachable"). SSH keys added under `auth user <name> ssh_key`. |
| `system` | `time`, `log`, **`schedule`** (scheduled tasks / cron-like automation), `watchdog`, `power`, `fips`, `erase_button`, `primaryresponder` | `schedule` enables on-box automation. `log` is the journald surface. |
| `cloud` | Digi Remote Manager (`edp12.devicecloud.com`) | Currently Disconnected (no WAN). Secondary interface, not the IaC path. |
| `monitoring` | `events`, `intelliflow`, `netflow`, `perf_quality` | Telemetry / flow export (NetFlow, IntelliFlow) — candidate feeds for the observability stack. |
| `serial` | `port1` (console) | Mode `login` @ **9600** baud. See access runbook for the physical-cable issue. |

### Cutover-critical config paths (quick reference)

| Need (checkpoint) | DAL path |
|---|---|
| LAN address → `10.0.0.1/24` (C) | `network interface lan ipv4 address` |
| Home DHCP scope `10.20.0.0/24` (D) | `network interface <home> ipv4 dhcp_server …` |
| Home VLAN (D) | `network vlan <name> …` + interface `device` binding |
| Firewall zones / default-deny home→platform (D) | `firewall filter <n>` with `src_zone`/`dst_zone` |
| DNAT 30487/30356 → `10.0.0.226` (E) | `firewall dnat <n> …` |
| WireGuard ingress tunnel (E) | `vpn wireguard client <name> …` |

---

## Current bench state + hardening notes (pre-cutover)

Captured facts, not yet-final config — the box is mid bench setup:

- **`firewall filter 2` = "Allow all for testing"** (src `any` → dst `any`, accept). Permissive bench rule — **must be removed** before the box fronts anything.
- **`service ssh` ACL includes the `wan` interface** — SSH would be reachable from WAN. Restrict to LAN/mgmt zones before the WAN is live.
- **`telnet` present but disabled** (port filtered) — leave off.
- **WiFi AP1** is a mixed-PSK bench placeholder (SSID + PSK redacted).
- **Clock skewed** (`show system` ~1 day off) — no WAN → no NTP sync yet. Resolves once WAN/`service ntp` reaches the internet.
- **DRM enabled but Disconnected**. Decide whether DRM stays enabled post-cutover (operator: not the primary interface).
- **Cellular modem disabled** — SIM slot 1 is physically empty; firmware reported `SIM 1 (Not found)` / `failed`, and the lit **SIM1 LED only meant slot 1 was the *selected* slot, not that a card was present**. The modem shipped with **TELUS carrier firmware** (`03.14.10.00_TELUS`), suggesting an ex-carrier unit — relevant only if cellular is ever wanted (carrier-locked images can need reflashing). Disabled at both layers to stop the futile ~5s SIM-slot probing (and its LED), matching ADR-044's "cellular not enabled for now": `network interface modem enable false` + `network modem modem enable false`.

## How this was captured (reproducible)

```
# reach it: no IPv4 on 10.0.0.0/24 yet, so use IPv6 link-local on the LAN segment.
# find the address (Digi OUI 00:40:9d), then SSH to it:
ip -6 neigh | grep -i '00:40:9d'          # -> fe80::…%<iface>
ssh admin@fe80::…%<iface>

# state
show system ; show network ; show route ; show serial ; show eth ; show config

# schema introspection (safe — discarded on exit without save)
printf 'config\nshow firewall\nexit\n' | ssh admin@<ex50>
```
