# Dockhand (off-site)

A separate Dockhand on Quack01 that deploys its git stacks (`uptime-kuma`,
`alloy`). Separate on purpose: an agent of the primary's Dockhand would give
the primary root on the backup box. Why the YAML looks the way it does is in
the header of `dockhand-offsite.yml`.

## Install

1. Dataset `HDDs/dockhand` with two empty directories inside: `data/` and
   `ts-state/`.
2. Tailscale admin: a single-use, pre-approved, non-ephemeral auth key tagged
   `tag:dockhand` (the tag already exists for the primary's Dockhand).
3. TrueNAS → Apps → Discover → ⋮ → **Install via YAML**: paste
   `dockhand-offsite.yml`, replace `tskey-auth-REPLACE_ME` there (not in
   git), name the app `dockhand`, save.
4. Open `https://dockhand-offsite.<tailnet>.ts.net` and create the admin user
   straight away.
5. Add this repo (public, no credentials) and create the git stacks, each
   with its `.env` pasted in Dockhand:
   - `truenas/docker-compose/uptime-kuma` (off-site values in its
     `.env.example`)
   - `truenas/docker-compose/alloy` (`HOST_LABEL=quack01`)

Leave auto-update off, as on the primary: Pull → review → Redeploy.

## Updating Dockhand itself

Bump the two pinned image tags in `dockhand-offsite.yml`, commit, then paste
the new YAML into the app's Edit screen in TrueNAS.
