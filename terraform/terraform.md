Deux étapes volontairement séparées (bonne pratique : le cluster doit exister avant de configurer les providers Kubernetes/Helm).

  cd terraform/cluster  && terraform init && terraform apply     # cluster + réseau + registre
  cd terraform/platform && terraform init && terraform apply     # ingress, quotas, supervision

Détruire : platform puis cluster (`terraform destroy`). `./launch.sh infra-up` / `infra-down` le font pour vous.
