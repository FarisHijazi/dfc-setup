#!/bin/bash
# Setup script for the DFC (Distributed Fleet Controller) stack
# Installs all prerequisites and clones all repos
#
# Supports: Ubuntu 22.04+ / Debian 12+
# Run as root or with sudo
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# ============================================================
# 1. System prerequisites
# ============================================================
install_system_deps() {
    log "Installing system dependencies..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq \
        curl wget gnupg lsb-release software-properties-common \
        build-essential git \
        iproute2 arping \
        ca-certificates >/dev/null

    log "System dependencies installed"
}

# ============================================================
# 2. Python 3.12 + 3.13 (some repos need >=3.13)
# ============================================================
install_python() {
    local need_install=false

    if ! command -v python3.12 &>/dev/null; then
        need_install=true
    fi
    if ! command -v python3.13 &>/dev/null; then
        need_install=true
    fi

    if $need_install; then
        log "Installing Python 3.12 and 3.13..."
        add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq \
            python3.12 python3.12-dev python3.12-venv \
            python3.13 python3.13-dev python3.13-venv >/dev/null
        log "Python installed: $(python3.12 --version), $(python3.13 --version)"
    else
        log "Python already installed: $(python3.12 --version), $(python3.13 --version)"
    fi
}

# ============================================================
# 3. uv (Python package manager)
# ============================================================
install_uv() {
    if ! command -v uv &>/dev/null; then
        log "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # Add to PATH for this session
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
        log "uv installed: $(uv --version)"
    else
        log "uv already installed: $(uv --version)"
    fi
}

# ============================================================
# 4. PostgreSQL 16 + TimescaleDB
# ============================================================
install_postgresql() {
    if ! command -v pg_isready &>/dev/null; then
        log "Installing PostgreSQL 16..."
        # Add PostgreSQL apt repo
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
            gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \
            http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        apt-get update -qq
        apt-get install -y -qq postgresql-16 >/dev/null
        log "PostgreSQL 16 installed"
    else
        log "PostgreSQL already installed"
    fi

    # TimescaleDB
    if ! sudo -u postgres psql -c "SELECT 1 FROM pg_available_extensions WHERE name='timescaledb'" -tAq 2>/dev/null | grep -q 1; then
        log "Installing TimescaleDB..."
        # Add TimescaleDB apt repo
        echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/timescaledb.list
        curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | \
            gpg --dearmor -o /usr/share/keyrings/timescaledb-keyring.gpg 2>/dev/null || \
            wget -qO - https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add - 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq timescaledb-2-postgresql-16 2>/dev/null || \
            log "  TimescaleDB package not found, will try extension only"
        # Configure shared_preload_libraries
        PG_CONF=$(sudo -u postgres psql -tAc "SHOW config_file" 2>/dev/null || echo "/etc/postgresql/16/main/postgresql.conf")
        if ! grep -q "timescaledb" "$PG_CONF" 2>/dev/null; then
            echo "shared_preload_libraries = 'timescaledb'" >> "$PG_CONF"
            service postgresql restart 2>/dev/null || pg_ctlcluster 16 main restart 2>/dev/null || true
        fi
        log "TimescaleDB installed"
    else
        log "TimescaleDB already available"
    fi

    # Ensure PostgreSQL is running
    if ! pg_isready -q 2>/dev/null; then
        pg_ctlcluster 16 main start 2>/dev/null || service postgresql start 2>/dev/null || true
    fi

    # Allow local connections without password
    PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file" 2>/dev/null || echo "/etc/postgresql/16/main/pg_hba.conf")
    if ! grep -q "local.*all.*postgres.*trust" "$PG_HBA" 2>/dev/null; then
        # Prepend trust rule for local postgres user
        sed -i '1s/^/local   all   postgres   trust\n/' "$PG_HBA" 2>/dev/null || true
        pg_ctlcluster 16 main reload 2>/dev/null || service postgresql reload 2>/dev/null || true
    fi
}

# ============================================================
# 5. Redis
# ============================================================
install_redis() {
    if ! command -v redis-server &>/dev/null; then
        log "Installing Redis..."
        apt-get install -y -qq redis-server >/dev/null
        log "Redis installed"
    else
        log "Redis already installed"
    fi
}

# ============================================================
# 6. Ray
# ============================================================
install_ray() {
    if ! command -v ray &>/dev/null; then
        log "Installing Ray..."
        pip3 install --break-system-packages "ray[default]==2.49.2" 2>/dev/null || \
            pip3 install "ray[default]==2.49.2"
        log "Ray installed: $(ray --version)"
    else
        log "Ray already installed: $(ray --version)"
    fi
}

# ============================================================
# 7. Clone repos
# ============================================================
clone_repos() {
    # GitHub user and token for private repos
    GH_USER="${GH_USER:-fhijazi-demaenergy}"

    if [ -z "$GH_TOKEN" ]; then
        echo "ERROR: GH_TOKEN environment variable is required for cloning private repos"
        echo "  export GH_TOKEN=github_pat_..."
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

    log "Cloning repos..."
    for repo in "${REPOS[@]}"; do
        if [ -d "$repo" ]; then
            echo "  $repo already exists, pulling latest..."
            (cd "$repo" && git pull --ff-only 2>/dev/null || true)
        else
            echo "  Cloning $repo..."
            git clone "https://x-access-token:${GH_TOKEN}@github.com/${GH_USER}/${repo}.git"
        fi
    done
}

# ============================================================
# 8. Install Python dependencies (uv sync)
# ============================================================
install_deps() {
    log "Installing Python dependencies..."

    # Main service repos
    UV_REPOS=(control-service discovery-service grid-gateway modbus-server telemetry)
    for repo in "${UV_REPOS[@]}"; do
        echo "  Installing $repo..."
        (cd "$repo" && uv sync --no-editable 2>&1 | tail -1)
    done

    # Virtual grid devices — top-level + sub-projects each need their own venv
    echo "  Installing virtual-grid-devices..."
    (cd virtual-grid-devices && uv sync --no-editable 2>&1 | tail -1)
    echo "  Installing virtual-grid-devices/virtual_breaker..."
    (cd virtual-grid-devices/virtual_breaker && uv sync --no-editable 2>&1 | tail -1)
    echo "  Installing virtual-grid-devices/virtual_miner..."
    (cd virtual-grid-devices/virtual_miner && uv sync --no-editable 2>&1 | tail -1)

    log "All dependencies installed"
}

# ============================================================
# 9. Create databases
# ============================================================
setup_databases() {
    log "Setting up databases..."

    # Ensure PostgreSQL is running
    if ! pg_isready -q 2>/dev/null; then
        pg_ctlcluster 16 main start 2>/dev/null || service postgresql start 2>/dev/null || true
        sleep 2
    fi

    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='control'" | grep -q 1 || \
        sudo -u postgres createdb control
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='telemetry'" | grep -q 1 || \
        sudo -u postgres createdb telemetry
    sudo -u postgres psql -d telemetry -c "CREATE EXTENSION IF NOT EXISTS timescaledb" 2>/dev/null || true

    log "Databases ready"
}

# ============================================================
# 10. Run migrations and seed
# ============================================================
run_migrations() {
    log "Running database migrations..."

    DB_USER="${DB_USER:-postgres}"
    DB_PASS="${DB_PASS:-postgres}"
    DB_HOST="${DB_HOST:-localhost}"
    DB_PORT="${DB_PORT:-5432}"

    # Discovery service migrations (alembic.ini is in backend/)
    (cd discovery-service && \
        DATABASE_URL="postgresql+asyncpg://${DB_USER}:${DB_PASS}@${DB_HOST}/control" \
        uv run alembic -c backend/alembic.ini upgrade head 2>&1 | tail -1)

    # Telemetry migrations (env.py reads DATABASE_URL, not individual vars)
    (cd telemetry && \
        DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/telemetry" \
        uv run alembic upgrade head 2>&1 | tail -1)

    log "Migrations complete"
}

seed_fleet() {
    DB_USER="${DB_USER:-postgres}"
    DB_PASS="${DB_PASS:-postgres}"
    DB_HOST="${DB_HOST:-localhost}"

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
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "  DFC Stack Setup (Bare-Metal)"
    echo "========================================"
    echo ""

    install_system_deps
    install_python
    install_uv
    install_postgresql
    install_redis
    install_ray
    clone_repos
    install_deps
    setup_databases
    run_migrations
    seed_fleet

    echo ""
    echo "========================================"
    echo "  Setup complete!"
    echo "========================================"
    echo ""
    echo "To start the stack:"
    echo "  ./run-baremetal.sh start"
    echo ""
    echo "To check status:"
    echo "  ./run-baremetal.sh status"
    echo ""
    echo "To stop:"
    echo "  ./run-baremetal.sh stop"
    echo ""
}

main "$@"
