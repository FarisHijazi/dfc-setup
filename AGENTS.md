# AGENTS.md

## Cursor Cloud specific instructions

### Architecture Overview

This repo (`ray-head`) is the orchestrator for the **DFC (Distributed Fleet Controller)** stack -- an energy fleet management system that controls virtual/real cryptocurrency miners via Ray actors, Modbus, and PostgreSQL. It is a multi-repo system; the sibling repos are cloned into `/dfc/`:

| Repo | Purpose |
|---|---|
| `ray-head` (this repo, `/workspace`) | Orchestrator, `docker-compose.yml` |
| `control-service` (`/dfc/control-service`) | Fleet controller Ray actor |
| `discovery-service` (`/dfc/discovery-service`) | Device registration FastAPI (port 8001) |
| `grid-gateway` (`/dfc/grid-gateway`) | Modbus <-> Ray bridge |
| `modbus-server` (`/dfc/modbus-server`) | Modbus TCP server (ports 502/503) |
| `virtual-grid-devices` (`/dfc/virtual-grid-devices`) | Simulated breakers and miners |
| `telemetry` (`/dfc/telemetry`) | Redis Streams telemetry pipeline |

### Running the Stack

The entire stack runs via Docker Compose from `/workspace`:

```bash
cd /workspace
sudo docker compose up -d --build
sudo docker compose logs -f
sudo docker compose down -v   # full teardown with volumes
```

Key ports: Ray Dashboard `:8265`, Discovery API `:8001`, Modbus HTTP `:503`, Modbus TCP `:502`, PostgreSQL `:5432`.

### Important Gotchas

- **discovery-service branch**: Must use `origin/feat/add-cooling-tables` branch (checked out in `/dfc/discovery-service`) because the control-service requires a `tanks` table that only exists in that branch's migration.
- **control-service Dockerfile**: The stock Dockerfile uses `uv sync` which creates a `.venv` incompatible with Ray's base image. The fix is to use `uv pip install --system` instead (already applied in `/dfc/control-service/Dockerfile`). If the Dockerfile is overwritten by a pull, re-apply.
- **Docker in Docker**: This environment runs Docker inside Firecracker. Uses `fuse-overlayfs` storage driver and `iptables-legacy`. Docker daemon started via `sudo dockerd`.
- **Host PostgreSQL/Redis conflict**: The host-installed PostgreSQL and Redis must be stopped before running docker compose (they bind the same ports). Run `sudo service postgresql stop` before `docker compose up`.
- **Linting**: `ruff` is installed globally via `uv tool install ruff`. All repos use ruff for linting. Run `ruff check src/` from each repo.
- **Tests**: Some repos have pre-existing test dependency issues (e.g., `loki_logger_handler` missing in modbus-server). The grid-gateway integration tests require a running Ray cluster.
