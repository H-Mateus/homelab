# Storage Pools & Datasets

This document describes the ZFS pool and dataset layout used on the TrueNAS server.

## Pool Layout

| Pool | Vdev Type | Drives | Purpose |
|------|-----------|--------|---------|
| `tank` | Mirror / RAIDZ | Data drives | Primary storage pool |
| `boot-pool` | Stripe | Boot SSD | TrueNAS OS installation |

> Adjust the vdev type to match your actual hardware. A **mirror** (RAID-1 equivalent) is recommended for small numbers of drives; **RAIDZ2** (RAID-6 equivalent) provides better fault tolerance for larger arrays.

## Dataset Structure

All datasets are created under the `tank` pool.

```
tank/
├── docker/                  # Docker-related data
│   ├── appdata/             # Persistent container config and data volumes
│   │   ├── jellyfin/
│   │   ├── sonarr/
│   │   ├── radarr/
│   │   ├── prowlarr/
│   │   ├── bazarr/
│   │   ├── qbittorrent/
│   │   ├── traefik/
│   │   ├── grafana/
│   │   ├── prometheus/
│   │   ├── vaultwarden/
│   │   └── nextcloud/
│   └── compose/             # Docker Compose file copies (mirrors this repo)
│       ├── media/
│       ├── networking/
│       ├── monitoring/
│       └── productivity/
├── media/                   # Media library (read by Jellyfin)
│   ├── movies/
│   ├── tv/
│   └── music/
├── downloads/               # Download staging area
│   ├── complete/
│   └── incomplete/
├── backups/                 # Off-site / local backup targets
└── nextcloud/               # Nextcloud user data
```

## Dataset Settings

Recommended ZFS properties per dataset type:

| Dataset | Compression | Case Sensitivity | ACL Type | Notes |
|---------|-------------|-----------------|----------|-------|
| `docker/appdata` | `lz4` | sensitive | POSIX | Fast compression for config files |
| `media` | `off` | sensitive | POSIX | Media files are already compressed |
| `downloads` | `lz4` | sensitive | POSIX | Temporary storage |
| `backups` | `lz4` | sensitive | POSIX | |
| `nextcloud` | `lz4` | sensitive | POSIX | |

### Creating Datasets via the CLI

```bash
# Create the top-level datasets
zfs create tank/docker
zfs create tank/docker/appdata
zfs create tank/docker/compose
zfs create tank/media
zfs create tank/media/movies
zfs create tank/media/tv
zfs create tank/media/music
zfs create tank/downloads
zfs create tank/downloads/complete
zfs create tank/downloads/incomplete
zfs create tank/backups
zfs create tank/nextcloud

# Enable compression on all new datasets
zfs set compression=lz4 tank/docker
zfs set compression=lz4 tank/downloads
zfs set compression=lz4 tank/backups
zfs set compression=lz4 tank/nextcloud
# Leave tank/media uncompressed
zfs set compression=off tank/media
```

## Shares

| Share Name | Path | Protocol | Access |
|------------|------|----------|--------|
| `media` | `/mnt/tank/media` | SMB | Read-only for clients; read-write for admin |
| `downloads` | `/mnt/tank/downloads` | SMB | Read-write for admin |
| `backups` | `/mnt/tank/backups` | SMB | Admin only |

## Snapshot Schedule

Automated snapshots are configured under **Data Protection → Periodic Snapshot Tasks**:

| Dataset | Frequency | Retention |
|---------|-----------|-----------|
| `tank/docker/appdata` | Daily | 14 days |
| `tank/media` | Weekly | 4 weeks |
| `tank/nextcloud` | Daily | 30 days |
| `tank/backups` | Weekly | 8 weeks |
