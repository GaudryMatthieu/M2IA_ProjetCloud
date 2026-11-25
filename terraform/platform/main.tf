# ---------- Namespaces applicatifs : séparation dev / prod + quotas ----------
resource "kubernetes_namespace" "env" {
  for_each = var.environments
  metadata {
    name   = each.key
    labels = { "app.kubernetes.io/part-of" = "helpdesk" }
  }
}

resource "kubernetes_resource_quota" "env" {
  for_each = var.environments
  metadata {
    name      = "quota"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = each.value.cpu_requests
      "requests.memory" = each.value.memory_requests
      "limits.cpu"      = each.value.cpu_limits
      "limits.memory"   = each.value.memory_limits
      "pods"            = each.value.pods
    }
  }
}

# Valeurs par défaut pour tout conteneur sans requests/limits (ex : jobs ponctuels)
resource "kubernetes_limit_range" "env" {
  for_each = var.environments
  metadata {
    name      = "defaults"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }
  spec {
    limit {
      type            = "Container"
      default         = { cpu = "300m", memory = "256Mi" }
      default_request = { cpu = "50m", memory = "64Mi" }
    }
  }
}

# ---------- Ingress (entrée réseau HTTP/HTTPS) ----------
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    controller = {
      hostPort     = { enabled = true }
      service      = { type = "NodePort" }
      nodeSelector = { "ingress-ready" = "true" }
      tolerations = [
        { key = "node-role.kubernetes.io/control-plane", operator = "Equal", effect = "NoSchedule" },
        { key = "node-role.kubernetes.io/master", operator = "Equal", effect = "NoSchedule" },
      ]
      publishService = { enabled = false }
      admissionWebhooks = { enabled = false }
    }
  })]
}

# ---------- metrics-server (indispensable à l'autoscaling HPA) ----------
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.2"
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    args = ["--kubelet-insecure-tls", "--kubelet-preferred-address-types=InternalIP"]
  })]
}

# ---------- Observabilité : Prometheus + Grafana + Alertmanager, puis Loki (logs) ----------
resource "kubernetes_namespace" "monitoring" {
  count = var.enable_monitoring ? 1 : 0
  metadata { name = "monitoring" }
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  count      = var.enable_monitoring ? 1 : 0
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "61.9.0"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  timeout    = 900
  wait       = true

  values = [yamlencode({
    # On sélectionne tous les ServiceMonitor / PrometheusRule du cluster (pas seulement ceux du chart)
    prometheus = { prometheusSpec = {
      serviceMonitorSelectorNilUsesHelmValues = false
      ruleSelectorNilUsesHelmValues           = false
      podMonitorSelectorNilUsesHelmValues     = false
      retention                               = "2d"
      resources                               = { requests = { cpu = "200m", memory = "512Mi" }, limits = { memory = "1Gi" } }
    } }
    alertmanager = { alertmanagerSpec = { resources = { requests = { cpu = "20m", memory = "64Mi" } } } }
    grafana = {
      adminPassword = random_password.grafana.result
      sidecar       = { dashboards = { enabled = true, label = "grafana_dashboard", searchNamespace = "ALL" } }
      additionalDataSources = [{
        name = "Loki", uid = "loki", type = "loki", access = "proxy", url = "http://loki.monitoring.svc:3100"
      }]
    }
    # Composants non exposés dans kind
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }
  })]
}

resource "helm_release" "loki_stack" {
  count      = var.enable_monitoring ? 1 : 0
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  version    = "2.10.2"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  wait       = true

  values = [yamlencode({
    loki     = { enabled = true, persistence = { enabled = false } }
    promtail = { enabled = true }
    grafana  = { enabled = false }
  })]
}
