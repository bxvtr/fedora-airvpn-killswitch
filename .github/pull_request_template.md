## Summary

<!-- What does this PR change and why? -->

## Security impact

<!-- Does this affect kill-switch behavior, secret handling, or firewall rules? -->

- [ ] No security-sensitive behavior change
- [ ] Security-sensitive change (describe verification performed)

## Test plan

- [ ] `bash tests/unit/test_parsing.sh`
- [ ] `yamllint` / `ansible-lint` / `shellcheck` (or pre-commit)
- [ ] Ansible `--syntax-check` on playbooks
- [ ] Manual Fedora checks if networking behavior changed (describe)

## Checklist

- [ ] No AirVPN `.conf` files, private keys, tokens, or personal IPs included
- [ ] Documentation updated when user-facing behavior changes
- [ ] Repository text remains in English
