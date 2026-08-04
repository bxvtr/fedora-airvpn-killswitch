# Live Fedora VM integration testing

This directory holds the **opt-in** live integration-test helpers used by
`tools/integration-test-vm`.

## Warning

The live runner modifies NetworkManager, firewalld, WireGuard, routing, and DNS
inside the guest. It is **not** started by:

- cloning the repository
- `tools/validate-safe`
- pre-commit
- ordinary GitHub-hosted CI
- `./bootstrap.sh` (unless you deliberately run the VM runner yourself)

Run it only inside a disposable Fedora VM with a snapshot, after reading
[docs/INTEGRATION_TESTING.md](../../docs/INTEGRATION_TESTING.md).

## Layout

| Path | Purpose |
| --- | --- |
| `lib/*.sh` | Testable helpers (report, probes, redaction, assertions) |
| `fixtures/README.md` | Why real AirVPN configs must stay outside the clone |
| `MANUAL_FEDORA_TEST.md` | Legacy manual checklist (still useful; prefer the automated runner) |

## Unit tests

Logic in `lib/` is exercised by `tests/unit/test_integration_orchestrator.sh`
with mocks only — no live NetworkManager/firewalld calls.
