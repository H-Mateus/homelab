# Proxmox hosts

Setup for the two bare-metal Proxmox VE hosts: the cluster host (HP ProDesk,
runs the Talos VMs) and the Home Assistant box (ThinkCentre, runs the HA VM and
the Frigate LXC). Neither runs Docker, so the scripts install things as
ordinary Debian packages and systemd services. Both scripts are safe to re-run.

(Not to be confused with `proxmox/`, the untracked legacy Talos configs.)

| Host | `HOST_LABEL` |
|---|---|
| Cluster host (ProDesk) | `proxmox-k8s` |
| HA box (ThinkCentre, hostname `homeassistant`) | `proxmox-ha` |

## Getting the scripts onto a host

The repo is public, so clone it the same way as on the Frigate LXC:

```bash
apt install -y git
git clone https://github.com/H-Mateus/homelab.git /root/homelab
cd /root/homelab/proxmox-hosts
```

Update later with `cd /root/homelab && git pull`.

## Security updates: `setup-security-updates.sh`

```bash
./setup-security-updates.sh
```

- Installs `unattended-upgrades` and lets it install **Debian security updates
  only**, once a day, through the stock `apt-daily-upgrade.timer`.
- **Never reboots.** If an update needs one, `/var/run/reboot-required` exists.
- Proxmox packages (kernel, qemu, ZFS, pve-*), Debian point releases, Alloy and
  Tailscale are **not** touched. They wait for the monthly manual upgrade:
  ```bash
  apt update && apt full-upgrade   # never plain `apt upgrade` on Proxmox
  reboot                           # only if the kernel or pve stack changed
  ```
  On the HA box, shut down the HA VM and the Frigate LXC cleanly first, or let
  their `onboot` + shutdown ordering handle it.
- What it installed shows in `/var/log/unattended-upgrades/` and in Loki at
  `{host="<label>", unit="apt-daily-upgrade.service"}` once Alloy is running.

## Logs and metrics: `setup-alloy.sh`

The Proxmox version of `truenas/docker-compose/alloy/` (same output, same
`host` label scheme, same secret redaction; no container parts):

- **Logs**: the host's systemd journal → Loki, labelled `host`, `unit`,
  `level` (`{host="proxmox-ha", job="loki.source.journal.host"}`). Includes
  pveproxy, pvedaemon, qemu-server, pve-cluster, the kernel, ZFS, sshd.
- **Metrics**: node exporter (CPU, memory, disks, ZFS ARC, network) →
  Prometheus remote-write, labelled `host`. The Node Exporter Full dashboard
  picks it up via its host picker.

How it reaches the cluster: the ingest endpoints only accept
`tag:monitoring-agent`. Instead of giving the host's own Tailscale identity
push rights, the script runs a **second, userspace Tailscale instance**
(`alloy-tailscaled.service`, its own state/socket/port, device name
`alloy-<HOST_LABEL>`) that offers an HTTP proxy on `127.0.0.1:1055`, exactly
like the `alloy-ts` sidecar on the Docker hosts. It doesn't touch the host's
routes, DNS or any existing `tailscaled`. Nothing listens beyond loopback.

Steps:

1. Tailscale admin → Settings → Keys: a single-use, pre-approved,
   non-ephemeral auth key tagged `tag:monitoring-agent`, one per host.
2. On the host:
   ```bash
   ./setup-alloy.sh
   ```
   It asks for the `HOST_LABEL` (table above), the tailnet's full DNS name (e.g.
   `tailXXXX.ts.net`, including `.ts.net`) and the auth key (typed, not echoed, not stored
   by the script).
3. Check: the `alloy-<HOST_LABEL>` device appears in the Tailscale admin, and
   `journalctl -u alloy -n 50` shows no `loki.write` / `remote_write` errors.

To change the config, edit `alloy/homelab.alloy`, push, then on each host
`git pull && ./setup-alloy.sh`. Alloy's debug UI is on `127.0.0.1:12345`
(`ssh -L 12345:127.0.0.1:12345 root@<host>`).

### What goes where on the host

| Path | From |
|---|---|
| `/etc/alloy/homelab.alloy` | `alloy/homelab.alloy` |
| `/etc/alloy/homelab.env` | written by the script (label + URLs, no secrets) |
| `/etc/systemd/system/alloy.service.d/homelab.conf` | `alloy/alloy-homelab.conf` |
| `/etc/systemd/system/alloy-tailscaled.service` | `alloy/alloy-tailscaled.service` |
| `/var/lib/alloy-tailscale/` | Tailscale state for `alloy-<HOST_LABEL>` |

The package's own `/etc/default/alloy` and `/etc/alloy/config.alloy` are left
as shipped, so `apt full-upgrade` never stops to ask about changed config
files. The drop-in points the service at `homelab.alloy` instead.

### Removing it

```bash
systemctl disable --now alloy alloy-tailscaled
apt purge alloy
rm -rf /etc/systemd/system/alloy.service.d /etc/systemd/system/alloy-tailscaled.service \
  /var/lib/alloy-tailscale /etc/alloy/homelab.* /etc/apt/sources.list.d/grafana.list
systemctl daemon-reload
```

Then delete the `alloy-<HOST_LABEL>` device in the Tailscale admin.
