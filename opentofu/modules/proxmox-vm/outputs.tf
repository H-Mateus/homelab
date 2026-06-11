output "vm_id" {
  description = "Proxmox VMID."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "VM name / hostname."
  value       = proxmox_virtual_environment_vm.this.name
}

output "mac_address" {
  description = "Configured MAC address."
  value       = var.mac_address
}

output "ipv4_addresses" {
  description = "IPv4 addresses reported by qemu-guest-agent (post-first-boot)."
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}
