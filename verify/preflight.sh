#!/usr/bin/env bash
# Pre-flight check: verifies the required tools are on PATH at compatible versions
# AND that the Docker runtime has enough memory + CPUs allocated to host the cluster.
# Does NOT install anything — keeps the harness deterministic across machines.

set -uo pipefail

REQUIRED=(docker terraform kind kubectl helm conftest checkov tflint)
MISSING=()
INCOMPATIBLE=()

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "Checking required tools..."
echo

# Version-comparison helper (returns 0 if $1 >= $2)
version_ge() {
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Extract a numeric "X.Y.Z" from a tool's --version output.
extract_version() {
  echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

for tool in "${REQUIRED[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    full=$("$tool" --version 2>&1 | head -1 | tr -d '\n' | head -c 90)
    ver=$(extract_version "$full")
    printf "  ${GREEN}OK${NC}      %-12s  %s\n" "$tool" "$full"

    case "$tool" in
      conftest)
        if [ -n "$ver" ] && ! version_ge "$ver" "0.46.0"; then
          INCOMPATIBLE+=("conftest $ver < 0.46.0 — shipped policies use Rego v1 which older versions don't parse")
        fi
        ;;
      terraform)
        if [ -n "$ver" ] && ! version_ge "$ver" "1.6.0"; then
          INCOMPATIBLE+=("terraform $ver < 1.6.0")
        fi
        ;;
      kind)
        if [ -n "$ver" ] && ! version_ge "$ver" "0.20.0"; then
          INCOMPATIBLE+=("kind $ver < 0.20.0")
        fi
        ;;
    esac
  else
    MISSING+=("$tool")
    printf "  ${RED}MISSING${NC} %-12s  not on PATH\n" "$tool"
  fi
done

echo

# ── Docker resource check ─────────────────────────────────────────────────────
# The cluster runs ~20 pods. Anything less than ~6 GB / 4 CPUs OOMs at apply time.
if command -v docker >/dev/null 2>&1; then
  echo "Checking Docker resource allocation..."
  DOCKER_MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  DOCKER_CPUS=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  DOCKER_MEM_GB=$(awk "BEGIN { printf \"%.1f\", $DOCKER_MEM_BYTES / 1024 / 1024 / 1024 }")

  if [ -n "$DOCKER_MEM_BYTES" ] && [ "$DOCKER_MEM_BYTES" -gt 0 ]; then
    if awk "BEGIN { exit !($DOCKER_MEM_GB < 6.0) }"; then
      printf "  ${RED}LOW${NC}     memory       %s GiB (need >= 6 GiB)\n" "$DOCKER_MEM_GB"
      INCOMPATIBLE+=("Docker has only ${DOCKER_MEM_GB} GiB RAM — cluster will OOM. Increase via Docker Desktop Settings > Resources, or for Colima: 'colima stop && colima start --memory 8 --cpu 4'")
    else
      printf "  ${GREEN}OK${NC}      memory       %s GiB\n" "$DOCKER_MEM_GB"
    fi
  fi

  if [ "$DOCKER_CPUS" -lt 4 ]; then
    printf "  ${RED}LOW${NC}     CPUs         %s (need >= 4)\n" "$DOCKER_CPUS"
    INCOMPATIBLE+=("Docker has only ${DOCKER_CPUS} CPUs — apply will time out under load. Increase via Docker Desktop Settings > Resources, or for Colima: 'colima stop && colima start --memory 8 --cpu 4'")
  else
    printf "  ${GREEN}OK${NC}      CPUs         %s\n" "$DOCKER_CPUS"
  fi
  echo
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
if [ ${#MISSING[@]} -eq 0 ] && [ ${#INCOMPATIBLE[@]} -eq 0 ]; then
  echo -e "${GREEN}All required tools and resources are at compatible levels.${NC}"
  exit 0
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}Missing ${#MISSING[@]} tool(s): ${MISSING[*]}${NC}"
fi
if [ ${#INCOMPATIBLE[@]} -gt 0 ]; then
  echo
  echo -e "${YELLOW}Issues that will prevent a successful run:${NC}"
  for line in "${INCOMPATIBLE[@]}"; do
    echo "  - $line"
  done
fi

echo
echo "Install (macOS, Homebrew):"
echo "  brew install helm kind conftest hashicorp/tap/terraform terraform-linters/tap/tflint"
echo "  pip install checkov"
echo
echo "See README.md for full install instructions."
exit 1
