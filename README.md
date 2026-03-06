# Ray Head Node

Central Ray cluster coordinator for the demaenergy services.

## Cloning repos for the full DFC stack

```sh
# Install pre-commit with uv backend
uv tool install pre-commit --with pre-commit-uv --force-reinstall

# Clone and setup all services
REPOS=(
  git@github.com:DEMAEnergy/ray-head.git
  git@github.com:DEMAEnergy/control-service.git
  git@github.com:DEMAEnergy/discovery-service.git
  git@github.com:DEMAEnergy/grid-gateway.git
  git@github.com:DEMAEnergy/modbus-server.git
  git@github.com:DEMAEnergy/virtual-grid-devices.git
  git@github.com:DEMAEnergy/telemetry.git
)

for url in "${REPOS[@]}"; do
    git clone "$url" &&
    (cd "$(basename "$url" .git)" && uv run pre-commit install --install-hooks) || exit 1
done
```

## Running the DFC Stack

```bash
cd ray-head

# 1. Generate virtual fleet
# NOTE: --miners-per-breaker actually would be 80
python ../virtual-grid-devices/scripts/generate_fleet.py \
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
    --output ../virtual-grid-devices/docker-compose.yml \
    --manifest-output ../discovery-service/backend/scripts/fleet-manifest.json

# 2. Start all services
# set env vars that will be used in docker composes for network ipvlan connections
export CONTROL_SERVICE_MACVLAN_IP=192.168.8.102
export DISCOVERY_SERVICE_MACVLAN_IP=192.168.8.103
docker compose down -v && \
  docker compose up --build --force-recreate -d && \
  docker compose logs -f


# 3. (optional) Setup host access to macvlan network (one-time, requires sudo)
sudo \
  PARENT_IF=ens18 \
  SHIM_IF=macvlan-shim \
  SHIM_IP=192.168.8.199 \
  SUBNET=192.168.8.0/24 \
  ../virtual-grid-devices/scripts/setup-host-access.sh

```

## Dashboard

http://localhost:8265

## Notes

- Must be started before other Ray-dependent services
- Uses tmpfs for `/tmp/ray` to avoid permission issues
- Other services connect via Docker DNS: `ray-head:6380`
