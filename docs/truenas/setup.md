# TrueNAS SCALE – Initial Setup

Notes on the initial installation and configuration of the TrueNAS SCALE server.

## Installation

1. Download the latest TrueNAS SCALE ISO from [truenas.com](https://www.truenas.com/download-truenas-scale/).
2. Write the ISO to a USB drive (e.g. with [Balena Etcher](https://etcher.balena.io/)).
3. Boot the server from the USB drive.
4. Follow the installer prompts:
   - Select the boot device (a dedicated SSD/USB is recommended — **not** a data drive).
   - Set the root/admin password.
5. After installation, access the web UI from another machine at `http://<truenas-ip>`.

## First-Boot Configuration Checklist

- [ ] Change the admin password if not set during installation.
- [ ] Configure a static IP address (see [Network Configuration](network.md)).
- [ ] Set the correct timezone under **System → General**.
- [ ] Configure NTP servers under **System → General**.
- [ ] Create a storage pool (see [Datasets](datasets.md)).
- [ ] Enable email alerts under **System → Alert Settings**.
- [ ] Set up an SSH key pair for CLI access.
- [ ] Schedule regular ZFS scrubs under **Data Protection → Scrub Tasks**.
- [ ] Configure automatic snapshots under **Data Protection → Periodic Snapshot Tasks**.
- [ ] Enable S.M.A.R.T. tests under **Data Protection → S.M.A.R.T. Tests**.

## SSH Access

SSH is enabled via **System → Services → SSH**. It is recommended to:

- Disable root login (`PermitRootLogin no` in the SSH service settings).
- Use key-based authentication only (disable password authentication).
- Add your public key under **Credentials → Local Users → admin → Edit → SSH Public Key**.

## Updates

TrueNAS SCALE receives regular updates. To update:

1. Go to **System → Update**.
2. Check for available updates.
3. Review release notes before applying.
4. It is good practice to take a ZFS snapshot before a major update.

> **Note:** Major version upgrades (e.g. Dragonfish → Electric Eel) may require extra steps. Always consult the release notes.

## Docker / App Configuration

TrueNAS SCALE supports running Docker containers natively. To use custom Docker Compose stacks:

1. Enable the **Apps** service under **Apps → Configuration**.
2. Choose a dataset for Docker storage (see [Datasets](datasets.md)).
3. Deploy stacks using the Compose files in the [`docker/`](../../docker/) directory.
   Compose files can be placed on a TrueNAS dataset and run with:
   ```bash
   docker compose -f /mnt/<pool>/docker/compose/<stack>/docker-compose.yml up -d
   ```
