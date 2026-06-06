output "kubeconfig_path" {
  description = "Path to the kubeconfig for the local-stage kind cluster."
  value       = module.cluster.kubeconfig_path
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.cluster.endpoint
}

output "cluster_name" {
  description = "Name of the kind cluster."
  value       = module.cluster.cluster_name
}
