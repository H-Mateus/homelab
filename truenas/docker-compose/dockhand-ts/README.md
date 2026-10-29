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
mode and points `tailscale serve` at Dockhand's published node-port on the host,
via `host.docker.internal` (mapped to Docker's `host-gateway`). No shared network
or LAN IP is required; the sidecar just has to reach the port.

`serve.json` is committed under `ts-config/dockhand/` and bind-mounted as a
directory rather than defined with Compose `configs:`. Dockhand's image
auto-update recreates containers without materialising `configs:`, which left
the old version crash-looping (containerboot's fsnotify watch on a missing
`/config/serve.json`) until a manual redeploy. A bind mount survives that path.

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
   `30328`; `0.0.0.0` is required so the sidecar can reach it via the host
   gateway). If it differs, update the `Proxy` URL in
   `ts-config/dockhand/serve.json`.
2. `cp .env.example .env` and set `TS_AUTHKEY_DOCKHAND` — reusable,
   pre-approved, tagged per your ACLs.
3. Deploy the stack git-wired in Dockhand (so `ts-config/` is synced alongside
   the compose file), or `docker compose up -d` from a checkout.
4. Approve the new `dockhand` device in the Tailscale admin console if it isn't
   auto-approved, then browse to `https://dockhand.<tailnet>.ts.net`.

## Files

```
dockhand-ts/
├── docker-compose.yml
├── ts-config/dockhand/serve.json
├── .env.example
├── .gitignore
└── README.md
```

`ts-state/` (the device's node key) and `.env` are gitignored.
