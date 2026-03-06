#!/usr/bin/env bash
# DFC Stack Setup Script
# Clones all required repositories and sets up the virtual mining environment.
#
# Usage:
#   GH_TOKEN=<your-github-token> ./setup.sh
#   # or with SSH:
#   USE_SSH=1 ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Configuration ---
ORG="DEMAEnergy"
REPOS=(
  ray-head
  control-service
  discovery-service
  grid-gateway
  modbus-server
  virtual-grid-devices
  telemetry
)

# Fleet generation defaults
BREAKERS=2
TANKS=4
MINERS_PER_TANK=20
MINERS_PER_BREAKER=10
PHASES="6,7,7"
MINER_POWER=3200
MINERS_PER_CONTAINER=40
BASE_BREAKER_IP="192.168.8.100"
BASE_MINER_IP="192.168.8.10"
BREAKER_IP_RANGE="192.168.8.100-101"
MINER_IP_RANGE="192.168.8.10-29"
MACVLAN_PARENT="ens18"
MACVLAN_SUBNET="192.168.8.0/24"
MACVLAN_GATEWAY="192.168.8.1"

# Docker network IPs
export CONTROL_SERVICE_MACVLAN_IP="192.168.8.102"
export DISCOVERY_SERVICE_MACVLAN_IP="192.168.8.103"

# --- Helper functions ---
log() { echo -e "\033[1;34m[setup]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; }
ok()  { echo -e "\033[1;32m[ok]\033[0m $*"; }

clone_repo() {
  local repo="$1"
  if [[ -d "$repo" ]]; then
    log "Directory '$repo' already exists, pulling latest..."
    git -C "$repo" pull --ff-only || log "Pull failed for $repo, continuing with existing checkout"
    return 0
  fi

  if [[ "${USE_SSH:-}" == "1" ]]; then
    local url="git@github.com:${ORG}/${repo}.git"
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    local url="https://x-access-token:${GH_TOKEN}@github.com/${ORG}/${repo}.git"
  else
    local url="https://github.com/${ORG}/${repo}.git"
  fi

  log "Cloning $repo..."
  if ! git clone "$url" "$repo"; then
    err "Failed to clone $repo"
    return 1
  fi
  ok "Cloned $repo"
}

# --- Step 1: Clone all repositories ---
log "=== Step 1: Cloning repositories ==="
FAILED_REPOS=()
for repo in "${REPOS[@]}"; do
  if ! clone_repo "$repo"; then
    FAILED_REPOS+=("$repo")
  fi
done

if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  err "Failed to clone: ${FAILED_REPOS[*]}"
  err "Make sure your GH_TOKEN has access to the $ORG org, or use USE_SSH=1"
  exit 1
fi
ok "All repositories cloned successfully"

# --- Step 2: Install pre-commit hooks (optional) ---
log "=== Step 2: Setting up pre-commit hooks ==="
if command -v uv &>/dev/null; then
  uv tool install pre-commit --with pre-commit-uv --force-reinstall 2>/dev/null || true
  for repo in "${REPOS[@]}"; do
    if [[ -f "$repo/.pre-commit-config.yaml" ]]; then
      log "Installing pre-commit hooks for $repo..."
      (cd "$repo" && uv run pre-commit install --install-hooks 2>/dev/null) || log "Skipping pre-commit for $repo"
    fi
  done
else
  log "uv not found, skipping pre-commit setup"
fi

# --- Step 3: Generate virtual fleet ---
log "=== Step 3: Generating virtual fleet ==="
FLEET_SCRIPT="virtual-grid-devices/scripts/generate_fleet.py"
if [[ -f "$FLEET_SCRIPT" ]]; then
  PYTHON_CMD="python3"
  if command -v uv &>/dev/null; then
    PYTHON_CMD="uv run python"
  fi

  $PYTHON_CMD "$FLEET_SCRIPT" \
    --breakers "$BREAKERS" \
    --tanks "$TANKS" \
    --miners-per-tank "$MINERS_PER_TANK" \
    --miners-per-breaker "$MINERS_PER_BREAKER" \
    --phases "$PHASES" \
    --miner-power "$MINER_POWER" \
    --miners-per-container "$MINERS_PER_CONTAINER" \
    --base-breaker-ip "$BASE_BREAKER_IP" \
    --base-miner-ip "$BASE_MINER_IP" \
    --breaker-ip-range "$BREAKER_IP_RANGE" \
    --miner-ip-range "$MINER_IP_RANGE" \
    --macvlan-parent "$MACVLAN_PARENT" \
    --macvlan-subnet "$MACVLAN_SUBNET" \
    --macvlan-gateway "$MACVLAN_GATEWAY" \
    --output "virtual-grid-devices/docker-compose.yml" \
    --manifest-output "discovery-service/backend/scripts/fleet-manifest.json"

  ok "Virtual fleet generated"
else
  err "Fleet generation script not found at $FLEET_SCRIPT"
  exit 1
fi

# --- Step 4: Start the stack ---
log "=== Step 4: Starting DFC stack ==="
cd "$SCRIPT_DIR/ray-head"

log "Bringing up docker compose..."
docker compose down -v 2>/dev/null || true
docker compose up --build --force-recreate -d

ok "Docker compose started"

# --- Step 5: Verify controller ---
log "=== Step 5: Verifying controller ==="
cd "$SCRIPT_DIR"
bash verify-controller.sh

log "=== Setup complete ==="
echo ""
echo "Dashboard: http://localhost:8265"
echo ""
echo "To view logs:   cd ray-head && docker compose logs -f"
echo "To stop stack:  cd ray-head && docker compose down"
