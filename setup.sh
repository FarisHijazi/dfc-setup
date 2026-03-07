#!/bin/bash
# Setup script for the DFC (Distributed Fleet Controller) stack
# Clones all repos and installs dependencies
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# GitHub user and token for private repos
GH_USER="${GH_USER:-fhijazi-demaenergy}"

if [ -z "$GH_TOKEN" ]; then
    echo "ERROR: GH_TOKEN environment variable is required for cloning private repos"
    exit 1
fi

REPOS=(
    ray-head
    control-service
    discovery-service
    grid-gateway
    modbus-server
    virtual-grid-devices
    telemetry
)

echo "=== Cloning repos ==="
for repo in "${REPOS[@]}"; do
    if [ -d "$repo" ]; then
        echo "  $repo already exists, skipping clone"
    else
        echo "  Cloning $repo..."
        git clone "https://x-access-token:${GH_TOKEN}@github.com/${GH_USER}/${repo}.git"
    fi
done

echo ""
echo "=== Installing dependencies ==="

# Repos with pyproject.toml that need uv sync
UV_REPOS=(control-service discovery-service grid-gateway modbus-server virtual-grid-devices telemetry)

for repo in "${UV_REPOS[@]}"; do
    echo "  Installing $repo..."
    (cd "$repo" && uv sync --no-editable 2>&1 | tail -1)
done

echo ""
echo "=== Generating virtual fleet ==="
python3 virtual-grid-devices/scripts/generate_fleet.py \
    --breakers 2 \
    --tanks 4 \
    --miners-per-tank 20 \
    --miners-per-breaker 10 \
    --phases 6,7,7 \
    --miner-power 3200 \
    --miners-per-container 40 \
    --base-breaker-ip 192.168.8.100 \
    --base-miner-ip 192.168.8.10 \
    --breaker-ip-range 192.168.8.100-101 \
    --miner-ip-range 192.168.8.10-29 \
    --macvlan-parent ens18 \
    --macvlan-subnet 192.168.8.0/24 \
    --macvlan-gateway 192.168.8.1 \
    --output virtual-grid-devices/docker-compose.yml \
    --manifest-output discovery-service/backend/scripts/fleet-manifest.json

echo ""
echo "=== Setup complete ==="
echo ""
echo "To start the stack:"
echo "  cd ray-head"
echo "  export CONTROL_SERVICE_MACVLAN_IP=192.168.8.102"
echo "  export DISCOVERY_SERVICE_MACVLAN_IP=192.168.8.103"
echo "  docker compose up --build -d"
echo ""
echo "Dashboard: http://localhost:8265"
