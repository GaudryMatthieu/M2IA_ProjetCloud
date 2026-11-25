variable "kubeconfig_path" {
  type    = string
  default = "../cluster/helpdesk-config"
}
variable "cluster_name" {
  type    = string
  default = "helpdesk"
}
variable "enable_monitoring" {
  description = "Installe Prometheus + Grafana + Loki (≈ 2 Go de RAM). Mettre false sur une petite machine."
  type        = bool
  default     = true
}
variable "environments" {
  description = "Un namespace par environnement (A.8.31) avec quotas (FinOps)"
  type = map(object({
    cpu_requests    = string
    memory_requests = string
    cpu_limits      = string
    memory_limits   = string
    pods            = string
  }))
  default = {
    "helpdesk-dev"  = { cpu_requests = "2", memory_requests = "3Gi", cpu_limits = "6", memory_limits = "5Gi", pods = "30" }
    "helpdesk-prod" = { cpu_requests = "3", memory_requests = "4Gi", cpu_limits = "8", memory_limits = "6Gi", pods = "40" }
  }
}
