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

- Run firewalld zone/policy setup before NetworkManager import so `airvpn-firewall-sync` does not fail on missing policies.
- Load `airvpn_client` role defaults from `playbooks/uninstall.yml` so cleanup variables are defined.
- Track project-owned underlay endpoint rich rules in a state file; do not delete unrelated UDP accept rules.
- Detect missing `python3-firewall` on Fedora Atomic in addition to CLI command probes.
- Parse NetworkManager terse output with escape-aware field splitting for names containing `:`.
- Refresh managed WireGuard config copies in `airvpn-import --mode add` when profiles already exist.
- Use a single project-wide flock for mutating runtime commands, including `airvpn-protect-connection`.
- Nested lock re-entry uses inherited lock FD only; `AIRVPN_LOCK_HELD` is not trusted.
- Validate owned underlay rich rules before persisting or passing them to `firewall-cmd`.
