# =============================================================================
# Talos image (schematic + ISO download)
# =============================================================================
module "talos_image" {
  source = "../../modules/talos-image"

  talos_version     = var.talos_version
  extensions        = var.talos_extensions
  proxmox_node_name = var.proxmox_node_name
  iso_datastore_id  = var.iso_datastore_id
}

# =============================================================================
# Proxmox VMs — one module instance per node, fed from var.control_planes +
# var.workers. Keys = Talos hostnames; the map shape is the source of truth.
# =============================================================================
module "control_plane_vm" {
  source = "../../modules/proxmox-vm"

  for_each = var.control_planes

  name              = each.key
  description       = "Talos control plane — managed by OpenTofu"
  tags              = ["talos", "tofu", "controlplane"]
  proxmox_node_name = var.proxmox_node_name
  vm_id             = each.value.vm_id
  cpu_cores         = var.control_plane_cpu
  memory_mb         = var.control_plane_memory_mb
  disk_gb           = var.control_plane_disk_gb
  disk_datastore_id = var.vm_disk_datastore_id
  iso_file_id       = module.talos_image.iso_file_id
  network_bridge    = var.network_bridge
  mac_address       = each.value.mac
}

module "worker_vm" {
  source = "../../modules/proxmox-vm"

  for_each = var.workers

  name              = each.key
  description       = "Talos worker — managed by OpenTofu"
  tags              = ["talos", "tofu", "worker"]
  proxmox_node_name = var.proxmox_node_name
  vm_id             = each.value.vm_id
  cpu_cores         = var.worker_cpu
  memory_mb         = var.worker_memory_mb
  disk_gb           = var.worker_disk_gb
  disk_datastore_id = var.vm_disk_datastore_id
  iso_file_id       = module.talos_image.iso_file_id
  network_bridge    = var.network_bridge
  mac_address       = each.value.mac
}

# =============================================================================
# Talos cluster: secrets, config generation, apply, bootstrap, health.
# `depends_on` on the VM modules makes the dependency explicit — Talos can't
# apply config until the nodes are at least powered on.
# =============================================================================
module "talos_cluster" {
  source = "../../modules/talos-cluster"

  depends_on = [
    module.control_plane_vm,
    module.worker_vm,
  ]

  cluster_name           = var.cluster_name
  talos_version_contract = var.talos_version_contract
  kubernetes_version     = var.kubernetes_version
  installer_image        = module.talos_image.installer_image

  cluster_vip  = var.cluster_vip
  node_subnet  = var.node_subnet
  netmask_bits = var.netmask_bits
  gateway      = var.gateway
  dns_servers  = var.dns_servers

  tailscale_authkey = data.sops_file.secrets.data["tailscale_authkey"]

  nodes = merge(
    { for name, n in var.control_planes : name => { name = name, ip = n.ip, role = "controlplane" } },
    { for name, n in var.workers : name => { name = name, ip = n.ip, role = "worker" } },
  )
}

# =============================================================================
# Drop kubeconfig + talosconfig to disk for `kubectl` / `talosctl` convenience.
# Files are gitignored (_generated/). Sensitive content; 0600 perms.
# =============================================================================
resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/${var.kubeconfig_path}"
  content         = module.talos_cluster.kubeconfig
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  filename        = "${path.module}/${var.talosconfig_path}"
  content         = module.talos_cluster.talosconfig
  file_permission = "0600"
}
