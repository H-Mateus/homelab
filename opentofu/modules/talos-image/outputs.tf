output "schematic_id" {
  description = "Image Factory schematic ID (hash of the extension set)."
  value       = talos_image_factory_schematic.this.id
}

output "iso_file_id" {
  description = "Proxmox file ID for the downloaded ISO, e.g. local:iso/talos-v1.13.2-abcd1234.iso. Feed this to the proxmox-vm module."
  value       = proxmox_download_file.iso.id
}

output "installer_image" {
  description = "The Talos installer image to use in machine.install.image patches. Derived from talos_version; pinning here keeps installer + boot ISO in lockstep."
  value       = "factory.talos.dev/metal-installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"
}
