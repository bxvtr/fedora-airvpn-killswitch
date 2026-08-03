# fedora-airvpn-killswitch

Reproducible Ansible + Bash tooling to configure **AirVPN WireGuard** connections with **NetworkManager** and a **leak-resistant firewalld kill switch** on **Fedora**.

> **Unofficial project.** This software is **not affiliated with, endorsed by, or related to AirVPN** or AirVPN Ltd. You must create and pay for your own AirVPN account and export WireGuard configuration files yourself. This project never downloads AirVPN configurations and never authenticates against AirVPN.

## Disclaimer

THE SOFTWARE IS PROVIDED **WITHOUT WARRANTY**. Users must verify behavior on their own systems. This project aims for a fail-closed, leak-**resistant** posture. It does **not** claim to be “guaranteed leak-proof.” Passing a public DNS-leak website alone is **not** adequate verification.

## Threat model and limitations

**Intended behavior**

- Without an active managed AirVPN tunnel, ordinary Internet traffic via managed physical interfaces is blocked.
- During VPN server switches, ordinary Internet traffic remains blocked.
- If WireGuard activation or handshake verification fails, the system fails closed.
- After boot, before manual VPN activation, ordinary Internet traffic is blocked (managed profiles have `autoconnect` disabled).
- Installation imports managed AirVPN profiles but leaves them inactive; activate one explicitly with `airvpn-switch`.
- After suspend/resume, traffic either continues through an still-active VPN or remains blocked.
- Physical Wi-Fi/Ethernet may send only required WireGuard handshake traffic to explicitly allowed numeric AirVPN endpoints (plus minimal DHCP/NDP allowances).
- Traffic via the managed AirVPN interface is allowed.
- IPv4 and IPv6 are both considered when enabled.
- DNS must not escape through the underlay; VPN DNS priority and routing domain `~.` are applied.
- The project never silently disables the kill switch to restore connectivity.

**Limitations**

- Version 1 supports **direct-on-host** Ansible only (controller == managed host).
- Hostname-based WireGuard `Endpoint` values are **rejected** (they need pre-tunnel DNS).
- All imported numeric endpoints are allowed persistently (not “current endpoint only”).
- Local LAN access via the underlay is blocked by the default kill switch (fail closed).
- Newly created Wi-Fi/Ethernet profiles are **not** auto-protected; use `airvpn-protect-connection`.
- CI does **not** exercise real NetworkManager/firewalld/WireGuard integration.

## Supported systems

**Officially supported in version 1**

- Fedora Workstation
- Fedora Spins using NetworkManager and firewalld
- Fedora Atomic Desktops using NetworkManager and firewalld

Other distributions are **not** supported. See [ROADMAP.md](ROADMAP.md).

## Fedora Atomic notes

Atomic hosts are detected via `/run/ostree-booted` (plus Ansible facts).

- The role **does not** use DNF to modify the host image.
- Missing layered packages cause a **clear failure** with `rpm-ostree install …` instructions by default.
- Optional automatic layering is available only when `airvpn_atomic_layer_missing_packages: true`. Even then, the role **does not reboot**; you must reboot and re-run bootstrap.
- Persistent project files live under `/etc`, `/var`, and `/usr/local`.

## Dependency layers

### 1. Controller bootstrap (`bootstrap.sh`)

Creates a repository-local Python virtualenv, installs **pinned** `ansible-core` and tooling from `requirements-controller.txt`, installs **pinned** collections from `requirements.yml`, then runs `playbooks/install.yml`.

Ansible cannot install itself through a playbook that cannot yet run.

### 2. Ansible runtime and collections

Exact pins (verified 2026-08-02):

| Component | Version |
| --- | --- |
| ansible-core | 2.21.2 |
| ansible-lint | 26.6.0 |
| yamllint | 1.38.0 |
| pre-commit | 4.6.1 |
| pytest | 9.1.1 |
| ansible.posix | 2.2.2 |
| community.general | 13.2.0 |

Update process: [CONTRIBUTING.md](CONTRIBUTING.md).

### 3. Managed host state

Required components include NetworkManager/`nmcli`, firewalld/`firewall-cmd`, WireGuard kernel support, `wireguard-tools`/`wg`, Python 3, `python3-firewall` (for Ansible firewalld modules), and systemd.

## Security warning: AirVPN configs are secrets

AirVPN WireGuard `.conf` files contain **private keys**.

- Never commit them.
- Never store them inside this Git repository.
- Keep source directories mode `0700` and files mode `0600` when practical.
- This project copies configs only to a root-owned directory (`/etc/airvpn-client/configs` by default).

## Cursor agent safety (local development)

This repository includes defense-in-depth Cursor guardrails for local agents.
They guide static code work and reduce accidental live host changes. They are
**not** a complete security boundary and do **not** replace OS permissions,
manual approval of commands, avoiding passwordless sudo, or a disposable VM
for live NetworkManager/firewalld tests.

| File | Role |
| --- | --- |
| `.cursor/permissions.json` | Cursor **IDE** allowlist / Auto-review guidance (when a supported Run Mode is enabled) |
| `.cursor/cli.json` | Cursor **CLI** allow/deny permissions |
| `.cursor/rules/*.mdc` | Local Agent project rules (instructions, not a sandbox) |
| `.cursor/BUGBOT.md` | Bugbot review instructions only |

Preferred static validation:

```bash
tools/check-agent-safety
tools/validate-safe
```

Optional live Fedora VM integration test (modifies networking; never automatic):

```bash
tools/integration-test-vm \
  --config-source /secure/airvpn-configs \
  --i-understand-this-modifies-networking
```

See [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md) and
[CONTRIBUTING.md](CONTRIBUTING.md). The repository cannot change your global
Cursor settings for you. Cursor agents must not run `tools/integration-test-vm`
without explicit human authorization inside a disposable VM.

## Quick start

1. Export WireGuard configs from AirVPN (prefer **numeric IP** endpoints).
2. Store them **outside** this repository, e.g. `/secure/airvpn-configs`.
3. Clone this repository on the Fedora host.
4. (Recommended) On a disposable Fedora VM with a snapshot, run
   `tools/integration-test-vm` as documented in
   [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md).
5. On the target host, install:

```bash
./bootstrap.sh --config-source /secure/airvpn-configs
sudo airvpn-check --offline
sudo airvpn-switch
sudo airvpn-check --online
```

After a successful install, managed AirVPN profiles are present but **inactive**
(zero active managed tunnels). The kill switch remains enabled, so ordinary
Internet traffic stays blocked until you activate a profile with `airvpn-switch`.

`bootstrap.sh` does **not** invoke the live integration test automatically.

Optional local overrides: copy `example.config.yml` to `config.yml` (gitignored).

## Detailed installation

### Package-based Fedora

`bootstrap.sh` prepares the controller venv/collections, then the install playbook installs missing host packages with the Ansible package module and configures NetworkManager + firewalld.

### Fedora Atomic

If required commands/packages are missing, bootstrap/role stops with layering instructions unless you explicitly enable `airvpn_atomic_layer_missing_packages`.

### Check mode

```bash
./bootstrap.sh --config-source /secure/airvpn-configs --check
```

Check mode is best-effort; some NetworkManager/firewalld operations are not fully simulated.

## Usage commands

| Command | Purpose |
| --- | --- |
| `airvpn-import --source DIR [--mode add\|replace] [--dry-run]` | Import/harden profiles and sync endpoint exceptions |
| `airvpn-switch [--name NAME \| --uuid UUID \| --disconnect]` | Activate a managed profile (interactive if no flag) or disconnect all managed tunnels |
| `airvpn-firewall-sync [--dry-run]` | Synchronize firewalld endpoint exceptions |
| `airvpn-status` | Status report (never prints private keys) |
| `airvpn-check --offline\|--online` | Verification with non-zero exit on failure |
| `airvpn-killswitch status\|enable\|disable [--force]` | Manage **only** project kill-switch policies |
| `airvpn-protect-connection NAME\|UUID` | Protect a new Wi-Fi/Ethernet profile |

Wrappers are installed under `/usr/local/bin`; implementation scripts live under
`/usr/local/libexec/airvpn-client`. Runtime commands require root via `sudo`.

### Activate, switch, or disconnect

```bash
sudo airvpn-status
sudo airvpn-switch                          # interactive menu
sudo airvpn-switch --name "AirVPN - …"      # exact managed profile name
sudo airvpn-switch --uuid <uuid>
sudo airvpn-switch --disconnect             # tear down managed tunnels; kill switch stays on
```

Disconnect leaves the fail-closed underlay in place: ordinary Internet traffic
remains blocked until you activate a profile again (or intentionally disable
the kill switch / uninstall).

## Expected kill-switch behavior

firewalld policy objects (not a parallel raw nftables ruleset):

```text
HOST -> airvpn        ACCEPT   (policy name default: airvpn-host-vpn)
HOST -> vpn-underlay  REJECT  (+ exact UDP endpoint exceptions, DHCP/NDP allowances)
                       (policy name default: airvpn-host-under)
```

Policy object names must be at most **18 characters** on supported Fedora/firewalld.
Override `airvpn_policy_to_vpn` / `airvpn_policy_to_underlay` only with short
`[A-Za-z0-9_-]` names; invalid overrides fail before firewalld changes.
Install removes known former default policy names after the current policies are
configured; uninstall removes current configured names plus those known former
defaults. Managed AirVPN interfaces are placed in the `airvpn` zone. Managed physical interfaces are placed in `vpn-underlay`.

`airvpn-killswitch disable` requires typing `DISABLE KILLSWITCH` (or `--force`) and warns that direct traffic may leak. It never stops firewalld globally.

## Verification

Prefer host-state inspection over website leak tests:

```bash
sudo airvpn-check --offline
sudo airvpn-status
sudo airvpn-check --online   # requires active tunnel
```

Checks cover commands/services, zones/policies, endpoint exceptions, autoconnect/zone/DNS settings, active managed VPN count, handshake, effective VPN routing (`ip route get`, including NetworkManager policy-routing tables), and unsafe physical connections.

## Suspend / resume

Managed AirVPN profiles are configured with `connection.autoconnect no`. After resume, if the tunnel is down, the underlay kill switch should continue blocking ordinary traffic until you run `airvpn-switch` again.

## Adding a new Wi-Fi or Ethernet profile

```bash
sudo airvpn-protect-connection "MyNewWiFi"
sudo airvpn-check --offline
```

## Updating AirVPN configurations

```bash
sudo airvpn-import --source /secure/airvpn-configs --mode add
# or replace all managed profiles:
sudo airvpn-import --source /secure/airvpn-configs --mode replace
```

## Uninstalling

```bash
source .venv/bin/activate
ansible-playbook playbooks/uninstall.yml \
  --ask-become-pass \
  -e airvpn_uninstall_confirmed=true
```

`--ask-become-pass` lets Ansible prompt for the sudo/become password on the
TTY (the playbook uses `become`). Inventory defaults come from `ansible.cfg`.

WARNING: Uninstalling removes project kill-switch policies/zones (including
known former default policy names) and can restore direct Internet access.
Managed config copies under `/etc/airvpn-client/configs` are preserved unless
`-e airvpn_uninstall_delete_configs=true`.

## Troubleshooting

- **Hostname Endpoint rejected**: Re-export AirVPN configs using numeric endpoints.
- **Atomic missing packages**: Layer with `rpm-ostree install …`, reboot, re-run bootstrap.
- **Active Wi-Fi not protected**: Run `airvpn-protect-connection`.
- **Handshake timeout**: Kill switch stays enabled; inspect `airvpn-status` and endpoint exceptions.
- **Need temporary direct access**: Only via explicit `airvpn-killswitch disable` (dangerous) or uninstall.

## Architecture

- **Ansible** owns installation, detection, dependency handling, script deployment, baseline firewall zones/policies, and uninstall.
- **Bash** owns runtime import/switch/sync/status/check operations with `set -Eeuo pipefail`, `flock`, `mktemp`, and UUID-oriented NetworkManager operations.
- **firewalld policy objects** implement HOST→zone filtering. `ansible.posix.firewalld` (2.2.2) has no policy module, so policies are managed with `firewall-cmd` plus idempotent `changed_when` logic and `airvpn-firewall-sync`.

Authoritative references:

- [firewalld policy objects introduction](https://firewalld.org/2020/09/policy-objects-introduction)
- [ansible.posix.firewalld](https://docs.ansible.com/projects/ansible/latest/collections/ansible/posix/firewalld_module.html)
- [Fedora Magazine: WireGuard with NetworkManager](https://fedoramagazine.org/configure-wireguard-vpns-with-networkmanager/)

## CI limitations

GitHub Actions run YAML/Ansible/Shell lint, syntax checks, unit tests (including
mocked integration-orchestrator tests), and secret scanning. They do **not**
run `tools/integration-test-vm`, install playbooks against a live host, or
validate NetworkManager/WireGuard/firewalld traffic. See
[docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md).

## Known limitations

- No remote SSH controller support
- No automatic dispatcher for new physical connections
- No current-endpoint-only firewall mode
- Broad underlay REJECT also blocks LAN unless you intentionally change policy (not recommended without understanding the risk)

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) — Copyright (c) 2026 bxvtr
