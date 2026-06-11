output "kubeconfig" {
  description = "Raw kubeconfig for the new cluster. Write to disk + chmod 600."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Raw talosconfig pointing at all nodes."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (VIP-fronted)."
  value       = "https://${var.cluster_vip}:6443"
}

output "control_plane_ips" {
  description = "Control plane node IPs."
  value       = local.control_plane_ips
}

output "worker_ips" {
  description = "Worker node IPs."
  value       = local.worker_ips
}
