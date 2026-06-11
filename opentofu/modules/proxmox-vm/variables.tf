variable "name" {
  description = "Hostname for the VM (also used as Talos node name)."
  type        = string
}

variable "description" {
  description = "Free-form VM description shown in the Proxmox UI."
  type        = string
  default     = "Talos node, managed by OpenTofu"
}

variable "tags" {
  description = "Proxmox tags."
  type        = list(string)
  default     = ["talos", "tofu"]
}

variable "proxmox_node_name" {
  description = "Proxmox cluster node that will host the VM."
  type        = string
}

variable "vm_id" {
  description = "Numeric Proxmox VMID."
  type        = number
}

variable "cpu_cores" {
  description = "Number of vCPU cores."
  type        = number
}

variable "cpu_type" {
  description = "QEMU CPU type. `host` gives best perf on a single-node lab; `x86-64-v2-AES` is portable across hosts."
  type        = string
  default     = "host"
}

variable "memory_mb" {
  description = "Memory in MiB."
  type        = number
}

variable "disk_gb" {
  description = "Boot/system disk size in GiB."
  type        = number
}

variable "disk_datastore_id" {
  description = "Proxmox datastore for the root disk."
  type        = string
  default     = "local-lvm"
}

variable "iso_file_id" {
  description = "Proxmox file ID of the Talos ISO (e.g. local:iso/talos-v1.13.2-abcd.iso). Output from the talos-image module."
  type        = string
}

variable "network_bridge" {
  description = "Linux bridge the NIC attaches to."
  type        = string
  default     = "vmbr0"
}

variable "mac_address" {
  description = "Static MAC address. Pin this so DHCP reservations / Talos deviceSelector stay stable across rebuilds."
  type        = string
}
