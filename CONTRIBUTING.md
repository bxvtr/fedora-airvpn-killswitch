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

## Development setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-controller.txt
ansible-galaxy collection install -r requirements.yml -p .ansible/collections
pre-commit install
```

## Local checks

```bash
bash tests/unit/test_parsing.sh
yamllint -c .yamllint .
ansible-lint
find bootstrap.sh roles/airvpn_client/files tests/unit -type f \( -name '*.sh' -o -name 'airvpn-*' -o -name 'bootstrap.sh' \) -print0 | xargs -0 shellcheck -x -S error
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
