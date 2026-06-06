# ── Cluster ──────────────────────────────────────────────────────────────────

module "cluster" {
  source = "../../modules/kind-cluster"

  cluster_name       = var.cluster_name
  node_count         = var.node_count
  kubernetes_version = var.kubernetes_version
}

# ── Provider configuration ────────────────────────────────────────────────────

provider "helm" {
  kubernetes {
    config_path = module.cluster.kubeconfig_path
  }
}

provider "kubectl" {
  config_path = module.cluster.kubeconfig_path
}

provider "kubernetes" {
  config_path = module.cluster.kubeconfig_path
}

# ── Add Helm repos to local cache (Helm provider requires this) ───────────────

resource "null_resource" "helm_repos" {
  provisioner "local-exec" {
    command = <<-EOT
      helm repo add jetstack https://charts.jetstack.io
      helm repo add argo https://argoproj.github.io/argo-helm
      helm repo add external-secrets https://charts.external-secrets.io
      helm repo add kyverno https://kyverno.github.io/kyverno/
      helm repo update
    EOT
  }

  depends_on = [module.cluster]
}

# ── cert-manager ──────────────────────────────────────────────────────────────

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [null_resource.helm_repos]
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.3"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [null_resource.helm_repos, helm_release.cert_manager]
}

# ── External Secrets Operator ─────────────────────────────────────────────────

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.13"
  namespace        = "external-secrets"
  create_namespace = true

  depends_on = [null_resource.helm_repos]
}

# ── Kyverno ───────────────────────────────────────────────────────────────────

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.1.4"
  namespace        = "kyverno"
  create_namespace = true

  depends_on = [null_resource.helm_repos]
}

# ── Wait for platform components ─────────────────────────────────────────────

resource "null_resource" "wait_for_argocd" {
  triggers = {
    argocd_version = helm_release.argocd.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${module.cluster.kubeconfig_path}"
      kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server
      kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-repo-server
      kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-application-controller 2>/dev/null || \
        kubectl -n argocd wait --for=condition=available --timeout=300s statefulset/argocd-application-controller 2>/dev/null || true
    EOT
  }

  depends_on = [helm_release.argocd]
}

resource "null_resource" "wait_for_eso" {
  triggers = {
    eso_version = helm_release.external_secrets.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${module.cluster.kubeconfig_path}"
      kubectl -n external-secrets wait --for=condition=available --timeout=180s deployment/external-secrets
      kubectl -n external-secrets wait --for=condition=available --timeout=180s deployment/external-secrets-webhook
      kubectl wait --for=condition=established --timeout=120s crd/clustersecretstores.external-secrets.io
      kubectl wait --for=condition=established --timeout=120s crd/externalsecrets.external-secrets.io
    EOT
  }

  depends_on = [helm_release.external_secrets]
}

resource "null_resource" "wait_for_kyverno" {
  triggers = {
    kyverno_version = helm_release.kyverno.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${module.cluster.kubeconfig_path}"
      kubectl -n kyverno wait --for=condition=available --timeout=300s deployment/kyverno-admission-controller
    EOT
  }

  depends_on = [helm_release.kyverno]
}

# ── ESO source Secret ─────────────────────────────────────────────────────────

resource "kubernetes_secret" "app_secret_source" {
  metadata {
    name      = "app-secret-source"
    namespace = "default"
  }

  data = {
    app-key = "c2VjcmV0LXZhbHVl"
  }

  depends_on = [null_resource.helm_repos]
}

# ── ClusterSecretStore ────────────────────────────────────────────────────────

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: local-store
    spec:
      provider:
        kubernetes:
          remoteNamespace: default
          auth:
            serviceAccount:
              name: external-secrets
              namespace: external-secrets
          server:
            url: https://kubernetes.default.svc
            caProvider:
              type: ConfigMap
              name: kube-root-ca.crt
              namespace: default
              key: ca.crt
  YAML

  depends_on = [null_resource.wait_for_eso]
}

# ── ExternalSecret in sample-app-stage namespace ──────────────────────────────

resource "kubernetes_namespace" "sample_app_stage" {
  metadata {
    name = "sample-app-stage"
  }

  depends_on = [null_resource.helm_repos]
}

resource "kubectl_manifest" "external_secret" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: sample-app-secret
      namespace: sample-app-stage
    spec:
      refreshInterval: 1m
      secretStoreRef:
        name: local-store
        kind: ClusterSecretStore
      target:
        name: sample-app-secret
        creationPolicy: Owner
      data:
        - secretKey: app-key
          remoteRef:
            key: app-secret-source
            property: app-key
  YAML

  depends_on = [
    kubectl_manifest.cluster_secret_store,
    kubernetes_namespace.sample_app_stage,
  ]
}

# ── ArgoCD root Application ───────────────────────────────────────────────────

resource "kubectl_manifest" "argocd_root_project" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: root
      namespace: argocd
    spec:
      description: Root app-of-apps project
      sourceRepos:
        - "${var.git_repo_url}"
      destinations:
        - server: https://kubernetes.default.svc
          namespace: argocd
      clusterResourceWhitelist:
        - group: "*"
          kind: "*"
      namespaceResourceWhitelist:
        - group: "*"
          kind: "*"
  YAML

  depends_on = [null_resource.wait_for_argocd]
}

resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: root
      namespace: argocd
    spec:
      project: root
      source:
        repoURL: "${var.git_repo_url}"
        targetRevision: HEAD
        path: argocd/apps
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  YAML

  depends_on = [kubectl_manifest.argocd_root_project]
}
