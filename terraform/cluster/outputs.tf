output "kubeconfig_path" {
  value = kind_cluster.helpdesk.kubeconfig_path
}
output "registry" {
  value = "localhost:${var.registry_port}"
}
