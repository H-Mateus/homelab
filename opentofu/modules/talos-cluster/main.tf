terraform {
  required_version = ">= 1.9"
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.11"
    }
  }
}

# ---------------------------------------------------------------------------
# Cluster-wide PKI material. Persisted in state — protect the backend.
# ---------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version_contract
}

# ---------------------------------------------------------------------------
# Split nodes by role for cleaner downstream wiring.
# ---------------------------------------------------------------------------
locals {
  control_plane_nodes = { for k, v in var.nodes : k => v if v.role == "controlplane" }
  worker_nodes        = { for k, v in var.nodes : k => v if v.role == "worker" }

  # The first control plane (alphabetically) is the bootstrap target. Picking
  # a deterministic node avoids "which one did I bootstrap last time?"
  # confusion across re-runs.
  bootstrap_node_key = sort(keys(local.control_plane_nodes))[0]
  bootstrap_node_ip  = local.control_plane_nodes[local.bootstrap_node_key].ip

  control_plane_ips = [for n in values(local.control_plane_nodes) : n.ip]
  worker_ips        = [for n in values(local.worker_nodes) : n.ip]
}

# ---------------------------------------------------------------------------
# Rendered patches, per node. Two patches per node:
#   1. common (hostname, NIC, install disk, VIP on CP)
#   2. tailscale extension config (with secret authkey)
# ---------------------------------------------------------------------------
locals {
  per_node_patches = {
    for k, n in var.nodes : k => [
      templatefile("${path.module}/patches/common.yaml.tftpl", {
        hostname        = n.name
        node_ip         = n.ip
        gateway         = var.gateway
        netmask_bits    = var.netmask_bits
        node_subnet     = var.node_subnet
        dns_servers     = var.dns_servers
        ntp_servers     = var.ntp_servers
        installer_image = var.installer_image
        vip_ip          = n.role == "controlplane" ? var.cluster_vip : null
      }),
      templatefile("${path.module}/patches/tailscale-extension.yaml.tftpl", {
        tailscale_authkey = var.tailscale_authkey
      }),
    ]
  }
}

# ---------------------------------------------------------------------------
# Render machine configs per role. The data source returns the base
# config; per-node patches are applied at apply time.
# ---------------------------------------------------------------------------
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${var.cluster_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version_contract
  kubernetes_version = var.kubernetes_version
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = "https://${var.cluster_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version_contract
  kubernetes_version = var.kubernetes_version
}

# ---------------------------------------------------------------------------
# Apply machine config to each node.
# ---------------------------------------------------------------------------
resource "talos_machine_configuration_apply" "control_plane" {
  for_each = local.control_plane_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value.ip
  config_patches              = local.per_node_patches[each.key]

  # `staged_if_needing_reboot` runs a dry-run first and uses staged mode
  # when the change requires a reboot. Without this, day-2 patches that
  # touch e.g. install.image would reboot etcd members under us.
  apply_mode = "staged_if_needing_reboot"

  timeouts = {
    create = "10m"
    update = "10m"
  }
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = local.worker_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ip
  config_patches              = local.per_node_patches[each.key]

  apply_mode = "staged_if_needing_reboot"

  timeouts = {
    create = "10m"
    update = "10m"
  }
}

# ---------------------------------------------------------------------------
# Bootstrap etcd on the first control plane. Runs exactly once per cluster.
# All other CPs join via the cluster secrets + endpoint.
# ---------------------------------------------------------------------------
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.control_plane]

  node                 = local.bootstrap_node_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  timeouts = {
    create = "10m"
  }
}

# ---------------------------------------------------------------------------
# Wait for the cluster to become healthy. Anything depending on
# `data.talos_cluster_health.this` is guaranteed to see a usable API.
# Hitting the VIP exercises the keepalived election as a side benefit.
# ---------------------------------------------------------------------------
data "talos_cluster_health" "this" {
  depends_on = [
    talos_machine_bootstrap.this,
    talos_machine_configuration_apply.worker,
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.control_plane_ips
  worker_nodes         = local.worker_ips
  endpoints            = [var.cluster_vip]

  timeouts = {
    read = "15m"
  }
}

# ---------------------------------------------------------------------------
# Outputs: kubeconfig + talosconfig.
# ---------------------------------------------------------------------------
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.control_plane_ips
  nodes                = concat(local.control_plane_ips, local.worker_ips)
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [data.talos_cluster_health.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.bootstrap_node_ip
  endpoint             = var.cluster_vip
}
