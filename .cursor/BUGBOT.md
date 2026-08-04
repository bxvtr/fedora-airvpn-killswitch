# Bugbot Review Instructions

## Project context

This repository configures NetworkManager, WireGuard, and firewalld on Fedora
systems. Changes may affect host connectivity, firewall behavior, DNS routing,
and access to sensitive WireGuard configuration files.

Prioritize correctness, fail-closed behavior, reversibility, idempotency, and
secret safety over convenience.

## Review priorities

Pay particular attention to:

- paths that could allow direct internet traffic outside the VPN
- overly broad firewalld rules or endpoint exceptions
- IPv4 or IPv6 behavior that is handled only partially
- DNS traffic escaping through physical connections
- commands that may modify unrelated NetworkManager profiles
- commands that may delete unrelated firewalld objects
- private keys or complete WireGuard configurations appearing in logs
- unsafe shell quoting, word splitting, globbing, or temporary-file handling
- missing locking around concurrent network operations
- non-idempotent Ansible tasks
- inaccurate `changed_when` or `failed_when` conditions
- Fedora Atomic code paths that unexpectedly use DNF or require a reboot
- uninstall behavior that can leave the host in an inconsistent state
- localized human-readable command output being parsed unnecessarily

## Security invariants

Treat the following as required invariants:

1. Ordinary internet traffic must remain blocked when no managed VPN is active.
2. Switching VPN profiles must not temporarily disable the kill switch.
3. Only exact configured WireGuard endpoint IP and UDP port pairs may be
   permitted through the physical underlay.
4. Hostname-based WireGuard endpoints must be rejected unless explicitly
   implemented and documented.
5. Private keys must never be printed, logged, committed, or exposed in CI.
6. Project operations must not modify unrelated VPN profiles, physical
   connections, firewall zones, policies, or rules.
7. Disabling the project kill switch must require an explicit action and must
   not disable firewalld globally.

## Review boundaries

Do not assume GitHub-hosted CI can fully validate NetworkManager, firewalld,
WireGuard, routing, suspend/resume, or real Fedora Atomic behavior.

Flag missing tests and unsafe assumptions, but do not report the absence of
destructive live-network CI tests as a defect.
