output "grafana_admin_password" {
  value     = var.enable_monitoring ? random_password.grafana.result : null
  sensitive = true
}
output "namespaces" {
  value = keys(var.environments)
}
