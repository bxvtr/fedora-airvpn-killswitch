# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-04

Initial public release of the Fedora AirVPN WireGuard kill switch for Fedora 43
(NetworkManager + firewalld). Live validation covered Fedora Silverblue 43 under
KVM/Fedora Boxes with a virtual Ethernet interface. See
[docs/RELEASE_NOTES_v0.1.0.md](docs/RELEASE_NOTES_v0.1.0.md) and
[docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

### Added

- Fedora 43 AirVPN WireGuard kill-switch implementation (direct-on-host Ansible
  + Bash runtime).
- NetworkManager import and management of AirVPN WireGuard profiles (imported
  profiles remain inactive until explicit activation).
- Fail-closed IPv4, IPv6, and DNS underlay posture without an active managed VPN.
- Managed VPN activation and switching with endpoint-specific underlay firewall
  allowances.
- Runtime commands: `airvpn-import`, `airvpn-switch`, `airvpn-firewall-sync`,
  `airvpn-status`, `airvpn-check`, `airvpn-killswitch`,
  `airvpn-protect-connection`.
- Confirmed uninstall playbook with restore-zone behavior and optional managed
  config retention.
- Manual disposable-VM integration workflow and uninstall audit snapshot
  collector (`tools/uninstall-audit-snapshot`).
- Known limitations, roadmap, and validation documentation.
- Unit tests and CI for lint, syntax, unit coverage, and secret scanning.

### Fixed

- Repeated uninstall no longer depends on installed runtime libraries removed by
  the first successful uninstall (repository-sourced `airvpn-common.sh`).
- Incomplete audit snapshots are no longer published after interrupted or failed
  capture; successful phases publish atomically after a full capture.
- Failed audit partial handling and signal-path robustness (`SIGINT`/`SIGTERM`
  exit status, best-effort `FAILED.txt`, compare rejects marked phases).

### Security

- Restrictive handling of managed WireGuard configuration copies.
- Secret redaction and avoidance of private-key logging in status/diagnostics.
- Atomic publication of successful uninstall audit snapshots only.
- Fail-closed network behavior without an active managed VPN (validated on the
  documented Silverblue 43 path; not a universal leak-proof guarantee).

### Known limitations

Current limitations (physical Wi-Fi lifecycle, post-install connection
protection, suspend/resume, dual uplink, uninstall lock, restore-zone vs exact
pre-install zones, retained configs, pre-existing firewalld name collisions)
are documented in [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).
