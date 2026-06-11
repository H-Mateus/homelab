output "cluster_endpoint" {
  description = "Kubernetes API endpoint (VIP-fronted)."
  value       = module.talos_cluster.cluster_endpoint
}

output "control_plane_ips" {
  value = module.talos_cluster.control_plane_ips
}

output "worker_ips" {
  value = module.talos_cluster.worker_ips
}

output "kubeconfig_path" {
  description = "Local path where the kubeconfig was written."
  value       = local_sensitive_file.kubeconfig.filename
}

output "talosconfig_path" {
  description = "Local path where the talosconfig was written."
  value       = local_sensitive_file.talosconfig.filename
}

output "schematic_id" {
  description = "Image Factory schematic ID. Useful to record in PR descriptions when bumping extensions."
  value       = module.talos_image.schematic_id
}
