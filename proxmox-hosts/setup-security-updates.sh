#!/usr/bin/env bash
# Daily automatic install of DEBIAN SECURITY updates only, never a reboot.
# Everything else (Proxmox packages, kernels, Alloy, Tailscale, Debian point
# releases) waits for the monthly manual `apt update && apt full-upgrade`
# + reboot. See README.md.
#
# Usage (as root): ./setup-security-updates.sh   (safe to re-run)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

echo "==> Installing unattended-upgrades"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades

echo "==> Writing apt config"
# Turn on the daily apt timers' list refresh + unattended upgrade run.
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Written by proxmox-hosts/setup-security-updates.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Read after the package's 50unattended-upgrades. Its default origins also
# pull in normal Debian stable updates; #clear drops those so only the
# security archive is allowed. Proxmox's own repos are never matched.
cat >/etc/apt/apt.conf.d/52unattended-upgrades-homelab <<'EOF'
// Written by proxmox-hosts/setup-security-updates.sh
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
	"origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// Never reboot; a pending reboot shows up as /var/run/reboot-required.
Unattended-Upgrade::Automatic-Reboot "false";

// Leave kernel and dependency cleanup to the manual monthly upgrade
// (proxmox-boot-tool manages the boot entries).
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";

// Into the journal too, so runs show up in Loki
// ({unit="apt-daily-upgrade.service"}).
Unattended-Upgrade::SyslogEnable "true";
EOF

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

echo "==> Check (dry run)"
unattended-upgrade --dry-run --debug 2>&1 \
	| grep -E "Allowed origins|Packages that will be upgraded|No packages found" || true
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager
echo
echo "Done. Allowed origins above should list only the -security archive."
