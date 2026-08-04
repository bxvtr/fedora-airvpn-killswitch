# Fedora AirVPN Kill Switch v0.1.0

## Overview

`v0.1.0` is the first public release of **fedora-airvpn-killswitch**:
direct-on-host Ansible and Bash tooling that configures **AirVPN WireGuard**
with **NetworkManager** and a **fail-closed firewalld** kill switch on
**Fedora 43**.

This is an unofficial project. It does not download AirVPN configurations and
does not authenticate against AirVPN. Behavior is leak-**resistant**, not a
guaranteed leak-proof product.

## Highlights

- Import managed AirVPN WireGuard profiles into NetworkManager.
- Leave newly imported managed profiles inactive until explicit activation.
- Activate and switch managed profiles; expect exactly one active managed VPN.
- Block ordinary IPv4, IPv6, and DNS egress without an active managed VPN.
- Allow only required AirVPN endpoint traffic (and minimal DHCP/NDP) on the
  underlay.
- Route IPv4, IPv6, and DNS through the active VPN on the validated path.
- Provide status, check, import, switch, firewall-sync, kill-switch, and
  protect-connection commands.
- Manually protect additional physical connections with
  `airvpn-protect-connection`.
- Confirmed and repeatable uninstall (explicit confirmation required).
- Manual uninstall audit snapshot tooling for disposable VM reviews.

## Validated Environment

Live integration evidence for this release:

```text
Fedora Silverblue 43
KVM / Fedora Boxes
virtual Ethernet interface
```

Physical Wi-Fi hardware and Wi-Fi lifecycle scenarios were **not** live
validated. Other Fedora editions and topologies are target-family candidates,
not blanket-validated environments.

## Installation

Follow the documented direct-on-host path in [README.md](../README.md):

1. Place AirVPN WireGuard `.conf` files outside the repository.
2. Copy `example.config.yml` to `config.yml` and set `airvpn_config_source`.
3. Run `./bootstrap.sh` as your normal user (Ansible become password prompted).

Do not invent alternate install syntax. Prefer a disposable VM with a snapshot
for first live runs. See [docs/INTEGRATION_TESTING.md](INTEGRATION_TESTING.md).

## Main Commands

| Command | Purpose |
| --- | --- |
| `airvpn-import` | Import/harden managed profiles and sync endpoint exceptions. |
| `airvpn-switch` | Activate, switch, or disconnect managed tunnels. |
| `airvpn-firewall-sync` | Synchronize firewalld endpoint exceptions. |
| `airvpn-status` | Read-oriented status report (never prints private keys). |
| `airvpn-check` | Offline/online verification with non-zero exit on failure. |
| `airvpn-killswitch` | Manage only project kill-switch policies. |
| `airvpn-protect-connection` | Assign a physical profile to the underlay zone. |

Commands that modify NetworkManager, firewalld, VPN state, or managed files
require root. Read-only status and diagnostic operations may support non-root
execution depending on the requested checks.

## Uninstall

Uninstall requires explicit confirmation
(`-e airvpn_uninstall_confirmed=true`). See [README.md](../README.md).

On the validated Silverblue 43 path:

- First uninstall removed project policies, zones, managed VPN profiles,
  runtime files, and project state (managed config copies retained by default).
- Second uninstall after the fix completed successfully.
- Ordinary connectivity was available again after uninstall (and after reboot
  in the snapshot comparison).

Important restore semantics:

- Physical connections are set to `airvpn_restore_zone` (default `public`).
- Exact pre-install `connection.zone` values are **not** restored.
- Managed AirVPN configuration copies under `/etc/airvpn-client/configs`
  remain by default unless
  `-e airvpn_uninstall_delete_configs=true` is passed.

## Security Model

- Fail-closed underlay without an active managed VPN.
- Endpoint-specific underlay UDP exceptions for imported numeric AirVPN
  endpoints.
- Restrictive permissions on managed configuration material.
- Status and diagnostics avoid intentionally logging private keys.
- Runtime expectation of exactly one active managed VPN when online checks
  require a tunnel.

This release does **not** claim absolute or universal leak-proof behavior.
Operators must verify on their own hosts.

## Known Limitations

Most important for operators:

- Physical Wi-Fi not live validated.
- New physical profiles after install may require `airvpn-protect-connection`.
- Suspend/resume and dual-uplink scenarios not live validated.
- Uninstall does not acquire the shared runtime project lock.
- Pre-existing same-named firewalld objects are not fully ownership-tracked.
- Exact pre-install zone restoration is not implemented.
- Managed WireGuard config copies are retained by default.

Full detail: [docs/KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

## Validation Evidence

- Required CI checks (lint, syntax, unit tests, secret scan) green on the
  release branch tip used for this documentation pass.
- Live Silverblue 43 lifecycle: install, multi-config import (inactive),
  fail-closed without VPN, VPN activation, handshake, IPv4/IPv6 policy routing,
  DNS via VPN.
- First and second uninstall live validated after the repeatable-uninstall fix.
- Uninstall audit snapshot comparison
  (`baseline` → `installed` → `uninstalled` → `after-reboot`).
- Audit collector interruption/hardening: incomplete captures are not published
  as final phases; successful phases publish atomically.

No private host paths, UUIDs, IP addresses, or secrets are included here.

## Upgrade Notes

This is the initial release. No upgrade path from an earlier release is
required.

Future versions may change behavior; do not assume forward compatibility
promises beyond what each release documents.

## Links

- [README.md](../README.md)
- [CHANGELOG.md](../CHANGELOG.md)
- [docs/KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
- [ROADMAP.md](../ROADMAP.md)
- [docs/INTEGRATION_TESTING.md](INTEGRATION_TESTING.md)
- [SECURITY.md](../SECURITY.md)
