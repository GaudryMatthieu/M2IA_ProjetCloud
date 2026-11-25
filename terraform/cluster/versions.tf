terraform {
  required_version = ">= 1.5"
  required_providers {
    kind   = { source = "tehcyx/kind", version = "~> 0.5" }
    docker = { source = "kreuzwerker/docker", version = "~> 3.0" }
  }
}

provider "docker" {}
provider "kind" {}
