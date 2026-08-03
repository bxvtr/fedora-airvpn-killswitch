# Integration testing

This project separates **static validation** from an **opt-in live Fedora VM
integration test**. The live test modifies networking and must never run by
accident.

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

### Direct installation on a supported Fedora host

```bash
./bootstrap.sh --config-source /absolute/path/to/airvpn-configs
```

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
active**. Prefer restoring the VM snapshot when state is uncertain.

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

## Distinguishing entry points

| Command | What it does |
| --- | --- |
| `tools/validate-safe` | Static, non-destructive validation |
| `airvpn-check --offline` | Installed host posture without requiring an active VPN |
| `airvpn-check --online` | Installed host posture including live tunnel checks |
| `tools/integration-test-vm` | Full opt-in lifecycle in a disposable VM |

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
