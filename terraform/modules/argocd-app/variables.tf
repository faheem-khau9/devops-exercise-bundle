variable "app_name" {
  type        = string
  description = "Name for the ArgoCD Application and AppProject."
}

variable "repo_url" {
  type        = string
  description = "HTTPS URL of the Git repository ArgoCD will sync from."
}

variable "chart_path" {
  type        = string
  description = "Path within the repo to the Helm chart or plain YAML directory."
}

variable "target_namespace" {
  type        = string
  description = "Kubernetes namespace to deploy into. Must not be 'default'."

  validation {
    condition     = var.target_namespace != "default"
    error_message = "target_namespace must not be 'default' — use a dedicated namespace."
  }
}

variable "project_name" {
  type        = string
  description = "ArgoCD AppProject name to assign this Application to."
}

variable "values_file" {
  type        = string
  description = "Relative path (from repo root) to the Helm values overlay file."
  default     = ""
}

variable "automated_prune" {
  type        = bool
  description = "Enable automated pruning of resources removed from Git."
  default     = true
}

variable "automated_self_heal" {
  type        = bool
  description = "Enable automated self-healing of drift between live state and Git."
  default     = true
}

variable "sync_options" {
  type        = list(string)
  description = "Additional ArgoCD sync options."
  default     = ["CreateNamespace=true", "ServerSideApply=true"]
}

variable "destination_server" {
  type        = string
  description = "Kubernetes API server URL for the destination cluster."
  default     = "https://kubernetes.default.svc"
}

variable "source_target_revision" {
  type        = string
  description = "Git branch, tag, or commit SHA to sync from."
  default     = "HEAD"
}

variable "helm_release_name" {
  type        = string
  description = "Override the Helm release name (defaults to app_name)."
  default     = ""
}

variable "project_source_repos" {
  type        = list(string)
  description = "Source repos the AppProject allows. Defaults to the app repo."
  default     = []
}

variable "project_destination_namespaces" {
  type        = list(string)
  description = "Namespaces the AppProject allows as destinations."
  default     = []
}
