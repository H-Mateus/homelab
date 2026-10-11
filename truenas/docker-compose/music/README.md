# music

Self-hosted music streaming with Navidrome, replacing Spotify. Tailnet-only,
at `https://navidrome.<tailnet>.ts.net`.

## Datasets

| Dataset | Preset | Notes |
|---|---|---|
| `tank/media/music` | Apps | The library. Record size **1M** (large files read sequentially), atime off. A child of `tank/media` so it can be snapshotted and replicated by itself. The `tank` snapshot task isn't recursive, so add it explicitly. |
| `apps/music` | Apps | App state. Inherits defaults; covered by the recursive `apps` snapshot task. |

## Deploy

Git-wired in Dockhand (`truenas/docker-compose/music`). Fill in the env from
`.env.example`, using Dockhand's secret toggle for the entries marked
`[secret]`.

## Clients

- **iPhone:** Amperfy (free, open source, offline downloads, CarPlay).
  play:Sub and Narjo are polished paid alternatives. Set the streaming and
  download format to AAC or Opus ~256k; Navidrome converts on the fly, so the
  library stays in its original quality.
- **Desktop:** Feishin, or the web UI.
