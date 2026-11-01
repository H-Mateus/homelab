# Alloy

[Grafana Alloy](https://grafana.com/docs/alloy/) for every Docker host in the
homelab. The same files run on each box; only `.env` differs. Ships:

- **Logs**: every container's output → Loki, labelled `host`, `stack`
  (Compose project) and `container`; plus the host's own systemd journal
  (kernel, sshd, TrueNAS middleware, ZFS, Docker daemon, ...), labelled
  `host`, `unit` and `level` (`{host="truenas", job="loki.source.journal.host"}`). Secrets are scrubbed on the box first
  (`loki.process "redact"` in `config.alloy`).
- **Metrics**: host (node exporter: CPU, memory, disks, ZFS ARC, network)
  and per-container (cAdvisor) → Prometheus remote-write, labelled `host`.

Both go to the cluster's push-only endpoints
(`kubernetes/apps/monitoring/ingest-ingress.yaml`) over the tailnet. Read
them in Grafana (Explore → Loki: `{host="<HOST_LABEL>"}`; the Node Exporter
Full and Cadvisor dashboards in the Homelab folder have a host picker).

The stack lives under `truenas/` for history (moving it would orphan the
primary's Dockhand stack and its Tailscale state); it is not TrueNAS-specific.

## Per-box settings

| Box | Deployed by | `HOST_LABEL` | `DOCKER_DATA_ROOT` | `TS_HOSTNAME` |
|---|---|---|---|---|
| Primary TrueNAS | Dockhand (git stack) | `truenas` | `/mnt/.ix-apps/docker` | `alloy-truenas` |
| Quack01 | see its deployment notes | `quack01` | `/mnt/.ix-apps/docker` | `alloy-quack01` |
| Frigate LXC | `docker compose` from the git clone | `frigate` | `/var/lib/docker` | `alloy-frigate` |

Check a box's data root with `docker info -f '{{.DockerRootDir}}'`. A wrong
value doesn't break logs, but cAdvisor falls back to reporting only the
root cgroup (no per-container metrics).

## Deploy

1. Tailscale admin: a single-use, pre-approved, non-ephemeral auth key
   tagged `tag:monitoring-agent`, one per box. (The policy grant
   `tag:monitoring-agent → tag:monitoring-ingest:443` already exists.)
2. Fill `.env` from `.env.example` with the row above.
   - **Dockhand**: add the stack pointed at this directory, paste the `.env`
     in its UI, deploy.
   - **Plain Docker** (Frigate LXC, repo cloned at `/root/homelab`):
     ```bash
     cd /root/homelab && git pull
     cd truenas/docker-compose/alloy
     cp .env.example .env && chmod 600 .env   # then edit it
     docker compose up -d
     ```
     `.env` and `ts-state/` are gitignored, so `git pull` keeps working.
     Update later with `git pull && docker compose up -d`.
3. Check: `alloy-ts` joins the tailnet as `TS_HOSTNAME`; `docker logs alloy`
   shows no `loki.write` / `remote_write` errors; in Grafana,
   `{host="<HOST_LABEL>"}` returns logs and `up{host="<HOST_LABEL>"}` is 1.

Alloy's debug UI listens on `127.0.0.1:12345` of each host only (e.g.
`ssh -L 12345:127.0.0.1:12345 root@<box>`).

## pfSense (via the Frigate LXC)

pfSense can't run Alloy, so the Frigate LXC's Alloy collects for it. Two
optional `.env` values, set **only** there:

| Variable | Frigate LXC | Elsewhere |
|---|---|---|
| `SYSLOG_LISTEN_ADDR` | `192.168.1.39:1514` (UDP syslog listener on its LAN IP) | unset → `127.0.0.1:1514`, receives nothing |
| `PFSENSE_EXPORTER` | `<pfSense LAN IP>:9100` (node_exporter package) | unset → no target |

Logs arrive as `{host="pfsense", job="syslog"}` with `unit` = program
(`filterlog`, `unbound`, `dhcpd`, `sshd`, `php-fpm`, ...) and `level`; metrics
as `up{host="pfsense"}`. FreeBSD's node_exporter names some memory and disk
metrics differently, so parts of the Node Exporter Full dashboard stay empty.

pfSense side:

1. **Status → System Logs → Settings**:
   - *Log Message Format*: **syslog (RFC 5424)**.
   - *Enable Remote Logging*, *Source Address*: LAN, *IP Protocol*: IPv4,
     *Remote log servers*: `192.168.1.39:1514`, *Remote Syslog Contents*:
     Everything (untick firewall events if `filterlog` is too noisy).
2. **System → Package Manager**: install the node_exporter package, enable it
   under its Services page, listening on the **LAN** interface only, port 9100.

The syslog listener has no authentication: anything on the LAN can send it
lines (it can't read anything back). That's the usual trade-off for syslog
on a home LAN; the cameras' VLAN can't reach it.

## Not covered here

Hosts without Docker (the Proxmox hosts) run Alloy as a system package with
their own config: see `proxmox-hosts/`.
