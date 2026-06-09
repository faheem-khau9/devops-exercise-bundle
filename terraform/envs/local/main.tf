# ── Cluster ──────────────────────────────────────────────────────────────────

module "cluster" {
  source = "../../modules/kind-cluster"

  cluster_name       = var.cluster_name
  node_count         = var.node_count
  kubernetes_version = var.kubernetes_version
}

# ── Provider configuration (uses the kubeconfig from kind) ───────────────────

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

# ── cert-manager (ArgoCD dependency) ─────────────────────────────────────────

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

# ── Pre-load ArgoCD images into Kind nodes to avoid slow/stuck quay.io pulls ──

resource "null_resource" "preload_argocd_images" {
  triggers = {
    cluster_name  = module.cluster.cluster_name
    argocd_tag    = "v2.10.4"
    redis_tag     = "7.2.4-alpine"
  }

  provisioner "local-exec" {
    command = <<-EOT
      docker pull --platform linux/amd64 quay.io/argoproj/argocd:v2.10.4
      kind load docker-image quay.io/argoproj/argocd:v2.10.4 --name ${module.cluster.cluster_name}
      docker pull --platform linux/amd64 redis:7.2.4-alpine
      kind load docker-image redis:7.2.4-alpine --name ${module.cluster.cluster_name}
    EOT
  }

  depends_on = [module.cluster]
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.3"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [null_resource.helm_repos, helm_release.cert_manager, null_resource.preload_argocd_images]
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

  # bitnami/kubectl was removed from Docker Hub; the cleanupController and its
  # post-upgrade hooks use that image.  Disable the entire controller — it only
  # trims stale admission reports and is not needed for the exercise.
  set {
    name  = "cleanupController.enabled"
    value = "false"
  }

  depends_on = [null_resource.helm_repos]
}

# ── Wait for ArgoCD to be ready before applying CRD resources ────────────────

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

# ── Wait for ESO to be ready ──────────────────────────────────────────────────

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

# ── Wait for Kyverno to be ready ──────────────────────────────────────────────

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

# ── Allow API discovery cache to settle before kubectl_manifest applies ───────

resource "null_resource" "wait_for_crds" {
  triggers = {
    argocd_version = helm_release.argocd.version
    eso_version    = helm_release.external_secrets.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${module.cluster.kubeconfig_path}"
      for crd in clustersecretstores.external-secrets.io externalsecrets.external-secrets.io applications.argoproj.io appprojects.argoproj.io; do
        kubectl wait --for=condition=established --timeout=180s "crd/$crd"
      done
      sleep 10
    EOT
  }

  depends_on = [
    null_resource.wait_for_argocd,
    null_resource.wait_for_eso,
    null_resource.wait_for_kyverno,
  ]
}

# ── ESO: source Secret (acts as the "external" secret store) ─────────────────

resource "kubernetes_secret" "app_secret_source" {
  metadata {
    name      = "app-secret-source"
    namespace = "external-secrets"
  }

  data = {
    app-key = "c2VjcmV0LXZhbHVl" # base64("secret-value") — not a real secret
  }

  depends_on = [helm_release.external_secrets]
}

# ── ESO: ClusterSecretStore + ExternalSecret (via kubectl_manifest to avoid
#    provider REST-mapper cache issues when CRDs are installed in the same apply)

resource "kubernetes_namespace" "sample_app" {
  metadata {
    name = "sample-app"
  }

  depends_on = [module.cluster]
}

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: local-store
    spec:
      provider:
        kubernetes:
          remoteNamespace: external-secrets
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

  depends_on = [null_resource.wait_for_crds]
}

resource "kubectl_manifest" "external_secret" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: sample-app-secret
      namespace: sample-app
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
    kubernetes_namespace.sample_app,
    kubernetes_secret.app_secret_source,
  ]
}

resource "kubernetes_namespace" "sample_app_stage" {
  metadata {
    name = "sample-app-stage"
  }

  depends_on = [module.cluster]
}

resource "kubectl_manifest" "external_secret_stage" {
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
    kubernetes_secret.app_secret_source,
  ]
}

# ── ArgoCD root AppProject + Application (applied via kubectl for same reason) ─

resource "null_resource" "argocd_bootstrap" {
  triggers = {
    argocd_version = helm_release.argocd.version
    git_repo_url   = var.git_repo_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG="${module.cluster.kubeconfig_path}"
      kubectl wait --for=condition=established --timeout=120s crd/appprojects.argoproj.io
      kubectl wait --for=condition=established --timeout=120s crd/applications.argoproj.io

      # Apply root AppProject first (root Application depends on it)
      kubectl apply -f - <<YAML
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

      # Apply sample-app AppProject — child Applications reference project: sample-app
      # This project lives in argocd/projects/ which is outside the root app's watched path,
      # so it must be bootstrapped here rather than discovered by the app-of-apps.
      kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: sample-app
  namespace: argocd
spec:
  description: AppProject for the sample application (local + stage)
  sourceRepos:
    - "${var.git_repo_url}"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: sample-app
    - server: https://kubernetes.default.svc
      namespace: sample-app-stage
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
YAML

      # Apply the root Application (app-of-apps — watches argocd/apps/)
      kubectl apply -f - <<YAML
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
    EOT
  }

  depends_on = [null_resource.wait_for_crds]
}

# ── kyverno-policies ArgoCD Application (via argocd-app module) ──────────────

module "kyverno_policies" {
  source = "../../modules/argocd-app"

  app_name          = "kyverno-policies"
  repo_url          = var.git_repo_url
  chart_path        = "helm/charts/kyverno-policies"
  target_namespace  = "kyverno"
  project_name      = "kyverno-policies"
  helm_release_name = "kyverno-policies"

  ignore_differences = [
    {
      group             = "kyverno.io"
      kind              = "ClusterPolicy"
      jqPathExpressions = [".spec.admission", ".spec.rules[].skipBackgroundRequests"]
    }
  ]

  depends_on = [null_resource.argocd_bootstrap, null_resource.wait_for_kyverno]
}
