variable "cluster_name" {
  type    = string
  default = "devops-exercise"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "kubernetes_version" {
  type    = string
  default = "v1.28.0"
}

variable "git_repo_url" {
  type        = string
  description = "HTTPS URL of the public Git repo ArgoCD syncs from."
  default     = "https://github.com/faheem-khau9/devops-exercise-bundle.git"
}
