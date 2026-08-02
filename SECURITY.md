# Security Policy

## Unsupported claims

This project aims for a leak-**resistant**, fail-closed posture. It does **not** claim to be guaranteed leak-proof. Passing a public DNS leak website alone is not sufficient verification.

## Reporting a vulnerability

Please report security issues privately if possible.

1. Open a GitHub Security Advisory for this repository, or
2. Email the repository maintainers through the contact method listed on the GitHub organization profile.

Include:

- Fedora edition and version
- Whether the host is Atomic or package-based
- Redacted `airvpn-check` / `airvpn-status` output
- Steps to reproduce

Do **not** include:

- AirVPN WireGuard `.conf` files
- `PrivateKey` / `PresharedKey` values
- API tokens, Ansible Vault passwords, or GitHub tokens
- Personal IP addresses unless strictly necessary (prefer documentation ranges)

## Secret handling

AirVPN configuration files contain WireGuard private keys. Contributors must never commit them. See `.gitignore`, `.gitleaks.toml`, and `CONTRIBUTING.md`.

## Preferred disclosure timeline

Please allow reasonable time for assessment and a fix before public disclosure of exploitable kill-switch bypasses.
