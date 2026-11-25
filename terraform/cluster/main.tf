# Cluster Kubernetes local (kind = Kubernetes dans Docker) + réseau + registre d'images.
resource "kind_cluster" "helpdesk" {
  name            = var.cluster_name
  node_image      = "kindest/node:${var.k8s_version}"
  wait_for_ready  = true
  kubeconfig_path = "${path.module}/${var.cluster_name}-config"

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # Les nœuds tirent les images "localhost:<port>/..." depuis le registre local (conteneur Docker)
    containerd_config_patches = [
      <<-TOML
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${var.registry_port}"]
        endpoint = ["http://${var.registry_name}:5000"]
      TOML
    ]

    node {
      role = "control-plane"
      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]
      extra_port_mappings {
        container_port = 80
        host_port      = var.http_port
      }
      extra_port_mappings {
        container_port = 443
        host_port      = var.https_port
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}

resource "docker_image" "registry" {
  name         = "registry:2"
  keep_locally = true
}

# Registre d'images (équivalent local d'ACR/GHCR), rattaché au réseau Docker "kind"
resource "docker_container" "registry" {
  name    = var.registry_name
  image   = docker_image.registry.image_id
  restart = "always"

  ports {
    internal = 5000
    external = var.registry_port
    ip       = "127.0.0.1"
  }

  networks_advanced {
    name = "kind"
  }

  depends_on = [kind_cluster.helpdesk]
}
