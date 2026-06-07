locals {
  release_name = var.helm_release_name != "" ? var.helm_release_name : var.app_name
  source_repos = length(var.project_source_repos) > 0 ? var.project_source_repos : [var.repo_url]
  dest_ns      = length(var.project_destination_namespaces) > 0 ? var.project_destination_namespaces : [var.target_namespace]
}

resource "kubectl_manifest" "app_project" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = var.project_name
      namespace = "argocd"
    }
    spec = {
      description = "AppProject for ${var.app_name}"
      sourceRepos = local.source_repos
      destinations = [
        {
          server    = var.destination_server
          namespace = var.target_namespace
        }
      ]
      clusterResourceWhitelist = [
        { group = "*", kind = "*" }
      ]
      namespaceResourceWhitelist = [
        { group = "*", kind = "*" }
      ]
    }
  })
}

resource "kubectl_manifest" "application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = var.app_name
      namespace = "argocd"
    }
    spec = merge(
      {
        project = var.project_name
        source = merge(
          {
            repoURL        = var.repo_url
            targetRevision = var.source_target_revision
            path           = var.chart_path
          },
          var.values_file != "" ? {
            helm = {
              releaseName = local.release_name
              valueFiles  = [var.values_file]
            }
          } : {}
        )
        destination = {
          server    = var.destination_server
          namespace = var.target_namespace
        }
        syncPolicy = {
          automated = {
            prune    = var.automated_prune
            selfHeal = var.automated_self_heal
          }
          syncOptions = var.sync_options
        }
      },
      length(var.ignore_differences) > 0 ? {
        ignoreDifferences = var.ignore_differences
      } : {}
    )
  })

  depends_on = [kubectl_manifest.app_project]
}
