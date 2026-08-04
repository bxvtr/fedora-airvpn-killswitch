# Roadmap

This roadmap describes direction only. It has **no dates**, **no delivery
promises**, and does **not** expand the current release into unproven claims.
See [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) for what is live
validated versus only statically identified.

## v0.1.x Hardening

Focused on making the current direct-on-host Fedora kill-switch path safer and
clearer without redesigning network lifecycle automation:

- [x] Make uninstall safely repeatable after a successful first run
  (repository-sourced `airvpn-common.sh` for NM cleanup; mocked unit test;
  live `install → uninstall → uninstall` validated on Fedora Silverblue 43).
- [x] Harden uninstall audit snapshot publish and signal paths (atomic success
  gate; incomplete captures not published as final phases; best-effort
  `FAILED.txt`; compare rejects marked phases).
- Add stronger post-uninstall verification (zones, profiles, paths, optional
  machine-readable checks).
- Improve handling of partial uninstall failures beyond the repeatable-uninstall
  path already fixed (general recovery after arbitrary partial failures remains
  open).
- Have uninstall acquire the shared runtime project lock used by mutating
  `airvpn-*` commands.
- Improve the uninstall audit collector formatting and deterministic output.
- Clarify retained managed configuration and restore-zone behavior in operator
  messaging where helpful.
- Consider explicit checks for pre-existing project object name conflicts
  before mutating firewalld.

## v0.2.0 Network Lifecycle

Focused on physical connection lifecycle gaps that static review and daily
Wi-Fi use make important:

- Detect and protect physical connections created after installation.
- Add NetworkManager lifecycle integration for new connections (for example a
  carefully scoped dispatcher), without weakening fail-closed defaults.
- Validate physical Wi-Fi hardware.
- Validate SSID changes, roaming, reconnect, and suspend/resume.
- Validate simultaneous Ethernet and Wi-Fi.
- Restore exact pre-installation NetworkManager zone assignments where that is
  safe and recorded.
- Define safe behavior for dynamically appearing physical uplinks.

## Future

Items that may matter later but are not required to harden the current path:

- Ownership tracking or safer restoration for pre-existing firewalld objects
  that share project names.
- Broader Fedora variant validation beyond the current Silverblue 43 VM
  evidence.
- Optional package and service state restoration (today these remain system
  prerequisites).
- Additional diagnostics and machine-readable uninstall verification.
- More complex network scenarios such as tethering and captive portals.
- Remote Ansible controller over SSH.
- Packaging or Ansible Galaxy distribution.
- Optional “current endpoint only” underlay exception mode.

## Out of Scope for the Current Roadmap

- Non-Fedora distributions as supported targets
- Non-AirVPN providers or arbitrary VPN protocols
- A graphical client
- General-purpose firewall management unrelated to this project’s zones and
  policies
- Claiming guaranteed leak-proof behavior or a complete system rollback after
  uninstall

Contributions that improve safety, clarity, and reproducible validation of the
current Fedora + NetworkManager + firewalld path are preferred over early scope
expansion.
