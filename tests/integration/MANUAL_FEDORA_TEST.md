# Manual Fedora integration test procedure
#
# WARNING: These steps modify NetworkManager and firewalld on a real host.
# Do not run them in CI. Do not run them until you explicitly intend to.
#
# Prefer the automated opt-in runner when possible:
#   tools/integration-test-vm \
#     --config-source /absolute/path/to/airvpn-configs \
#     --i-understand-this-modifies-networking
# See docs/INTEGRATION_TESTING.md.
#
# Prerequisites:
# - Fedora Workstation, Spin, or Atomic Desktop with NetworkManager + firewalld
# - AirVPN WireGuard .conf files with numeric endpoints (outside the Git tree)
# - Root access via sudo for privileged steps

## 1. Install with no active VPN
./bootstrap.sh --config-source /absolute/path/to/airvpn-configs
sudo airvpn-check --offline

## 2. Verify direct Internet is blocked
# With no managed VPN active, outbound traffic via the underlay should fail.
# Example (expect failure / timeout):
#   curl -4 --max-time 5 https://example.com
# Confirm policies with:
sudo airvpn-status
sudo airvpn-killswitch status

## 3. Activate a VPN
sudo airvpn-switch

## 4. Verify a current handshake
sudo airvpn-check --online
sudo airvpn-status

## 5. Verify public traffic works through the VPN
# curl should succeed while the tunnel is up.
# Also compare public IP to the selected AirVPN server expectation.

## 6. Switch servers
sudo airvpn-switch
# Select a different profile. During the switch, direct underlay traffic must
# remain blocked.

## 7. Confirm that direct ISP connectivity never appears
# While switching and after failures, underlay policy target must stay REJECT.

## 8. Disconnect the tunnel
sudo airvpn-switch --disconnect
# Or run sudo airvpn-switch and choose "Disconnect all managed AirVPN tunnels"

## 9. Confirm that traffic is blocked
# curl to the public Internet should fail again.

## 10. Suspend and resume
# Suspend the machine, resume, then:
sudo airvpn-status
# Expect either an intact VPN path or a blocked underlay (fail closed).
# Autoconnect is disabled for managed profiles, so a resume without an active
# tunnel should remain blocked.

## 11. Confirm fail-closed behavior
# Intentionally deactivate WireGuard / block handshake and ensure underlay
# REJECT remains enforced.

## 12. Test IPv6 behavior
# With airvpn_enable_ipv6 true, verify IPv6 routes and lack of underlay IPv6 leaks.

## 13. Test DNS routing
# resolvectl status should show VPN DNS / routing domain ~. while connected.
# DNS queries must not egress via the underlay.

## 14. Run uninstall and verify rollback
cd /path/to/fedora-airvpn-killswitch
source .venv/bin/activate
ansible-playbook playbooks/uninstall.yml \
  --ask-become-pass \
  -e airvpn_uninstall_confirmed=true
# Confirm project zones/policies are gone and physical zones restored.
# WARNING: direct Internet may work again after uninstall.
