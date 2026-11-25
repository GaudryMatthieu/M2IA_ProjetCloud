variable "cluster_name" {
  type    = string
  default = "helpdesk"
}
variable "k8s_version" {
  description = "Version de l'image kindest/node"
  type        = string
  default     = "v1.30.6"
}
variable "worker_count" {
  type    = number
  default = 2
}
variable "http_port" {
  description = "Port hôte -> Ingress HTTP"
  type        = number
  default     = 8080
}
variable "https_port" {
  description = "Port hôte -> Ingress HTTPS"
  type        = number
  default     = 8443
}
variable "registry_name" {
  type    = string
  default = "kind-registry"
}
variable "registry_port" {
  description = "Port hôte du registre d'images local"
  type        = number
  default     = 5001
}
