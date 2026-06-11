variable "talos_version" {
  description = "Talos release tag (e.g. v1.13.2). The installer image used at runtime is derived from this."
  type        = string
}

variable "extensions" {
  description = "Official Talos system extensions to bake into the boot image."
  type        = list(string)
}

variable "proxmox_node_name" {
  description = "Proxmox node where the ISO should be downloaded."
  type        = string
}

variable "iso_datastore_id" {
  description = "Proxmox datastore that holds ISOs (must allow content_type=iso)."
  type        = string
  default     = "local"
}
