resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role  = "control-plane"
      image = "kindest/node:${var.kubernetes_version}"
    }

    dynamic "node" {
      for_each = range(var.node_count)
      content {
        role  = "worker"
        image = "kindest/node:${var.kubernetes_version}"
      }
    }
  }
}
