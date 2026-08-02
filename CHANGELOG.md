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
