#!/usr/bin/env bash
# Wire git_repo_url from terraform.tfvars into all ArgoCD manifests under argocd/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${ENV_DIR:-terraform/envs/local}"
TFVARS="${ROOT_DIR}/${ENV_DIR}/terraform.tfvars"

if [ ! -f "$TFVARS" ]; then
  echo "error: ${TFVARS} not found — run 'make setup' first" >&2
  exit 1
fi

GIT_REPO_URL="$(grep -E '^[[:space:]]*git_repo_url[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/')"

if [ -z "$GIT_REPO_URL" ]; then
  echo "error: could not parse git_repo_url from ${TFVARS}" >&2
  exit 1
fi

if [ "$GIT_REPO_URL" = "<YOUR_GIT_REPO_URL>" ]; then
  echo "error: git_repo_url in ${TFVARS} is still the placeholder — set your public repo HTTPS URL" >&2
  exit 1
fi

ARGOCD_DIR="${ROOT_DIR}/argocd"
if [ ! -d "$ARGOCD_DIR" ]; then
  echo "error: ${ARGOCD_DIR} not found" >&2
  exit 1
fi

export GIT_REPO_URL

while IFS= read -r -d '' yaml; do
  perl -pi -e '
    my $url = $ENV{GIT_REPO_URL};
    s|^(\s*repoURL:)\s.*|$1 $url|;
    s|^(\s*-)\s*<YOUR_GIT_REPO_URL>.*|$1 $url|;
    s|^(\s*-)\s*https?://\S+|$1 $url|;
  ' "$yaml"
done < <(find "$ARGOCD_DIR" -name '*.yaml' -print0)

echo "Wired ArgoCD manifests to ${GIT_REPO_URL}"
