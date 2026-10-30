# Uptime Kuma

Uptime checks, alerts and a status page for the homelab. Two copies that
watch each other:

| Copy | Box | Tailnet name | Deployed by | Watches |
|---|---|---|---|---|
| `docker-compose.yml` | primary TrueNAS | `uptime` | Dockhand (git) | everything |
| `offsite.yml` | Quack01 (off-site) | `uptime-offsite` | TrueNAS "Install via YAML" | the primary Kuma + a handful of key services |

Why two: the primary copy can't tell you the house is offline, because its
alerts have to leave via the house's internet connection. The off-site copy
sees that from outside. Each one monitors the other, so either dying alerts
from the survivor.

Kuma deliberately runs outside the Talos cluster: the cluster (and Grafana)
are among the things it watches.

## Deploy

1. **Tailscale ACL** (admin console): add the tag and let it reach what it
   monitors.
   ```jsonc
   "tagOwners": { "tag:uptime-kuma": ["autogroup:admin"] },
   "grants": [
     { "src": ["tag:uptime-kuma"], "dst": ["*"], "ip": ["tcp:443", "tcp:80", "icmp:*"] }
   ]
   ```
   Narrow `dst` to specific tags later if you prefer.
2. **Auth keys**: two single-use, pre-approved, non-ephemeral keys tagged
   `tag:uptime-kuma`.
3. **Primary**: create dataset `apps/uptime-kuma`, add the stack in Dockhand
   pointed at this directory, fill `.env` from `.env.example`, deploy.
4. **Off-site**: create dataset `HDDs/uptime-kuma` with `data/` and
   `ts-state/` inside, paste `offsite.yml` into TrueNAS → Apps → Install via
   YAML, replace `tskey-auth-REPLACE_ME` there (not in git), deploy.
5. Open `https://uptime.<tailnet>.ts.net` and `https://uptime-offsite.<tailnet>.ts.net`
   and create the admin user on each straight away.
6. Check MagicDNS works from inside Kuma: add an HTTP monitor for another
   `*.ts.net` service. If it can't resolve, use the device's 100.x address.

## What to monitor

**Primary (`uptime`)**

- HTTP(S): every app's Tailnet URL (Sonarr, Radarr, Jellyfin, Immich,
  Paperless, Navidrome, Dockhand, Grafana, …), Home Assistant, Frigate,
  Proxmox (`:8006`), pfSense web UI.
- Ping: pfSense, the Proxmox host, TrueNAS, the Talos VIP (`192.168.1.55`),
  each camera (VLAN 30).
- `https://uptime-offsite.<tailnet>.ts.net` — the other watcher.

**Off-site (`uptime-offsite`)**

- `https://uptime.<tailnet>.ts.net` — the primary watcher.
- A few signals that mean "the house is up": Home Assistant, Immich, the
  primary TrueNAS.

**Both**: a **Push** monitor on healthchecks.io (free) as a dead man's
switch. If both copies are down at once (e.g. a power cut), healthchecks.io
notices the missing heartbeats.

## Alerts

Send them through a service outside the house (ntfy.sh, Pushover or
Telegram), not Home Assistant: HA goes down with the house, which is
exactly when you need the alert.

## Metrics

Kuma serves Prometheus metrics at `/metrics` (Settings → API Keys). Scraping
that into the cluster's Prometheus puts uptime history in Grafana next to
everything else.
