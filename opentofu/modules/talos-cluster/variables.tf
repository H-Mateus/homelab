variable "cluster_name" {
  description = "Name of the Talos / Kubernetes cluster."
  type        = string
}

variable "talos_version_contract" {
  description = "Talos version contract for config generation (e.g. v1.13). Independent of the installer image — see installer_image."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version to install."
  type        = string
}

variable "installer_image" {
  description = "Full installer image ref including schematic ID, e.g. factory.talos.dev/installer/<schematic>:v1.13.2. From the talos-image module output."
  type        = string
}

variable "cluster_vip" {
  description = "Shared virtual IP for the control plane (Talos native VIP / keepalived). The k8s API endpoint will be https://<vip>:6443."
  type        = string
}

variable "nodes" {
  description = "Map of node key → spec. Key is also used as the hostname in plans."
  type = map(object({
    name = string
    ip   = string
    role = string # "controlplane" or "worker"
  }))

  validation {
    condition     = alltrue([for n in var.nodes : contains(["controlplane", "worker"], n.role)])
    error_message = "Each node.role must be either 'controlplane' or 'worker'."
  }
}

variable "node_subnet" {
  description = "CIDR the kubelet should restrict node IP discovery to (e.g. 192.168.1.0/24)."
  type        = string
}

variable "netmask_bits" {
  description = "Prefix length for the node's interface address (e.g. 24 for /24)."
  type        = number
}

variable "gateway" {
  description = "IPv4 default gateway."
  type        = string
}

variable "dns_servers" {
  description = "DNS resolvers Talos should use on the host."
  type        = list(string)
}

variable "ntp_servers" {
  description = "NTP servers for Talos (chrony)."
  type        = list(string)
  default     = ["0.uk.pool.ntp.org", "1.uk.pool.ntp.org", "2.uk.pool.ntp.org"]
}

variable "tailscale_authkey" {
  description = "Tailscale reusable+ephemeral auth key, tagged tag:k8s-node. Sensitive — passed via SOPS-decrypted variable in the live/ composition."
  type        = string
  sensitive   = true
}
