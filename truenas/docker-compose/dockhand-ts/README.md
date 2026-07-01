# dockhand-ts

Standalone Tailscale sidecar that gives the **Dockhand** TrueNAS app its own
Tailnet device and MagicDNS hostname (`dockhand.<tailnet>.ts.net`), matching the
per-service device model used by the `arr-stack` and `immich` stacks.

## Why a separate stack

Dockhand runs as a TrueNAS **app**, not a Compose project, so it can't host an
in-Compose sidecar the way arr-stack / immich do — those work because the
`tailscale/tailscale` container shares a Compose network with the app and
proxies by container name (`http://immich-server:2283`).

Instead this stack runs **only** a `tailscale/tailscale` container in userspace
mode and points `tailscale serve` at Dockhand on the host's **LAN IP:port**. No
shared network is required; the sidecar just has to reach the port.

Alternatives considered and rejected:

- **Convert Dockhand to a Compose stack + in-Compose sidecar** — a stack manager
  managing its own container can deadlock on redeploy.
- **Reuse the host Tailscale app's `tailscale serve`** — simplest, but puts
  Dockhand on the host's Tailnet identity instead of its own tagged device.

## Where Dockhand's own data lives

This stack only provides network access; Dockhand's storage is configured in the
TrueNAS app itself. Recommended:

- **Put Dockhand's config/appdata on a dataset on the `apps` (SSD) pool** — e.g.
  `apps/dockhand`. Its state is small and benefits from SSD latency.
- **Point Dockhand's *stacks* directory at the `apps` pool too.** This is the
  directory where Dockhand checks out git-wired stacks and stores their compose
  projects. Because stacks use **relative** bind mounts (`./configs`,
  `./ts-state`), everything Dockhand manages inherits SSD performance for free —
  e.g. the arr-stack's SQLite databases land on SSD with no per-service path
  juggling.
- **Reaching the `tank` pool**: managed stacks still bind bulk data from `tank`
  via absolute paths (e.g. arr-stack's `MEDIA_PATH=/mnt/tank/media`). The Docker
  engine runs on the host with full filesystem access, so a stack whose project
  dir is on `apps` can mount volumes from `tank` with no extra configuration —
  exactly the arr-stack case.

> Note: the local box uses **Dockhand only** — no Dockge (unlike the remote
> TrueNAS box).

## Setup

1. Confirm Dockhand's published port and the box's LAN IP. TrueNAS apps get a
   high node-port (30000-32767) rather than the app's native port — check the
   **Ports** panel on the Dockhand app (it should bind `0.0.0.0:<port>`, e.g.
   `30328`; `0.0.0.0` is required so the sidecar can reach it over the LAN IP).
2. `cp .env.example .env` and set:
   - `DOCKHAND_UPSTREAM=<lan-ip>:<port>`
   - `TS_AUTHKEY_DOCKHAND` — reusable, pre-approved, tagged per your ACLs.
3. Deploy the stack (via Dockhand, or `docker compose up -d`).
4. Approve the new `dockhand` device in the Tailscale admin console if it isn't
   auto-approved, then browse to `https://dockhand.<tailnet>.ts.net`.

## Files

```
dockhand-ts/
├── docker-compose.yml
├── .env.example
├── .gitignore
└── README.md
```

`ts-state/` (the device's node key) and `.env` are gitignored.
