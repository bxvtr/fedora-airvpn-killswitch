# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial public repository scaffold for Fedora AirVPN WireGuard + firewalld kill switch.
- Direct-on-host bootstrap with pinned `ansible-core` virtualenv and pinned collections.
- Ansible role for detection, dependencies, script install, NetworkManager hardening, and firewalld policies.
- Runtime commands: `airvpn-import`, `airvpn-switch`, `airvpn-firewall-sync`, `airvpn-status`, `airvpn-check`, `airvpn-killswitch`, `airvpn-protect-connection`.
- Unit tests for endpoint parsing and deterministic interface naming.
- CI workflows for lint, syntax, unit tests, and secret scanning.

### Fixed

- Make legacy firewalld policy cleanup use immutable task literals so
  `config.yml`, inventory, role params, and extra-vars cannot widen
  `--delete-policy` beyond `airvpn-host-to-vpn` and `airvpn-host-to-underlay`.
- Align usage, uninstall, and integration-test documentation with current
  CLI options, become prompting, post-install inactive posture, and
  `--skip-uninstall` lifecycle semantics.
- Migrate and uninstall known former firewalld policy defaults
  (`airvpn-host-to-vpn`, defensive `airvpn-host-to-underlay`) so upgrades do
  not leave duplicate project policies and uninstall cannot leave a legacy
  underlay REJECT policy behind while reporting success.
- Harden the VM integration First-VPN public IPv4 probe: bounded provider
  retries, strict IPv4 validation, preserved curl exit status, layered
  DNS/HTTPS classification, and structured artifacts so provider outages are
  not mislabeled as routing leaks (inconclusive lookups remain fail-closed).
- Verify online WireGuard egress with effective `ip route get` lookups so
  NetworkManager policy routing (`ip4-auto-default-route` / dedicated tables)
  is accepted; reject physical-underlay fallbacks. Capture policy-rule and
  all-table routing diagnostics in the VM integration runner.
- Leave newly imported WireGuard profiles inactive: NetworkManager may
  auto-activate on `connection import`; `autoconnect no` alone does not
  disconnect an already-active tunnel. Disconnect and verify inactivity
  before importing the next profile or finishing install.
- Import WireGuard profiles through a private temporary file named
  `<deterministic-ifname>.conf` so NetworkManager accepts long AirVPN
  source basenames; keep the original basename on the managed copy.
- Build the physical NetworkManager UUID fact with Jinja tests compatible with
  ansible-core 2.21 (`map('trim') | reject('equalto', '') | unique | list`)
  instead of invalid `select('length')`.
- Shorten default firewalld policy names to satisfy the 18-character
  `max_policy_name_len` limit on supported Fedora (`airvpn-host-vpn`,
  `airvpn-host-under`); reject overrides such as the former
  `airvpn-host-to-underlay` (23 characters) before firewalld mutation.
- Run firewalld zone/policy setup before NetworkManager import so `airvpn-firewall-sync` does not fail on missing policies.
- Load `airvpn_client` role defaults from `playbooks/uninstall.yml` so cleanup variables are defined.
- Track project-owned underlay endpoint rich rules in a state file; do not delete unrelated UDP accept rules.
- Detect missing `python3-firewall` on Fedora Atomic in addition to CLI command probes.
- Parse NetworkManager terse output with escape-aware field splitting for names containing `:`.
- Refresh managed WireGuard config copies in `airvpn-import --mode add` when profiles already exist.
- Use a single project-wide flock for mutating runtime commands, including `airvpn-protect-connection`.
- Nested lock re-entry uses inherited lock FD only; `AIRVPN_LOCK_HELD` is not trusted.
- Validate owned underlay rich rules before persisting or passing them to `firewall-cmd`.
- Remove obsolete project-shaped underlay endpoint rules from the live policy even when the ownership state file is missing; abort before rewriting ownership if `firewall-cmd` remove/add fails.
- Persist a pending firewalld reload marker until `firewall-cmd --reload` succeeds so a later sync retries applying permanent endpoint changes to the running firewall.
