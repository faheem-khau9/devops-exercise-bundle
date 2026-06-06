output "kubeconfig_path" {
  description = "Absolute path to the kubeconfig file written by the kind provider."
  value       = kind_cluster.this.kubeconfig_path
}

output "endpoint" {
  description = "Kubernetes API server endpoint."
  value       = kind_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "PEM-encoded cluster CA certificate."
  value       = kind_cluster.this.cluster_ca_certificate
  sensitive   = true
}

output "client_certificate" {
  description = "PEM-encoded client certificate for authentication."
  value       = kind_cluster.this.client_certificate
  sensitive   = true
}

output "client_key" {
  description = "PEM-encoded client key for authentication."
  value       = kind_cluster.this.client_key
  sensitive   = true
}

output "cluster_name" {
  description = "The name of the kind cluster."
  value       = kind_cluster.this.name
}
