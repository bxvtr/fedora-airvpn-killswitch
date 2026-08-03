# Contributing

Thanks for contributing to **fedora-airvpn-killswitch**.

This project is unofficial and not affiliated with AirVPN.

## Language

- Communicate in pull requests and issues in English.
- All repository files must remain in English (code, comments, docs, CI, templates).

## Safety rules

- Never commit AirVPN `.conf` files or WireGuard private keys.
- Never commit tokens, vault passwords, personal IPs, or live NetworkManager keyfiles.
- Do not add tests that require mutating a contributor's live firewall in CI.
- Prefer fail-closed behavior over convenience.

## Recommended local Cursor setup

This repository configures privileged networking. Cursor safety files are
**defense in depth**, not a complete security boundary. They do **not** replace
OS user permissions, manual command review, avoiding passwordless sudo,
workspace isolation, or a disposable VM for live network tests.

Recommended practices:

- Run Cursor as a normal unprivileged user. Never run Cursor with `sudo`.
- Avoid passwordless sudo on development hosts.
- Use Cursor **Allowlist** mode with sandboxing for this repository.
- Do **not** use **Run Everything**.
- Keep Auto-fix disabled for security-sensitive findings.
- Prefer Ask or Plan mode for initial review of networking or firewall changes.
- Use `tools/validate-safe` for static checks and `tools/check-agent-safety`
  to verify repository guardrail files.
- Manually inspect every command approval prompt.
- Keep real AirVPN configurations **outside** the workspace.
- Never auto-run `tools/integration-test-vm` from agents, pre-commit, or CI.
  Launch it only with explicit human authorization inside a disposable Fedora
  VM that has a snapshot. See [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md).
- Treat Background or Cloud Agents as **code-development** environments only,
  not as places for real host-network tests.

### Cursor file roles (do not conflate)

| Path | Applies to |
| --- | --- |
| `.cursor/permissions.json` | Supported Cursor **IDE** run modes / Auto-review allowlists and block guidance |
| `.cursor/cli.json` | Cursor **CLI** project permissions (`allow` / `deny`) |
| `.cursor/rules/*.mdc` | Local **Agent** project instructions (not a technical sandbox) |
| `.cursor/BUGBOT.md` | **Bugbot** PR review guidance only |

The repository cannot configure your global Cursor UI settings automatically.
If project-level IDE allowlists are ignored by your Cursor build, mirror the
`terminalAllowlist` entries in `~/.cursor/permissions.json` as needed.

These controls are **not immutable**. An agent (or human) with edit approval can
change `.cursor/` files and `tools/validate-safe` / `tools/check-agent-safety`.
Always review such diffs and re-read wrapper contents before approving their
execution. OS permissions and disposable VMs remain stronger controls than
repository policy files. Local `.mdc` rules are instructions, not a sandbox;
IDE and CLI use separate permission files.

## Development setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-controller.txt
ansible-galaxy collection install -r requirements.yml -p .ansible/collections
pre-commit install
```

## Local checks

Preferred agent-safe entry point (static only; skips unavailable tools; never
installs packages; never runs live playbooks or AirVPN runtime commands):

```bash
tools/check-agent-safety
tools/validate-safe
```

`tools/validate-safe` intentionally omits `pre-commit` because hooks may
download environments, install hook dependencies, and the repository shfmt hook
uses `-w` (writes). You may still run `pre-commit run --all-files` yourself
after reviewing `.pre-commit-config.yaml`.

Manual equivalents:

```bash
bash tests/unit/run_all.sh
yamllint -c .yamllint .
ansible-lint
find bootstrap.sh roles/airvpn_client/files tests/unit tests/integration/lib tools -type f \( -name '*.sh' -o -name 'airvpn-*' -o -name 'bootstrap.sh' -o -name 'validate-safe' -o -name 'check-agent-safety' -o -name 'integration-test-vm' \) -print0 | xargs -0 shellcheck -x -S error
for pb in playbooks/*.yml; do
  ansible-playbook --syntax-check "$pb" -e airvpn_config_source=/tmp/dummy -e airvpn_uninstall_confirmed=true
done
pre-commit run --all-files
```

## Dependency updates

Pins are intentional for reproducibility.

| Artifact | File | Source of truth |
| --- | --- | --- |
| `ansible-core`, lint tools, pytest | `requirements-controller.txt` | PyPI |
| Ansible collections | `requirements.yml` | Ansible Galaxy |
| Pre-commit hooks | `.pre-commit-config.yaml` | GitHub releases/tags |
| GitHub Actions | `.github/workflows/*.yml` | Full commit SHA + version comment |

When updating:

1. Read upstream release notes and compatibility constraints (`ansible-core` Python requirement, `ansible-lint` supported core range, collection `requires_ansible`).
2. Update pins to exact versions (no broad ranges for the initial release line).
3. Run local checks above.
4. Note the rationale in the PR and `CHANGELOG.md`.

Dependabot is configured for pip and GitHub Actions. Collection and pre-commit pins may need manual PRs.

## Pull requests

- Keep changes focused.
- Include a test plan.
- Call out any kill-switch or secret-handling impact.
- Do not force-push to shared branches without coordination.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
