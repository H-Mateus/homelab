terraform {
  required_version = ">= 1.9"
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.11"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.78"
    }
  }
}

# Resolve a schematic ID from the requested extensions. The Image Factory
# returns a stable hash so re-runs are idempotent as long as the schematic
# body is unchanged.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.extensions
      }
    }
  })
}

# Push the metal ISO from factory.talos.dev into a Proxmox ISO datastore.
# The URL embeds the schematic ID, so bumping `extensions` rebuilds the
# image transparently.
resource "proxmox_download_file" "iso" {
  content_type = "iso"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node_name
  file_name    = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}.iso"
  url          = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/metal-amd64.iso"
  overwrite    = false
}
