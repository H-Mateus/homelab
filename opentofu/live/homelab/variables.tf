# -----------------------------------------------------------------------------
# Proxmox
# -----------------------------------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://pve.lan:8006/"
  type        = string
}

variable "proxmox_node_name" {
  description = "Proxmox node hosting the cluster (single-host homelab)."
  type        = string
  default     = "pve"
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (typical for a homelab cert)."
  type        = bool
  default     = true
}

variable "iso_datastore_id" {
  description = "Datastore for ISO storage."
  type        = string
  default     = "local"
}

variable "vm_disk_datastore_id" {
  description = "Datastore for VM root disks."
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Linux bridge VM NICs attach to."
  type        = string
  default     = "vmbr0"
}

# -----------------------------------------------------------------------------
# Talos / Kubernetes
# -----------------------------------------------------------------------------
variable "cluster_name" {
  description = "Cluster name (used in Talos config + as a label)."
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos release tag (drives both boot ISO and installer image)."
  type        = string
  default     = "v1.13.2"
}

variable "talos_version_contract" {
  description = "Talos contract version for config generation. Major.minor only."
  type        = string
  default     = "v1.13"
}

variable "kubernetes_version" {
  description = "Kubernetes version for kubeadm-equivalent layer."
  type        = string
  default     = "v1.34.0"
}

variable "talos_extensions" {
  description = "System extensions baked into the Talos boot image. Mirrors the previous proxmox/schematic.yaml."
  type        = list(string)
  default = [
    "siderolabs/iscsi-tools",
    "siderolabs/qemu-guest-agent",
    "siderolabs/tailscale",
    "siderolabs/util-linux-tools",
  ]
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
variable "node_subnet" {
  description = "Subnet the cluster nodes live in (CIDR)."
  type        = string
  default     = "192.168.1.0/24"
}

variable "netmask_bits" {
  description = "Netmask bits for the node subnet."
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway."
  type        = string
  default     = "192.168.1.1"
}

variable "dns_servers" {
  description = "DNS resolvers (typically AdGuard on TrueNAS over Tailscale; fall back to a public resolver here for bootstrap reachability before Tailnet is up)."
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "cluster_vip" {
  description = "Floating VIP across the 3 control planes. Talos native VIP feature handles election."
  type        = string
}

# -----------------------------------------------------------------------------
# Node sizing — per CLAUDE.md, the Proxmox host is 16GB RAM / 6 cores.
# Defaults sized for 3 CP + 2 worker (14GB / 10 vCPU total — over-subscribed
# on CPU which is fine for an idle homelab).
# -----------------------------------------------------------------------------
variable "control_plane_cpu" {
  type    = number
  default = 2
}

variable "control_plane_memory_mb" {
  type    = number
  default = 2048
}

variable "control_plane_disk_gb" {
  type    = number
  default = 20
}

variable "worker_cpu" {
  type    = number
  default = 2
}

variable "worker_memory_mb" {
  type    = number
  default = 4096
}

variable "worker_disk_gb" {
  type    = number
  default = 40
}

# -----------------------------------------------------------------------------
# Per-node identity
# -----------------------------------------------------------------------------
variable "control_planes" {
  description = "Control plane node specs. Map key is the Talos hostname."
  type = map(object({
    vm_id = number
    ip    = string
    mac   = string
  }))
}

variable "workers" {
  description = "Worker node specs. Map key is the Talos hostname."
  type = map(object({
    vm_id = number
    ip    = string
    mac   = string
  }))
}

# -----------------------------------------------------------------------------
# Local artefact paths
# -----------------------------------------------------------------------------
variable "kubeconfig_path" {
  description = "Where to drop the rendered kubeconfig on disk for kubectl convenience."
  type        = string
  default     = "_generated/kubeconfig"
}

variable "talosconfig_path" {
  description = "Where to drop the rendered talosconfig."
  type        = string
  default     = "_generated/talosconfig"
}
