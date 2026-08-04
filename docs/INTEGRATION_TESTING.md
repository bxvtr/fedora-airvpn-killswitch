# Integration testing

This project separates **static validation** from an **opt-in live Fedora VM
integration test**. The live test modifies networking and must never run by
accident.

For a first-time overview that also covers Ansible check mode, direct
installation, and installed-state verification (`airvpn-check`), see
[Choose how to validate, test, or install](../README.md#choose-how-to-validate-test-or-install)
in the README.

## What static tests already prove

`tools/validate-safe` and the unit suite prove, among other things:

- Bash syntax / ShellCheck / formatting drift checks (when tools are installed)
- YAML and Ansible linting (when installed)
- Ansible playbook `--syntax-check` only
- Parsing, locking, firewall ownership helpers, repository structure
- Cursor agent safety file presence and policy invariants
- No tracked AirVPN `.conf` files outside `tests/fixtures/`

They do **not** prove:

- Live NetworkManager zone assignment behavior
- firewalld policy enforcement under real traffic
- WireGuard handshake success
- DNS leak absence
- Server-switch leak resistance
- Install/uninstall lifecycle on a real Fedora host

## Ansible become password prompting

Live install, check-mode, idempotency, and uninstall playbooks use Ansible
`become` (sudo). The integration runner adds `--ask-become-pass` so **Ansible**
prompts on the interactive TTY. The runner does **not** read, store, export, or
write the password to artifacts.

Expect:

- An interactive terminal (do not pipe stdin away from the TTY)
- One Ansible become prompt **per** Ansible process (check mode, install,
  idempotency, and uninstall may each ask again)
- No password on the command line, in environment variables, or in files

`--non-interactive` is incompatible with these lifecycle phases. A prior
interactive `sudo` prompt from the runner does **not** replace Ansible's become
prompt.

## Firewalld zone lifecycle notes

Project zones (`airvpn`, `vpn-underlay`) are created and deleted with
`ansible.posix.firewalld` using **permanent-only** semantics. Zone transactions
must not set `immediate: true` (firewalld / ansible.posix limitation). A
`firewall-cmd --reload` after permanent zone and policy changes activates the
runtime configuration. Check mode remains advisory: it does not prove live
firewalld enforcement. After a failed partial install in the VM, prefer
restoring the snapshot.

## Firewalld policy name limits

Supported Fedora/firewalld builds limit policy object names to **18 characters**
(`firewall.max_policy_name_len()`, derived from iptables chain length). Default
project policies are:

- `airvpn-host-vpn` (HOST → `airvpn`, target `ACCEPT`)
- `airvpn-host-under` (HOST → `vpn-underlay`, target `REJECT`)

Custom overrides via `config.yml` must use the same charset as firewalld
(`[A-Za-z0-9_-]`, no `/`), stay within the length limit, remain distinct from
each other and from zone names, and must be updated consistently (defaults,
runtime conf, and uninstall). Invalid overrides fail in early validation before
any firewalld mutation. Do not rename only one reference by hand.

Install migrates away from known former project defaults by deleting the exact
historical names `airvpn-host-to-vpn` and (defensively) `airvpn-host-to-underlay`
only after the current policies are fully configured, then validates and reloads
once. Those historical names are fixed task literals, not operator-configurable
variables. Uninstall deletes the exact union of the current configured names and
those same two historical literals. The overlong former underlay name exceeds the
current 18-character limit and may never have been creatable on such hosts;
cleanup still attempts the exact historical name and treats absence as success.

## WireGuard import filenames

AirVPN `.conf` downloads often use long human-readable basenames that exceed the
Linux interface-name limit (`IFNAMSIZ - 1` = 15). NetworkManager WireGuard
import requires the file basename to be a valid interface name followed by
`.conf`.

`airvpn-import` keeps the original basename on the root-owned managed copy for
endpoint discovery, and imports through a private temporary file named
`<deterministic-ifname>.conf` (mode `0600` under a `0700` directory). Temporary
key material is removed on success and failure. Source files are never renamed.

Installation imports managed profiles but leaves them **inactive** with
`autoconnect` disabled. NetworkManager may activate a profile during WireGuard
import; `airvpn-import` disconnects each newly imported profile and verifies
inactivity before continuing. Explicit activation remains `airvpn-switch`.
Offline verification fails if more than one managed VPN is active; a clean
install should report zero active managed VPNs.

## Online routing verification

NetworkManager WireGuard full-tunnel profiles typically enable
`wireguard.ip4-auto-default-route` (Improved Rule-based Routing): the default
route lives in a dedicated table with policy rules, while the main table may
still show the physical underlay default. Therefore `airvpn-check --online`
validates **effective** routing with `ip route get` to a documentation-range
destination (`192.0.2.1` / `2001:db8::1`) and requires the selected device to be
the active managed WireGuard interface. A handshake alone is not sufficient.

The VM integration runner records `ip rule`, `ip route show table all`, and
`ip route get` under `first-vpn-routing.txt` after activation. External public-IP
comparison against the baseline remains an integration-test responsibility: the
runner uses bounded multi-provider IPv4 probes with preserved curl status,
strict IPv4 validation, and layered DNS / generic HTTPS classification so a
transient provider outage is not mislabeled as a routing leak. An inconclusive
lookup still fails the phase (egress not proven).

## Purpose of the live VM test

`tools/integration-test-vm` orchestrates the project's existing playbooks and
runtime commands inside a **disposable Fedora virtual machine** to exercise:

1. Preflight (consent, VM detection, snapshot confirmation, config safety)
2. Static validation (`tools/validate-safe`)
3. Ansible syntax and optional check mode (advisory)
4. Baseline network / public IP collection
5. Installation
6. Offline fail-closed probes
7. First VPN activation
8. Redacted diagnostics
9. Server-switch leak probes (when ≥2 profiles)
10. Forced disconnect
11. Optional suspend/resume (off by default)
12. Idempotent re-install
13. Uninstall and connectivity restoration
14. Final PASS/FAIL/SKIP/WARN summary

## User journeys

### Static project validation (safe default)

```bash
tools/validate-safe
```

Non-destructive. Suitable for local development and Cursor agents.

### Optional VM integration test (modifies networking)

```bash
tools/integration-test-vm \
  --config-source /absolute/path/to/airvpn-configs \
  --i-understand-this-modifies-networking
```

Recommended before installing on a primary workstation. **Not mandatory.**
`bootstrap.sh` does **not** invoke this runner automatically.

By default the runner ends with uninstall and connectivity restoration: a
**successful lifecycle test** leaves the project **uninstalled**.

Pass `--skip-uninstall` only when you intentionally want the installation to
**remain present** after the run (for manual follow-up). That is a different
outcome from a full lifecycle PASS. A failed run—with or without
`--skip-uninstall`—can leave an installed, active, or uncertain networking
state; prefer restoring the VM snapshot rather than flushing firewalls.

Other useful flags (see `tools/integration-test-vm --help` for the full list):

| Flag | Effect |
| --- | --- |
| `--snapshot-confirmed` | Required with `--non-interactive`; asserts you created a snapshot |
| `--skip-switch-test` | Skip server-switch leak probes (also needed with a single config) |
| `--skip-forced-disconnect` | Skip the forced-disconnect phase |
| `--skip-check-mode` | Skip advisory Ansible check mode |
| `--enable-suspend` | Interactive suspend/resume (off by default) |
| `--allow-non-vm` | Dangerous bare-metal override (discouraged) |

### Direct installation on a supported Fedora host

Run as your normal user (not `sudo ./bootstrap.sh`). Bootstrap installs
controller tooling repository-locally, then Ansible prompts for the
become/sudo password via `--ask-become-pass`:

```bash
./bootstrap.sh --config-source /absolute/path/to/airvpn-configs
```

`--skip-playbook` prepares only the repository-local controller environment
and does not run the install playbook or request a become password.

## Requirements

- Disposable Fedora VM (Workstation, Spin, or Atomic) with NetworkManager + firewalld
- Snapshot created **before** state-changing phases (GNOME Boxes snapshots cannot
  be verified by the script — you must confirm)
- AirVPN WireGuard `.conf` files with **numeric** endpoints, stored **outside**
  the Git repository
- At least two configs when the switch test is enabled
- Normal (non-root) user; `sudo` for privileged steps only (no `sudo -S`)
- Controller tooling available (`./bootstrap.sh ... --skip-playbook` if needed)

Ordinary containers are **not** treated as equivalent to a VM for firewall
testing and are refused by default.

## Why configs stay outside the repository

AirVPN configs contain WireGuard `PrivateKey` material. Tracked secrets are a
critical failure. Use `--config-source` pointing outside the clone. Fake unit
fixtures under `tests/fixtures/` are documentation-range only.

## Safeguards

| Control | Behavior |
| --- | --- |
| Explicit consent | Requires `--i-understand-this-modifies-networking` |
| VM detection | `systemd-detect-virt`; refuses non-VM by default |
| Non-VM override | `--allow-non-vm` plus interactive confirmation (or `--allow-non-vm-confirmed` with `--non-interactive`); strongly discouraged |
| Snapshot | Interactive `SNAPSHOT_CREATED` or `--snapshot-confirmed` |
| Root | Entire runner refuses root |
| Fail-closed recovery | Does **not** flush nftables/iptables or run panic-off / complete-reload |
| Secrets | Artifact redaction for PrivateKey / tokens; never print full private configs |
| Automation | Not invoked by `validate-safe`, pre-commit, or GitHub-hosted CI |

If a later phase fails after install, assume the kill switch **may still be
active** and treat host networking state as **uncertain**. Prefer restoring the
VM snapshot when state is uncertain. Do not flush nftables/iptables or run
`firewall-cmd --panic-off` / `--complete-reload` as recovery.

When `--skip-uninstall` was used, even a PASS leaves the project installed.
Uninstall manually only when you understand that removing the kill switch can
restore direct Internet access.

## Interpreting results

| Status | Meaning |
| --- | --- |
| PASS | Required assertions for the phase succeeded |
| FAIL | Required phase failed; runner exits non-zero |
| SKIP | Optional phase omitted (flags / prerequisites) |
| WARN | Advisory issue; does not alone fail the run unless paired with FAIL |

Artifacts default to `/tmp/fedora-airvpn-live-test-YYYYMMDD-HHMMSS/` (or
`--output-dir`). Reports may still contain network metadata (endpoint / public
IPs). Treat artifact directories as sensitive.

## Manual uninstall state snapshots

`tools/uninstall-audit-snapshot` is a **manual**, **read-only** collector for
disposable Fedora VMs. It records host state into durable phase directories so
you can compare baseline, installed, uninstalled, and after-reboot captures.

It does **not**:

- run `playbooks/install.yml` or `playbooks/uninstall.yml`
- run `bootstrap.sh` or `tools/integration-test-vm`
- mutate NetworkManager, firewalld, WireGuard, services, or packages
- overwrite an existing phase directory (there is no `--force`)

Run it yourself as root. Default output root is
`/var/tmp/fedora-airvpn-uninstall-audit` so the same `--run-name` survives a
reboot (`/tmp` is often wiped). Artifacts may contain network metadata (zones,
routes, optional public IPs). Treat them as sensitive.

Example:

```bash
sudo tools/uninstall-audit-snapshot \
  --run-name silverblue43-v010 \
  --phase baseline \
  --include-connectivity

# Install and exercise the project manually.

sudo tools/uninstall-audit-snapshot \
  --run-name silverblue43-v010 \
  --phase installed \
  --include-connectivity

# Run the documented uninstall manually.

sudo tools/uninstall-audit-snapshot \
  --run-name silverblue43-v010 \
  --phase uninstalled \
  --include-connectivity

# Reboot the disposable VM, then:

sudo tools/uninstall-audit-snapshot \
  --run-name silverblue43-v010 \
  --phase after-reboot \
  --include-connectivity

sudo tools/uninstall-audit-snapshot \
  --run-name silverblue43-v010 \
  --compare
```

`--compare` only reads existing snapshots and writes under
`comparisons/<timestamp>.<pid>/`. Missing phases are reported as `SKIP`.
“No difference detected in captured structural state” is **not** a proof that
the system was fully restored.

Connectivity probes require explicit `--include-connectivity`.

## Distinguishing entry points

Short reference (full decision table:
[README](../README.md#choose-how-to-validate-test-or-install)):

| Command | What it does |
| --- | --- |
| `tools/validate-safe` | Static validation (non-destructive; no live networking proof) |
| `./bootstrap.sh … --check` | Ansible check mode (best-effort; not a live integration test) |
| `tools/integration-test-vm` | Live VM integration test (real install; not a dry run) |
| `tools/uninstall-audit-snapshot` | Manual read-only host state snapshots for uninstall audits |
| `./bootstrap.sh …` | Direct installation on the target host |
| `airvpn-check --offline` / `--online` | Installed-state verification |

## CI limitation

GitHub Actions run static/mocked checks only. They must **not** execute the live
install playbook, mutate NetworkManager/firewalld, establish WireGuard, or read
real AirVPN files. Unit tests cover argument parsing, refusal logic, redaction,
and report helpers with mocks.

## Known limitations

- No guarantee of complete leak prevention against all adversaries or kernel bugs
- Check mode is advisory and does not prove live correctness
- Public IP lookups use short-timeout HTTPS endpoints with fallbacks; the suite
  does not depend on a single external service, but offline environments limit
  some assertions
- Suspend/resume requires human interaction and is disabled by default
- Idempotency may still report some Ansible `changed` tasks; play failures fail
  the phase

## Maintainer journey

1. Develop and run `tools/validate-safe` on the workstation.
2. Push the feature branch; confirm CI static jobs (no live test).
3. Inside a snapshotted Fedora Boxes VM: clone the same revision, place AirVPN
   configs outside the tree, prepare the venv if needed, then run
   `tools/integration-test-vm` with consent.
4. Inspect `/tmp/fedora-airvpn-live-test-*/summary.txt`.
5. Restore the snapshot when finished or when state is uncertain.
