# DevOps Engineering Exercise

A self-contained local Kubernetes GitOps platform. Everything runs on a single laptop via kind — no cloud account required.

---

## How to Run

### Prerequisites

```bash
# macOS
brew install helm kind kubectl conftest hashicorp/tap/terraform terraform-linters/tap/tflint
pip install checkov
# Docker Desktop / Colima / Rancher Desktop (min 8 GB RAM, 4 CPUs allocated)
```

Minimum versions: Terraform 1.6+, Helm 3.13+, kubectl 1.28+, kind 0.20+, Docker 24+, Conftest 0.46+, Checkov 3.x, tflint 0.50+.

### Quick start

Prerequisites: tools on PATH (see below), Docker with **≥ 8 GB RAM**, and a **public Git remote** (`origin`) with push credentials configured.

```bash
git clone https://github.com/faheem-khau9/devops-exercise-bundle.git
cd devops-exercise-bundle

make apply    # one command: setup → wire argocd URLs → git push → terraform apply
# or
make verify   # setup → sync-git → full 16-check pipeline (auto-destroys on success)
make destroy  # tear down the kind cluster
```

Set `git_repo_url` in `terraform/envs/local/terraform.tfvars` (copied from `.example` on first run). The `scripts/wire-argocd.sh` helper reads that value and updates all `argocd/**/*.yaml` before push — no manual `sed` required.

Use `KEEP=1 make verify` to keep the cluster running after a passing run. Override the environment with `ENV_DIR=terraform/envs/local-stage make apply`.

### Makefile targets

| Target | Effect |
|--------|--------|
| `make setup` | Verify tools on PATH; copy `*.example` → real config files |
| `make sync-git` | Wire `argocd/` URLs from tfvars and push `argocd/` + `helm/` to `origin` |
| `make plan` | `setup` + `terraform plan` in `envs/local` |
| `make apply` | `sync-git` + full cluster bring-up (`terraform apply -parallelism=3`) |
| `make verify` | `sync-git` + 16-check pipeline |
| `make destroy` | Tear down kind cluster |
| `make clean` | Destroy + remove `.terraform/`, lock files, kubeconfigs |

---

## Architecture

### System diagram

```
┌─────────────────────────────────────────────────────────┐
│  kind cluster (local)                                   │
│                                                         │
│  ┌──────────────┐  ┌─────────┐  ┌────────────────────┐ │
│  │    ArgoCD    │  │ Kyverno │  │        ESO         │ │
│  │  (argocd ns) │  │(kyverno)│  │ (external-secrets) │ │
│  └──────┬───────┘  └────┬────┘  └─────────┬──────────┘ │
│         │               │                  │            │
│  ┌──────▼───────────────▼──────────────────▼──────────┐ │
│  │              sample-app namespace                  │ │
│  │   Deployment / Service / ExternalSecret → Secret   │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Bootstrap sequence

1. **Terraform** (`envs/local/`) provisions the kind cluster via the `kind-cluster` module, installs cert-manager, ArgoCD, ESO, and Kyverno as Helm releases with pinned versions.
2. Terraform applies the **root ArgoCD Application** pointing at `argocd/apps/` in this repo.
3. **ArgoCD** (app-of-apps) discovers every YAML under `argocd/apps/` and deploys each Application. Adding a new YAML there is enough for ArgoCD to pick it up on the next sync.
4. ArgoCD deploys `sample-app` and `kyverno-policies` from `helm/charts/`.

### Environments

| Env | Terraform dir | Cluster name | App namespace |
|-----|--------------|--------------|---------------|
| local | `envs/local/` | `devops-exercise` | `sample-app` |
| local-stage | `envs/local-stage/` | `devops-exercise-stage` | `sample-app-stage` |

Both environments call the same two modules with different inputs.

---

## Module Interfaces

### `terraform/modules/kind-cluster/`

| Input | Type | Default | Validation |
|-------|------|---------|------------|
| `cluster_name` | string | — | Lowercase, hyphens only, ≤ 32 chars |
| `node_count` | number | `1` | 1–5 |
| `kubernetes_version` | string | `v1.28.0` | — |

| Output | Description |
|--------|-------------|
| `kubeconfig_path` | Absolute path to kubeconfig (required by harness) |
| `endpoint` | API server URL |
| `cluster_ca_certificate` | PEM CA cert (sensitive) |
| `cluster_name` | Cluster name |

### `terraform/modules/argocd-app/`

Uses `gavinbunney/kubectl` provider — avoids CRD-at-plan-time failures with `hashicorp/kubernetes`.

| Input | Type | Default | Validation |
|-------|------|---------|------------|
| `app_name` | string | — | — |
| `repo_url` | string | — | — |
| `chart_path` | string | — | — |
| `target_namespace` | string | — | Must not be `default` |
| `project_name` | string | — | — |
| `automated_prune` | bool | `true` | — |
| `automated_self_heal` | bool | `true` | — |

| Output | Description |
|--------|-------------|
| `application_name` | ArgoCD Application name |
| `project_name` | AppProject name |
| `target_namespace` | Destination namespace |

---

## Secrets Approach

ESO is installed via Terraform. A `ClusterSecretStore` named `local-store` uses the Kubernetes provider, reading from a source Secret (`app-secret-source`) in the `external-secrets` namespace. `ExternalSecret` resources in `sample-app` and `sample-app-stage` pull `app-key` from that store; ESO creates native `sample-app-secret` Secrets the Deployments mount via `envFrom`.

In production, the `ClusterSecretStore` would point at AWS Secrets Manager (with IRSA) or GCP Secret Manager (with WIF) rather than a local Kubernetes Secret.

No secrets are committed in plaintext. `*.tfvars` and `backend.hcl` are gitignored.

---

## Trade-offs

**Simplified for the time budget:**
- ESO backend is local Kubernetes, not a real cloud secret manager
- Single-node kind cluster; no HA
- No Prometheus/Grafana/alerting stack
- ArgoCD has no SSO — local-only, no OIDC/Dex wired

**Would add next in production:**
- Swap ESO backend to AWS Secrets Manager + IRSA / GCP SM + WIF
- Add Prometheus + Grafana via ArgoCD (another `argocd/apps/` entry)
- Add Dex OIDC to ArgoCD for SSO + RBAC
- Add Renovate / Dependabot for automated chart version bumps
- Add Falco for runtime threat detection
- NetworkPolicies for namespace isolation

---

## AI Tools Used

This submission was built with **Claude Code** (Anthropic, claude-sonnet-4-6) as a pair-programmer.

**What Claude generated:** Boiler plates for Terraform module scaffolding (`kind-cluster`, `argocd-app`, both env compositions), ArgoCD YAML manifests, the `kyverno-policies` Helm chart, GitHub Actions workflow files, and this README structure.

**What was reviewed and adjusted:** All Kyverno `ClusterPolicy` rules were read against the `verify/bad-examples/` manifests to confirm rejection behaviour. The `gavinbunney/kubectl` provider choice was made after understanding the CRD-at-plan-time issue documented in §4.2. The `autogen-controllers: "none"` annotation was added after reading the ArgoCD drift warning in §6.1. The ESO `ClusterSecretStore` auth block was verified against ESO Kubernetes provider docs. Conftest policies were read directly to ensure field names and values matched exactly.

---

## Original bundle README

## Contents

- **`devops-engineer-exercise.pdf`** — the assignment. Read this end-to-end before doing anything else.
- **`helm/charts/sample-app/`** — the Helm chart for the sample application we ship. Wraps `traefik/whoami:v1.10.4`. **Do not modify the chart templates or `values.yaml`.** You write values overlay files next to the chart.
- **`verify/`** — the self-assessment harness:
  - `verify.sh` — orchestrates all 16 checks
  - `preflight.sh` — toolchain version check
  - `policies/` — Conftest `.rego` policies the harness applies to your Terraform plan, ArgoCD Application manifests, and Helm-rendered output. You also author **Kyverno** ClusterPolicies under `helm/charts/kyverno-policies/` (PDF §6.1)
  - `bad-examples/` — pre-seeded manifests that **must** be rejected by your Kyverno policies
- **`terraform/`** — empty scaffold. You write `modules/{kind-cluster,argocd-app}/` and `envs/{local,local-stage}/`.
- **`argocd/`** — empty scaffold. You write `root.yaml`, `projects/*.yaml`, `apps/*.yaml`.
- **`.github/workflows/`** — empty scaffold. You write `terraform-plan.yml`, `policy-test.yml`, `security-scan.yml`.
- **`Makefile`** — top-level entry points (`make setup`, `make verify`, etc.).

## Quick start

1. Read `devops-engineer-exercise.pdf` end-to-end. Sections §3.1–3.3 describe the shipped pieces and the naming requirements the harness depends on.

2. **Extract this bundle to a normal workspace path** — your home directory, project dir, or `~/Desktop`. **Not** `/tmp/`. On macOS, Docker Desktop, Colima, and Rancher Desktop all refuse some bind-mounts from `/tmp/` and the cluster boot will fail with confusing errors. Linux is unaffected.

3. **Allocate enough resources to your Docker runtime.** The local kind cluster runs ~18 pods (cert-manager + ArgoCD + ESO + Kyverno + the sample app). Recommended: 8 GB RAM, 4 CPUs. Docker Desktop defaults of 2 GB will OOM; raise the limit in Docker Desktop > Settings > Resources, or for Colima use `colima start --memory 8 --cpu 4`.

4. Check the toolchain:

   ```bash
   make setup
   ```

   This:
   - Verifies `docker`, `terraform`, `helm`, `kubectl`, `kind`, `conftest`, `checkov`, `tflint` are on `PATH`
   - Copies `*.example` files into their real counterparts (`backend.hcl.example` → `backend.hcl`, `terraform.tfvars.example` → `terraform.tfvars`) so a fresh clone can run `make verify` without manual file copying

   `make setup` does **not** install missing tools — it reports them and exits. Document the install commands in your submitted README.

5. Build your Terraform, ArgoCD wiring, Helm overlays, Kyverno policies, Conftest policies, and CI workflows per the PDF spec.

6. **Push your work to a public Git repository.** ArgoCD pulls your committed manifests over HTTPS; a public repo keeps the local stack credential-free. GitHub or GitLab is fine — any host that serves an HTTPS clone URL with no auth works. Private repos are out of scope; the harness has no credentials path.

   You author the ArgoCD manifests yourself under `argocd/`. While iterating, use the literal placeholder `<YOUR_GIT_REPO_URL>` for every `repoURL` field. When you're ready to verify:

   ```bash
   git init                                  # if not already a repo
   git remote add origin https://github.com/<you>/<repo>.git
   git add . && git commit -m "initial work"
   git push -u origin main

   # Now swap the placeholder for your real URL everywhere under argocd/.
   # macOS / BSD sed:
   find argocd -name '*.yaml' -exec sed -i '' \
     's#<YOUR_GIT_REPO_URL>#https://github.com/<you>/<repo>.git#g' {} +
   # Linux:
   # find argocd -name '*.yaml' -exec sed -i \
   #   's#<YOUR_GIT_REPO_URL>#https://github.com/<you>/<repo>.git#g' {} +

   git add argocd/ && git commit -m "wire argocd repoURL" && git push
   ```

   The harness recursively greps `argocd/` for `<YOUR_GIT_REPO_URL>` and fast-fails check 6 (root Application sync) if any occurrence remains anywhere — including under `argocd/projects/`. ArgoCD pulls the committed state, so unpushed commits are invisible to it.

   **Network requirement:** the kind cluster needs HTTPS egress to your Git host. On a corporate-proxy laptop this may need extra config; check 6 will hang as ArgoCD retries.

7. Run the verification harness:

   ```bash
   make verify
   ```

   Expect `✓ 16/16 checks passed` and exit 0.

   **By default the harness runs `terraform destroy` after a successful run** to clean up. While iterating, use `KEEP=1 make verify` to keep the cluster around so you can poke at it.

8. When you're done:

   ```bash
   make destroy   # tears down the local kind cluster
   ```

## How we evaluate

Primary check is **the output of `make verify`** on a clean clone of your submitted repository. Target: `16/16 checks passed`. Submissions that fail one or two checks will be evaluated case-by-case; submissions that fail many checks will not advance.

We also read the code: see `§13 Evaluation Criteria` in the PDF for the rubric.

## Critical naming requirements (the harness depends on these)

- **ArgoCD Application names** in `argocd/apps/`: `sample-app` (for local env) and `sample-app-stage` (for local-stage env). The Helm release name flows from the Application name, so the rendered Service becomes `svc/sample-app` on port 80 — that's what the harness probes.
- **ArgoCD itself** must be installed in the `argocd` namespace.
- **Sample app namespaces**: `sample-app` and `sample-app-stage` respectively.
- **`repoURL`** in every ArgoCD Application (and the root) must be your public Git repo's HTTPS clone URL (e.g. `https://github.com/<you>/<repo>.git`). The shipped templates use `<YOUR_GIT_REPO_URL>` as a placeholder you replace before pushing.
- **Helm values overlay file**: `helm/charts/sample-app/values.local.yaml` (alongside the shipped chart).
- **Your sample-app Application must include** `syncOptions: ["CreateNamespace=true", "ServerSideApply=true"]` — bad-examples test (check 10) needs the `sample-app` namespace to exist.

Your overlay values must **keep** the chart's defaults for CPU/memory limits, `runAsNonRoot: true`, and a pinned image tag — the shipped Helm-render policy fails if any of these are missing.

- **`terraform/envs/local/` must re-export `kubeconfig_path`** from the kind-cluster module (spec §4.5). The harness reads it via `terraform output -raw kubeconfig_path` to locate the cluster; without it, every kubectl call falls back to `localhost:8080` with confusing errors.

## CRD-at-plan-time gotcha

The official `hashicorp/kubernetes` provider's `kubernetes_manifest` resource validates manifests against the cluster's discovery API at **plan** time. Single-shot `terraform apply` will fail when planning CRD-shaped resources (ArgoCD `Application`, ESO `ClusterSecretStore`, Kyverno `ClusterPolicy`) whose CRDs haven't been installed yet.

**Recommended:** use the `gavinbunney/kubectl` provider's `kubectl_manifest` resource for CRD-shaped objects. It doesn't validate at plan time.

## Required toolchain

| Tool | Min version | Install |
|---|---|---|
| `docker` | 24.x | <https://docs.docker.com/engine/install/> (Colima and Rancher Desktop also work) |
| `terraform` | 1.6 | `brew install hashicorp/tap/terraform` or <https://developer.hashicorp.com/terraform/install> |
| `kind` | 0.20 | `brew install kind` |
| `kubectl` | 1.28 | `brew install kubectl` |
| `helm` | 3.13 | `brew install helm` |
| `conftest` | 0.46 (Rego v1 support) | `brew install conftest` |
| `checkov` | 3.x | `pip install checkov` |
| `tflint` | 0.50 | `brew install terraform-linters/tap/tflint` |

On macOS with Homebrew: `brew install helm kind conftest hashicorp/tap/terraform terraform-linters/tap/tflint && pip install checkov`.

## Required disclosure

Your submitted `README.md` **must** include an "AI tools used" section listing which AI tools you used and what for. The harness greps for this heading (check 14) and fails the run if it's missing. **Omitting it is a fail.**

We're not penalising AI use — we're penalising lack of transparency. See PDF §11.1.

## Submission

Per PDF §12: submit a zip of your working tree including the `.git/` directory, README, Makefile, `verify/`, and a sample `make verify` output. Send to the addresses on the cover page.
