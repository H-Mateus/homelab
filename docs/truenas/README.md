# TrueNAS SCALE

TrueNAS SCALE is the operating system running the homelab NAS server. It is a Debian-based Linux distribution that combines the ZFS storage technology from TrueNAS CORE with native Linux containerisation capabilities.

## Contents

- [Initial Setup](setup.md)
- [Storage Pools & Datasets](datasets.md)
- [Network Configuration](network.md)

## Key Features in Use

- **ZFS** — Copy-on-write filesystem providing data integrity, compression, and snapshots
- **SMB/NFS shares** — File shares accessed by other machines on the network
- **Docker (via TrueNAS SCALE Apps)** — Containerised services run directly on the TrueNAS host using Docker Compose
- **Scheduled snapshots** — Automated ZFS snapshots for data protection
- **Scrub tasks** — Regular ZFS scrubs to detect and correct data errors

## Administration

The TrueNAS web UI is accessible at `http://<truenas-ip>` on the local network. The admin dashboard provides access to:

- Storage management (pools, datasets, snapshots)
- Network configuration
- Service management
- App/container management
- System settings and updates

## Useful References

- [TrueNAS SCALE Documentation](https://www.truenas.com/docs/scale/)
- [TrueNAS Community Forums](https://forums.truenas.com/)
- [OpenZFS Documentation](https://openzfs.github.io/openzfs-docs/)
