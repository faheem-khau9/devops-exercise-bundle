variable "cluster_name" {
  type        = string
  description = "Name for the kind cluster. Must be DNS-1123 compatible."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", var.cluster_name)) && length(var.cluster_name) <= 32
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, no leading/trailing hyphens, max 32 chars."
  }
}

variable "node_count" {
  type        = number
  description = "Number of worker nodes (1–5)."
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes node image tag to use (e.g. v1.28.0)."
  default     = "v1.28.0"
}
