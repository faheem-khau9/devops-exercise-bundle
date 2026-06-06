output "application_name" {
  description = "Name of the ArgoCD Application created."
  value       = var.app_name
}

output "project_name" {
  description = "Name of the ArgoCD AppProject created."
  value       = var.project_name
}

output "target_namespace" {
  description = "Kubernetes namespace the application deploys into."
  value       = var.target_namespace
}
