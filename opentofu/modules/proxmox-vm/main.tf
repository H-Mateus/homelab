terraform {
  required_version = ">= 1.9"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.78"
    }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  description = var.description
  tags        = var.tags
  node_name   = var.proxmox_node_name
  vm_id       = var.vm_id

  # Talos has no userland for graceful shutdown signals to act on, so stop
  # rather than ACPI-shutdown on destroy.
  stop_on_destroy = true
  on_boot         = true

  # qemu-guest-agent extension is baked into the Talos image; we can enable
  # the agent and get IPs / clean shutdowns.
  agent {
    enabled = true
    timeout = "5m"
  }

  cpu {
    cores = var.cpu_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  # Boot from disk first; fall back to the Talos ISO on the very first power-on
  # (the disk is empty until Talos installs itself). Once installed the ISO
  # path is never taken again, even if it remains attached.
  boot_order = ["scsi0", "ide3"]

  disk {
    datastore_id = var.disk_datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
    file_format  = "raw"
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  cdrom {
    file_id   = var.iso_file_id
    interface = "ide3"
  }

  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = var.mac_address
  }

  operating_system {
    type = "l26"
  }

  # No `initialization` block: Talos does NOT use cloud-init. Machine
  # configuration is delivered via the talos provider, not Proxmox.

  # Talos manages its own state; ignore changes Proxmox might report after
  # the OS rewrites partition tables on first install.
  lifecycle {
    ignore_changes = [
      cdrom, # post-install we usually want to keep the ISO attached but never re-detect drift on file_id
    ]
  }
}
