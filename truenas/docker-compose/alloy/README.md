# Alloy

[Grafana Alloy](https://grafana.com/docs/alloy/) on the primary TrueNAS. Ships:

- **Logs**: every container's output → Loki, labelled `host`, `stack`
  (Compose project) and `container`. Secrets are scrubbed on the box first
  (`loki.process "redact"` in `config.alloy`).
- **Metrics**: host (node exporter: CPU, memory, disks, ZFS ARC, network)
  and per-container (cAdvisor) → Prometheus remote-write, labelled `host`.

Both go to the cluster's push-only endpoints
(`kubernetes/apps/monitoring/ingest-ingress.yaml`) over the tailnet. Read
them in Grafana (Explore → Loki: `{host="truenas"}`).

## Deploy

1. Tailscale admin: a single-use, pre-approved, non-ephemeral auth key
   tagged `tag:monitoring-agent`. (The policy grant
   `tag:monitoring-agent → tag:monitoring-ingest:443` already exists.)
2. Dockhand: add the stack pointed at this directory, fill `.env` from
   `.env.example`, deploy.
3. Check: `alloy-ts` joins the tailnet as `alloy-truenas`; Alloy's logs show
   no `loki.write` / `remote_write` errors; in Grafana,
   `{host="truenas"}` returns logs and `up{host="truenas"}` returns 1.

Alloy's debug UI is on `127.0.0.1:12345` of the TrueNAS host only (e.g.
`ssh -L 12345:127.0.0.1:12345 truenas`).

## Reusing on another Docker host

`config.alloy` takes everything box-specific from the environment. Copy the
stack, change `HOST_LABEL`, `TS_HOSTNAME` and `DOCKER_DATA_ROOT` (usually
`/var/lib/docker` off TrueNAS). Drop the `mnt/.ix-apps` exclude if you like.
