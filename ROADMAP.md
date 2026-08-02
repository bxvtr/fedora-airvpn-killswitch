# Roadmap

## Version 1 (current focus)

- Direct Ansible execution on the managed Fedora host (controller == managed host).
- Fedora Workstation, Spins, and Atomic Desktops with NetworkManager + firewalld.
- AirVPN WireGuard import, profile hardening, firewalld policy kill switch, and runtime switching.

## Possible future work

These items are intentionally **not** implemented in version 1:

- Remote Ansible controller over SSH
- Additional Linux distributions (Debian, Ubuntu, Arch Linux, openSUSE, etc.)
- Automated protection of newly created physical NetworkManager profiles via a dispatcher script
- Broader automated integration testing on real Fedora networking stacks
- Publishing as a package or Ansible Galaxy role
- Graphical user interface
- Optional mode that allows only the currently selected VPN endpoint (instead of all imported endpoints)

Contributions that advance version-1 safety, clarity, and reproducibility are preferred over expanding scope early.
