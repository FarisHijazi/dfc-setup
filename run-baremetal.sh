#!/bin/bash
# Bare-metal launcher for the DFC (Distributed Fleet Controller) stack
# Runs the entire Docker Compose stack natively without Docker
#
# Prerequisites (installed by setup.sh):
#   - PostgreSQL 16 with TimescaleDB extension
#   - Redis server
#   - Ray (pip install "ray[default]==2.49.2")
#   - uv (Python package manager)
#   - Python 3.12 + 3.13
#   - iproute2, arping (for virtual device networking)
#   - All repos cloned and dependencies installed via setup.sh
#
# Usage:
#   ./run-baremetal.sh start    # Start all services
#   ./run-baremetal.sh stop     # Stop all services
#   ./run-baremetal.sh status   # Check service status
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
DB_USER="${DB_USER:-postgres}"
DB_PASS="${DB_PASS:-postgres}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
RAY_HEAD_PORT="${RAY_HEAD_PORT:-6380}"
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
RAY_NUM_CPUS="${RAY_NUM_CPUS:-16}"
RAY_NUM_WORKERS="${RAY_NUM_WORKERS:-2}"

# Virtual device networking (uses loopback 127.0.0.x)
BREAKER_IPS="${BREAKER_IPS:-127.0.0.100,127.0.0.101}"
MINER_IPS_1="${MINER_IPS_1:-127.0.0.10,127.0.0.11,127.0.0.12,127.0.0.13,127.0.0.14,127.0.0.15,127.0.0.16,127.0.0.17,127.0.0.18,127.0.0.19}"
MINER_IPS_2="${MINER_IPS_2:-127.0.0.20,127.0.0.21,127.0.0.22,127.0.0.23,127.0.0.24,127.0.0.25,127.0.0.26,127.0.0.27,127.0.0.28,127.0.0.29}"

LOGDIR="/tmp/dfc-logs"
PIDFILE="$LOGDIR/pids"
mkdir -p "$LOGDIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

save_pid() {
    echo "$1=$2" >> "$PIDFILE"
}

start_services() {
    if [ -f "$PIDFILE" ]; then
        echo "Services may already be running. Run '$0 stop' first."
        exit 1
    fi
    > "$PIDFILE"

    # ---- 1. PostgreSQL ----
    log "Starting PostgreSQL..."
    if ! pg_isready -q 2>/dev/null; then
        pg_ctlcluster 16 main start 2>/dev/null || service postgresql start
    fi
    # Create databases if needed
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='control'" | grep -q 1 || \
        sudo -u postgres createdb control
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='telemetry'" | grep -q 1 || \
        sudo -u postgres createdb telemetry
    # Ensure TimescaleDB extension in telemetry DB
    sudo -u postgres psql -d telemetry -c "CREATE EXTENSION IF NOT EXISTS timescaledb" 2>/dev/null || true
    log "PostgreSQL ready"

    # ---- 2. Redis ----
    log "Starting Redis..."
    if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
        redis-server --daemonize yes --port "$REDIS_PORT"
    fi
    log "Redis ready"

    # ---- 3. Ray Head ----
    log "Starting Ray head node..."
    ray start --head --port="$RAY_HEAD_PORT" \
        --dashboard-host=0.0.0.0 --dashboard-port="$RAY_DASHBOARD_PORT" \
        --num-cpus="$RAY_NUM_CPUS" 2>&1 | tail -2

    # Start Ray workers
    for i in $(seq 1 "$RAY_NUM_WORKERS"); do
        ray start --address="127.0.0.1:$RAY_HEAD_PORT" \
            --object-store-memory=1000000000 2>&1 | tail -1
    done
    log "Ray cluster ready (1 head + $RAY_NUM_WORKERS workers)"

    # ---- 4. Database Migrations ----
    log "Running database migrations..."
    # Discovery service migrations (alembic.ini is in backend/)
    (cd discovery-service && \
        DATABASE_URL="postgresql+asyncpg://${DB_USER}:${DB_PASS}@${DB_HOST}/control" \
        uv run alembic -c backend/alembic.ini upgrade head 2>&1 | tail -1)
    # Telemetry migrations (env.py reads DATABASE_URL, not individual vars)
    (cd telemetry && \
        DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/telemetry" \
        uv run alembic upgrade head 2>&1 | tail -1)
    log "Migrations complete"

    # ---- 5. Seed fleet (if not already seeded) ----
    SEED_COUNT=$(sudo -u postgres psql -d control -tAc "SELECT count(*) FROM devices" 2>/dev/null || echo "0")
    if [ "$SEED_COUNT" = "0" ] || [ "$SEED_COUNT" = "" ]; then
        log "Seeding virtual fleet..."
        (cd discovery-service && \
            DATABASE_URL="postgresql+asyncpg://${DB_USER}:${DB_PASS}@${DB_HOST}/control" \
            uv run python backend/scripts/seed_virtual_fleet.py 2>&1 | tail -3)
        log "Fleet seeded"
    else
        log "Fleet already seeded ($SEED_COUNT devices)"
    fi

    # ---- 6. Virtual Grid Devices ----
    log "Starting virtual breakers..."
    (cd virtual-grid-devices/virtual_breaker && \
        BREAKER_IPS="$BREAKER_IPS" \
        HOSTNAME_PREFIX=breaker \
        BREAKER_VOLTAGE=230 BREAKER_FREQUENCY=50 \
        MINER_TIMEOUT=5.0 NETWORK_INTERFACE=lo \
        PYTHONUNBUFFERED=1 PATH="/usr/sbin:$PATH" \
        uv run python fleet_runner.py > "$LOGDIR/breakers.log" 2>&1 &
        save_pid breakers $!)

    log "Starting virtual miners (fleet 1)..."
    (cd virtual-grid-devices/virtual_miner && \
        MINER_IPS="$MINER_IPS_1" \
        HOSTNAME_PREFIX=miner-1 MINER_POWER=3200 \
        PHASE_DISTRIBUTION=4,3,3 \
        BREAKER_URL=http://127.0.0.100:8000 \
        POWER_PUSH_INTERVAL=1.0 \
        MINER_RAMP_UP_SECONDS=16 MINER_RAMP_DOWN_SECONDS=25 \
        NETWORK_INTERFACE=lo PYTHONUNBUFFERED=1 PATH="/usr/sbin:$PATH" \
        uv run python fleet_runner.py > "$LOGDIR/miners-1.log" 2>&1 &
        save_pid miners1 $!)

    log "Starting virtual miners (fleet 2)..."
    (cd virtual-grid-devices/virtual_miner && \
        MINER_IPS="$MINER_IPS_2" \
        HOSTNAME_PREFIX=miner-2 MINER_POWER=3200 \
        PHASE_DISTRIBUTION=4,3,3 \
        BREAKER_URL=http://127.0.0.101:8000 \
        POWER_PUSH_INTERVAL=1.0 \
        MINER_RAMP_UP_SECONDS=16 MINER_RAMP_DOWN_SECONDS=25 \
        NETWORK_INTERFACE=lo PYTHONUNBUFFERED=1 PATH="/usr/sbin:$PATH" \
        uv run python fleet_runner.py > "$LOGDIR/miners-2.log" 2>&1 &
        save_pid miners2 $!)

    sleep 3
    log "Virtual devices started"

    # ---- 7. Modbus Server ----
    log "Starting Modbus server..."
    (cd modbus-server && \
        MODBUS_HOST=0.0.0.0 MODBUS_PORT=502 \
        FASTAPI_PORT_OFFSET=1 \
        HEARTBEAT_ENABLED=true HEARTBEAT_INTERVAL=0.2 \
        PYTHONUNBUFFERED=1 \
        uv run python -m src.entry.fastapi_entry > "$LOGDIR/modbus.log" 2>&1 &
        save_pid modbus $!)

    # ---- 8. Discovery Service ----
    log "Starting Discovery service..."
    (cd discovery-service && \
        DATABASE_URL="postgresql+asyncpg://${DB_USER}:${DB_PASS}@${DB_HOST}/control" \
        RAY_ADDRESS="ray://127.0.0.1:10001" \
        PYTHONUNBUFFERED=1 \
        uv run uvicorn backend.main:app --host 0.0.0.0 --port 8001 > "$LOGDIR/discovery.log" 2>&1 &
        save_pid discovery $!)

    # ---- 9. Telemetry Consumer ----
    log "Starting Telemetry consumer..."
    (cd telemetry && \
        CONSUMER_CONFIG_PATH=config/consumer.yaml \
        REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" \
        TIMESCALEDB_HOST="$DB_HOST" TIMESCALEDB_PORT="$DB_PORT" \
        TIMESCALEDB_DATABASE=telemetry TIMESCALEDB_USER="$DB_USER" \
        TIMESCALEDB_PASSWORD="$DB_PASS" \
        LOG_LEVEL=INFO PYTHONUNBUFFERED=1 TZ=UTC \
        uv run python -m src.consumer > "$LOGDIR/telemetry-consumer.log" 2>&1 &
        save_pid telemetry_consumer $!)

    # ---- 10. Control Service ----
    log "Starting Control service..."
    (cd control-service && \
        DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}/control" \
        RAY_HEAD_ADDRESS="127.0.0.1" RAY_HEAD_PORT="$RAY_HEAD_PORT" \
        RAY_NAMESPACE="control_service" \
        FLEET_GLOBAL_POWER_LIMIT="300000" FLEET_MONITOR_INTERVAL="1" \
        FLEET_SET_MINERS_TO_SLEEP_ON_STARTUP="true" \
        FLEET_POWER_DISTRIBUTION_STRATEGY="capacity_based" \
        TELEMETRY_ENABLED="true" LOKI_ENABLED="false" \
        RUNNING_IN_DOCKER="false" ENABLE_POWER_SETPOINT="false" \
        PYTHONUNBUFFERED=1 \
        .venv/bin/python -m src.main > "$LOGDIR/control-service.log" 2>&1 &
        save_pid control $!)

    log "Waiting for FleetControllerActor to initialize..."
    sleep 20

    # ---- 11. Telemetry Producer ----
    log "Starting Telemetry producer..."
    (cd telemetry && \
        PYTHONPATH="$(pwd)/.venv/lib/python3.12/site-packages:$(pwd)" \
        PRODUCER_CONFIG_PATH=config/producer.yaml \
        REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" \
        RAY_ADDRESS="auto" LOG_LEVEL=INFO PYTHONUNBUFFERED=1 TZ=UTC \
        /usr/bin/python3.12 -c "
import os, sys, logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
os.environ.pop('RAY_ADDRESS', None)
import ray
ray.init(address='auto', namespace='telemetry', runtime_env={
    'working_dir': '$(pwd)',
    'excludes': ['logs/*', '*.pyc', '__pycache__/*', '.git/*', '.venv/*'],
    'env_vars': {'REDIS_HOST': '$REDIS_HOST', 'REDIS_PORT': '$REDIS_PORT'},
})
os.environ['RAY_ADDRESS'] = 'auto'
from src.producer import load_config, deploy_producer, keep_alive
config = load_config('config/producer.yaml')
deploy_producer(config=config, actor_name=config.actor_name, namespace='telemetry')
keep_alive()
" > "$LOGDIR/telemetry-producer.log" 2>&1 &
        save_pid telemetry_producer $!)

    # ---- 12. Grid Gateway ----
    log "Starting Grid Gateway..."
    (cd grid-gateway && \
        CONTROLLER_NAMESPACE="control_service" \
        CONTROLLER_NAME="fleet_controller" \
        MODBUS_URL="http://127.0.0.1:503" \
        MODBUS_LOOP_INTERVAL="0.2" \
        REGISTER_MAP_FILE="register_map.yaml" \
        TELEMETRY_ENABLED="true" TELEMETRY_NAMESPACE="telemetry" \
        TELEMETRY_ACTOR_NAME="telemetry_actor" \
        LOKI_ENABLED="false" PYTHONUNBUFFERED=1 TZ=UTC \
        .venv/bin/python -c "
import os, sys, signal, time
os.environ.pop('RAY_ADDRESS', None)
sys.path.insert(0, '$(pwd)')
import ray
env_vars = {k: os.environ[k] for k in ['MODBUS_URL', 'MODBUS_LOOP_INTERVAL', 'REGISTER_MAP_FILE',
    'CONTROLLER_NAMESPACE', 'CONTROLLER_NAME', 'TELEMETRY_ENABLED',
    'TELEMETRY_NAMESPACE', 'TELEMETRY_ACTOR_NAME', 'LOKI_ENABLED'] if k in os.environ}
ray.init(address='auto', namespace='control_service', runtime_env={
    'working_dir': '$(pwd)',
    'excludes': ['logs/*', '*.pyc', '__pycache__/*', '.git/*', '.venv/*'],
    'env_vars': env_vars,
})
from src.grid_actor import GridActor
from src.logging_setup import setup_logger
logger = setup_logger()
try:
    existing = ray.get_actor('grid_actor', namespace='control_service')
    ray.kill(existing); time.sleep(1)
except ValueError: pass
handle = GridActor.options(name='grid_actor', namespace='control_service',
    scheduling_strategy=ray.util.scheduling_strategies.NodeAffinitySchedulingStrategy(
        node_id=ray.get_runtime_context().get_node_id(), soft=False)).remote()
ray.get(handle.start.remote())
logger.info('Grid Actor started')
shutdown = False
def handler(sig, frame): global shutdown; shutdown = True
signal.signal(signal.SIGINT, handler); signal.signal(signal.SIGTERM, handler)
while not shutdown: time.sleep(10)
ray.kill(handle)
" > "$LOGDIR/grid-gateway.log" 2>&1 &
        save_pid grid_gateway $!)

    sleep 5
    log "All services started. Logs in $LOGDIR/"
    echo ""
    $0 status
}

stop_services() {
    log "Stopping DFC services..."

    if [ -f "$PIDFILE" ]; then
        # Deduplicate PIDs (keep last entry per name)
        declare -A seen_pids
        while IFS='=' read -r name pid; do
            seen_pids["$name"]="$pid"
        done < "$PIDFILE"

        for name in "${!seen_pids[@]}"; do
            pid="${seen_pids[$name]}"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null && log "Stopped $name (PID $pid)" || true
            fi
        done
        rm -f "$PIDFILE"
    fi

    # Stop Ray
    ray stop 2>/dev/null || true
    log "Ray stopped"

    log "Services stopped. PostgreSQL and Redis left running."
}

check_status() {
    echo "=== DFC Bare-Metal Service Status ==="
    echo ""

    # Infrastructure
    python3.12 -c "
import socket
services = [
    ('PostgreSQL', '127.0.0.1', 5432),
    ('Redis', '127.0.0.1', 6379),
    ('Ray Head', '127.0.0.1', $RAY_HEAD_PORT),
    ('Ray Dashboard', '127.0.0.1', $RAY_DASHBOARD_PORT),
    ('Modbus HTTP', '127.0.0.1', 503),
    ('Discovery Service', '127.0.0.1', 8001),
    ('Breaker 1', '127.0.0.100', 8000),
    ('Breaker 2', '127.0.0.101', 8000),
    ('Miner 1', '127.0.0.10', 8080),
    ('Miner 11', '127.0.0.20', 8080),
]
for name, host, port in services:
    s = socket.socket()
    s.settimeout(1)
    r = s.connect_ex((host, port))
    status = 'OK' if r == 0 else 'DOWN'
    print(f'  {name:25s} {host}:{port:5d}  {status}')
    s.close()
" 2>/dev/null

    echo ""

    # Ray actors
    python3.12 -c "
import ray, os
os.environ.pop('RAY_ADDRESS', None)
ray.init(address='auto', namespace='control_service', ignore_reinit_error=True)
for name in ['fleet_controller', 'grid_actor']:
    try:
        ray.get_actor(name)
        print(f'  {name:25s} OK')
    except: print(f'  {name:25s} DOWN')
ray.shutdown()
ray.init(address='auto', namespace='telemetry', ignore_reinit_error=True)
try:
    ray.get_actor('telemetry_actor')
    print(f'  {\"telemetry_actor\":25s} OK')
except: print(f'  {\"telemetry_actor\":25s} DOWN')
ray.shutdown()
" 2>/dev/null

    echo ""

    # Process status (deduplicated — shows only latest PID per service)
    if [ -f "$PIDFILE" ]; then
        echo "Background processes:"
        declare -A seen_pids
        while IFS='=' read -r name pid; do
            seen_pids["$name"]="$pid"
        done < "$PIDFILE"
        for name in breakers miners1 miners2 modbus discovery telemetry_consumer control telemetry_producer grid_gateway; do
            pid="${seen_pids[$name]:-}"
            if [ -n "$pid" ]; then
                if kill -0 "$pid" 2>/dev/null; then
                    echo "  $name (PID $pid): running"
                else
                    echo "  $name (PID $pid): stopped"
                fi
            fi
        done
    fi

    # Redis stream info
    echo ""
    STREAM_LEN=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" XLEN events 2>/dev/null || echo "N/A")
    echo "Redis stream 'events': $STREAM_LEN messages"
}

case "${1:-}" in
    start)  start_services ;;
    stop)   stop_services ;;
    status) check_status ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
