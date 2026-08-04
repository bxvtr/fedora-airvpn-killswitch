# Integration fixtures

Do **not** place real AirVPN WireGuard `.conf` files here.

Real configurations contain `PrivateKey` material and must remain **outside**
the Git repository (for example `/secure/airvpn-configs` on the VM).

Fake parsing fixtures used by unit tests live under `tests/fixtures/` and use
documentation-range addresses only.

When running `tools/integration-test-vm`, pass:

```bash
--config-source /absolute/path/outside/the/repo
```
