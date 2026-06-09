#!/usr/bin/env bash
# Wire ArgoCD repo URLs from tfvars, commit manifest changes, and push to origin.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_DIR="${ENV_DIR:-terraform/envs/local}"
export ENV_DIR

bash "${ROOT_DIR}/scripts/wire-argocd.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not a git repository — clone your public repo before running make apply/verify" >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "error: no git remote 'origin' — add your public repo: git remote add origin <url>" >&2
  exit 1
fi

git add argocd/ helm/ terraform/ scripts/ Makefile README.md

if ! git diff --cached --quiet; then
  git commit -m "chore: sync argocd repo URL and manifests [automated]"
fi

if ! git push -u origin HEAD; then
  echo "error: git push failed — ensure origin is a public repo and push credentials are configured" >&2
  exit 1
fi

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/HEAD 2>/dev/null || git rev-parse "@{u}")"

if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
  echo "error: local HEAD (${LOCAL_HEAD}) does not match remote (${REMOTE_HEAD}) after push" >&2
  exit 1
fi

echo "Synced and pushed ${LOCAL_HEAD} to origin"
