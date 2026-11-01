#!/usr/bin/env bash
# Install or update Grafana Alloy on a Proxmox host (journal -> Loki, node
# exporter -> Prometheus) plus the dedicated userspace Tailscale instance it
# pushes through. See README.md.
#
# Usage (as root, from the repo clone):
#   ./setup-alloy.sh                 # first run: prompts for what it needs
#   git pull && ./setup-alloy.sh     # later: re-installs config, restarts
#
# Non-interactive: HOST_LABEL=proxmox-ha TAILNET=tailXXXX.ts.net ./setup-alloy.sh
# The Tailscale auth key is only ever read from the terminal (not echoed,
# not an argument, not stored), and only on the first run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
env_file=/etc/alloy/homelab.env
ts_sock=/run/alloy-tailscale/tailscaled.sock

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
codename="$VERSION_CODENAME"

# Re-runs keep the values from the first run.
if [[ -f $env_file ]]; then
	# shellcheck source=/dev/null
	. "$env_file"
fi

if [[ -z ${HOST_LABEL:-} ]]; then
	read -rp "HOST_LABEL for this box (e.g. proxmox-ha, proxmox-k8s): " HOST_LABEL
fi
[[ $HOST_LABEL =~ ^[a-z0-9-]+$ ]] || { echo "HOST_LABEL must be [a-z0-9-]." >&2; exit 1; }

if [[ -z ${LOKI_PUSH_URL:-} || -z ${PROM_WRITE_URL:-} ]]; then
	if [[ -z ${TAILNET:-} ]]; then
		read -rp "Tailnet DNS name, including .ts.net (e.g. tailXXXX.ts.net): " TAILNET
	fi
	LOKI_PUSH_URL="https://loki.${TAILNET}/loki/api/v1/push"
	PROM_WRITE_URL="https://prometheus.${TAILNET}/api/v1/write"
fi

echo "==> Packages: alloy (Grafana repo), tailscale (Tailscale repo)"
install -d -m 755 /etc/apt/keyrings
if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
	curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
	chmod 644 /etc/apt/keyrings/grafana.asc
	echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
		>/etc/apt/sources.list.d/grafana.list
fi

tailscale_was_installed=yes
if ! command -v tailscaled >/dev/null; then
	tailscale_was_installed=no
	if [[ ! -f /etc/apt/sources.list.d/tailscale.list ]]; then
		curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.noarmor.gpg" \
			-o /usr/share/keyrings/tailscale-archive-keyring.gpg
		curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.tailscale-keyring.list" \
			-o /etc/apt/sources.list.d/tailscale.list
	fi
fi

apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q alloy tailscale

# If this script brought tailscale in, the host itself isn't meant to be on
# the tailnet: keep the package's default instance off, run only ours.
if [[ $tailscale_was_installed == no ]]; then
	systemctl disable --now tailscaled.service
fi

echo "==> Alloy config"
install -m 644 "$here/alloy/homelab.alloy" /etc/alloy/homelab.alloy
umask 027
cat >"$env_file" <<EOF
# Written by proxmox-hosts/setup-alloy.sh; read by alloy.service via the
# homelab.conf drop-in. No secrets in here.
CONFIG_FILE=/etc/alloy/homelab.alloy
HOST_LABEL=$HOST_LABEL
LOKI_PUSH_URL=$LOKI_PUSH_URL
PROM_WRITE_URL=$PROM_WRITE_URL
EOF
umask 022
chgrp alloy "$env_file"
alloy validate /etc/alloy/homelab.alloy

install -d -m 755 /etc/systemd/system/alloy.service.d
install -m 644 "$here/alloy/alloy-homelab.conf" /etc/systemd/system/alloy.service.d/homelab.conf
install -m 644 "$here/alloy/alloy-tailscaled.service" /etc/systemd/system/alloy-tailscaled.service
# The package adds alloy to these when they exist; make sure (journal access).
usermod -aG adm,systemd-journal alloy
systemctl daemon-reload

echo "==> Alloy's Tailscale instance"
systemctl enable --now alloy-tailscaled.service
for _ in $(seq 20); do [[ -S $ts_sock ]] && break; sleep 0.5; done
if tailscale --socket="$ts_sock" status >/dev/null 2>&1; then
	echo "Already logged in."
else
	echo "Needs a single-use, pre-approved, non-ephemeral auth key tagged"
	echo "tag:monitoring-agent (Tailscale admin -> Settings -> Keys)."
	read -rsp "Paste the auth key (not echoed): " ts_key
	echo
	# Hand it over via a root-only file on tmpfs (tailscale reads
	# --auth-key=file:<path>), so it never appears in the process list.
	key_file="$(mktemp -p /run alloy-ts-key.XXXXXX)"
	trap 'rm -f "$key_file"' EXIT
	printf '%s' "$ts_key" >"$key_file"
	unset ts_key
	tailscale --socket="$ts_sock" up --auth-key="file:$key_file" --hostname="alloy-${HOST_LABEL}"
	rm -f "$key_file"
fi

echo "==> Alloy"
systemctl enable alloy.service
systemctl restart alloy.service
sleep 5
systemctl --no-pager --lines=0 status alloy.service alloy-tailscaled.service || true
tailscale --socket="$ts_sock" status --self --peers=false || true

echo
echo "Done. In Grafana: {host=\"$HOST_LABEL\"} in Loki and up{host=\"$HOST_LABEL\"} in Prometheus."
echo "Errors, if any: journalctl -u alloy -n 50 --no-pager | grep -iE 'error|warn'"
