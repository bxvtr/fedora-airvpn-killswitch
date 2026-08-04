# Known Limitations

This document records what the current branch is intended to do, what has been
**live validated**, what is only **statically identified**, and what remains
**not yet validated**. It does not claim a complete security proof.

Related reading:

- [README.md](../README.md) — install, usage, and validation paths
- [INTEGRATION_TESTING.md](INTEGRATION_TESTING.md) — live VM workflow and snapshot collector
- [ROADMAP.md](../ROADMAP.md) — planned hardening and lifecycle work
- [SECURITY.md](../SECURITY.md) — unsupported claims and reporting

## Scope of This Document

Status labels used here:

| Label | Meaning |
| --- | --- |
| Live validated | Observed in a controlled disposable Fedora VM with install/uninstall (and reboot where noted) |
| Statically identified | Confirmed from repository code review; not necessarily reproduced live |
| Not yet validated | Implemented or intended, but not covered by the current live evidence |
| Intentional behavior | Deliberate design choice, not a defect |
| Planned | Tracked for a later release; see [ROADMAP.md](../ROADMAP.md) |

Do **not** treat successful CI, static validation, Ansible check mode, or a
single live VM run as proof that every Fedora host, Wi-Fi scenario, or
adversary model is covered.

## Validation Status

### Live Validated

Live integration testing was completed on **Fedora Silverblue 43** (Fedora 43
Atomic Desktop) using **KVM / Fedora Boxes** and a **virtual Ethernet**
interface. That environment is **not** a blanket validation of every Fedora 43
variant or of physical Wi-Fi hardware.

In that controlled run, the following were observed:

- Installation completed successfully.
- Two AirVPN WireGuard configurations were imported as managed VPN profiles.
- Newly imported managed VPN profiles remained inactive after installation.
- With no active managed VPN, ordinary IPv4, IPv6, and DNS traffic was blocked
  (fail-closed underlay posture).
- A managed VPN could be activated; exactly one managed VPN was active.
- A current WireGuard handshake was present.
- Effective IPv4 and IPv6 policy routing selected the managed WireGuard
  interface.
- DNS was routed via the VPN profile.
- Public IPv4 egress through AirVPN worked.
- After documented uninstall and reboot snapshot comparison
  (`baseline` → `installed` → `uninstalled` → `after-reboot`):
  - Project firewalld policies and project zones were removed.
  - Managed VPN profiles and WireGuard runtime state for those profiles were
    gone.
  - Project runtime scripts and wrapper symlinks were removed.
  - Project state under `/var/lib/airvpn-client` was removed.
  - No project routing rules remained after reboot.
  - DNS and service state matched the baseline after reboot.
  - Package and rpm-ostree state matched the baseline.
  - Ordinary Internet access and DNS worked again.
  - `/run/airvpn-client.lock` was gone after reboot.
- Repeated uninstall (`install → first uninstall → second uninstall`) completed
  successfully on the same Silverblue 43 host after the repository-sourced
  common-library fix.

No project firewalld policies, project zones, managed VPN profiles, WireGuard
runtime state, or project routing rules remained after the validated uninstall
and reboot test. That does **not** prove a full system rollback of every
possible host property.

### Statically Reviewed

Static review (including an uninstall code audit) identified additional gaps
that were **not** all reproduced live. See [Uninstall Behavior](#uninstall-behavior)
and [Network Connection Coverage](#network-connection-coverage).

CI and `tools/validate-safe` cover syntax, lint, mocked unit tests, and
structural guards only. They do **not** exercise live NetworkManager,
firewalld, WireGuard, DNS, or routing.

### Not Yet Validated

Examples (non-exhaustive):

- Physical Wi-Fi hardware and Wi-Fi lifecycle scenarios
- Physical Ethernet hardware (live run used virtual Ethernet)
- Connections created after installation (automatic underlay assignment)
- Concurrent uninstall while mutating runtime commands hold the project lock
- Pre-existing firewalld zones/policies that already use project object names
- Suspend/resume, roaming, airplane mode, dual uplinks, tethering, captive portals
- General recovery after arbitrary partial uninstall failures (beyond the
  repository-sourced runtime-library path fixed for repeatable uninstall)
- Package-based Fedora Workstation or Spin hosts as live integration targets
- Broader Fedora editions beyond the Silverblue 43 VM above

## Network Connection Coverage

### Existing Physical Connections

**Status:** Live validated for the tested virtual Ethernet profile during
install / VPN / uninstall on Silverblue 43.

Install assigns selected Ethernet and Wi-Fi NetworkManager profiles to the
underlay zone and reapplies the runtime zone on active devices. Exact
pre-install zone values are **not** stored for later restoration.

### Connections Added After Installation

**Status:** Not yet validated (implementation gap / incomplete guarantee).

**Impact:** Moderate in daily use if new SSIDs or adapters appear.

A physical NetworkManager connection profile created **after** installation may
**not** automatically be assigned to `vpn-underlay`. The project does not ship an
automatic NetworkManager dispatcher for new profiles.

**Current behavior:** Profiles present at install time can be protected by the
install role. Later profiles need explicit attention.

**Workaround:**

```bash
sudo airvpn-protect-connection "Connection Name Or UUID"
sudo airvpn-check --offline
```

Inspect `connection.zone` on new Ethernet/Wi-Fi profiles and confirm underlay
assignment before relying on fail-closed behavior.

**Planned:** Lifecycle detection/protection — see [ROADMAP.md](../ROADMAP.md)
(`v0.2.0`).

### Wi-Fi Validation Status

**Status:** Implementation covers `802-11-wireless` profile types; physical
Wi-Fi hardware and Wi-Fi lifecycle scenarios are **not yet validated**.

**Impact:** Unknown for real radios until live tested.

NetworkManager Wi-Fi connection profiles are supported by the implementation,
but physical Wi-Fi hardware and Wi-Fi lifecycle scenarios have not yet been
live validated. New SSID profiles are a common way the
post-install protection gap appears.

**Workaround:** Use `airvpn-protect-connection` and `airvpn-check` after adding
or changing Wi-Fi profiles.

### Suspend, Resume, and Roaming

**Status:** Not yet validated (suspend/resume is optional and off by default in
the live runner).

**Impact:** Unknown.

Intended fail-closed behavior after resume is described in the README threat
model, but it has not been proven in the current live evidence set.

### Multiple Physical Uplinks

**Status:** Not yet validated.

**Impact:** Unknown for simultaneous Ethernet + Wi-Fi, USB tethering, and
similar topologies.

## Uninstall Behavior

### Validated Cleanup

**Status:** Live validated on the Silverblue 43 VM with snapshot phases
including after-reboot.

Project policies, zones, managed VPN profiles, runtime scripts/wrappers,
`/var/lib/airvpn-client` state, and project routing rules were gone after
uninstall and reboot in that test. Ordinary connectivity returned.

This is **not** a claim of “clean uninstall” for every host property or every
failure path.

### Restore Zone Behavior

**Status:** Live confirmed difference from pre-install connection metadata;
matches intentional configured restore behavior.

**Impact:** Low to moderate (connection zone metadata changes; default-zone
semantics may still apply depending on prior emptiness).

The uninstall restores protected physical connections to the configured restore
zone (`airvpn_restore_zone`, default `public`). It does **not** currently
restore each connection’s exact pre-installation zone assignment.

In the validated VM:

- Before install, the tested Ethernet connection had **no** explicit
  `connection.zone` and was handled via the firewalld default zone
  `FedoraWorkstation`.
- After uninstall, that connection was explicitly set to `public`.
- The global firewalld default zone was not rewritten as part of that
  difference; the NetworkManager profile was.

Document this as restore-zone behavior, not as unexplained firewall damage.

**Workaround:** After uninstall, review `connection.zone` on physical profiles
and set the desired zone if `public` is not appropriate.

**Planned:** Exact per-connection restore — see [ROADMAP.md](../ROADMAP.md)
(`v0.2.0`).

### Retained Managed Configurations

**Status:** Intentional behavior (default).

**Impact:** Security-relevant if private keys remain on disk after uninstall.

Default:

```text
airvpn_uninstall_delete_configs: false
```

Managed copies under `/etc/airvpn-client/configs` are therefore **kept** unless
you pass `-e airvpn_uninstall_delete_configs=true`. Those files can contain
WireGuard private keys. Directory/file modes are intended to be restrictive
(root-owned managed tree), but a default uninstall is **not** a complete
removal of all private configuration material.

**Workaround:** Delete with the uninstall extra-var, or remove the managed
config directory manually after review.

### Repeated Uninstall

**Status:** Live validated on Fedora Silverblue 43
(`install → first uninstall → second uninstall`).

**Impact (historical):** A second uninstall could fail early because NetworkManager
cleanup tasks sourced installed
`/usr/local/libexec/airvpn-client/lib/airvpn-common.sh`, which the first
successful uninstall removes.

**Current behavior:** Those tasks source
`roles/airvpn_client/files/lib/airvpn-common.sh` from the repository checkout
used to run the playbook, so a second uninstall no longer depends on installed
runtime libraries. Already-absent project policies/files remain non-fatal;
managed configs stay retained unless `airvpn_uninstall_delete_configs=true`.

**Remaining:** General recovery after arbitrary partial uninstall failures is
**not** fully live validated. Uninstall still does not acquire the shared
runtime project lock (see [Concurrent Runtime Operations](#concurrent-runtime-operations)).
Further hardening items remain in [ROADMAP.md](../ROADMAP.md) (`v0.1.x`).

### Concurrent Runtime Operations

**Status:** Statically identified; not yet live reproduced.

**Impact:** Depends on environment (race between uninstall and mutating
`airvpn-*` commands).

Mutating runtime commands use a shared project lock. The uninstall playbook
does not take that same lock.

**Workaround:** Do not run `airvpn-import`, `airvpn-switch`,
`airvpn-firewall-sync`, or similar during uninstall.

**Planned:** Stronger uninstall serialization — see [ROADMAP.md](../ROADMAP.md)
(`v0.1.x`).

### Pre-existing firewalld Objects

**Status:** Statically identified; not yet live tested.

**Impact:** Depends on environment (same-named zones/policies could be
reconfigured or removed without full ownership tracking).

Install ensures project zone/policy names exist and configures them. Uninstall
deletes those exact names. There is no separate ownership record distinguishing
“created by this project” from “already present with the same name.”

**Workaround:** Avoid colliding custom firewalld names with project defaults
(or configured overrides) before install. Inspect permanent zones/policies if
you share the host with other firewall automation.

**Planned:** Stronger conflict checks / ownership — see [ROADMAP.md](../ROADMAP.md).

## Security Impact and Workarounds

| Topic | Status | Practical note |
| --- | --- | --- |
| Fail-closed without VPN (validated path) | Live validated (Silverblue 43 / vEth) | Still verify with `airvpn-check` on your host |
| Repeated uninstall | Live validated (Silverblue 43) | Still does not take the runtime project lock |
| New physical profiles | Not yet validated | Use `airvpn-protect-connection` |
| Wi-Fi hardware / lifecycle | Not yet validated | Do not assume radio scenarios match the VM Ethernet run |
| Suspend/resume / dual uplink | Not yet live validated | Do not treat intended design as confirmed |
| Restore zone ≠ original zone | Live confirmed + intentional | Review zones after uninstall |
| Retained managed configs | Intentional default | Treat `/etc/airvpn-client/configs` as secrets |
| Audit snapshot incomplete publish | Fixed (atomic success gate) | Leftover `.<phase>.partial.<pid>` dirs need manual cleanup |
| `/run/airvpn-client.lock` until reboot | Intentional / cosmetic | Cleared by reboot; not a persistent project install |
| Controller `.venv` / `.ansible` | Intentional | Repository-local; not removed by host uninstall |
| Packages / enabled NM+firewalld | Intentional | System prerequisites; not rolled back |

## Reporting Unexpected Behavior

See [SECURITY.md](../SECURITY.md). Prefer redacted `airvpn-check` /
`airvpn-status` output. Never attach AirVPN `.conf` files or private keys.
