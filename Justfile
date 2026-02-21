# Fluxer development task runner

set dotenv-load := false

repo_root := justfile_directory()

# Show available commands
default:
    @just --list

# Install dependencies and generate config/secrets
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(mise activate bash)"
    cd "{{repo_root}}"
    echo "Installing dependencies..."
    pnpm install
    ./scripts/dev_bootstrap.sh

# Start infrastructure services (Docker Compose)
infra:
    docker compose -f compose.dev.yaml up -d

# Stop infrastructure services
infra-down:
    docker compose -f compose.dev.yaml down

# Start all application processes (run after `just infra`)
apps:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(mise activate bash)"
    trap 'kill $(jobs -p) 2>/dev/null; wait' EXIT

    cd "{{repo_root}}"
    mkdir -p dev/logs

    export FLUXER_CONFIG="{{repo_root}}/config/config.json"
    export FLUXER_DATABASE="${FLUXER_DATABASE:-sqlite}"

    echo "Starting fluxer_server..."
    pnpm --filter fluxer_server dev > dev/logs/fluxer_server.log 2>&1 &

    echo "Starting fluxer_app..."
    FORCE_COLOR=1 FLUXER_APP_DEV_PORT=49427 pnpm --filter fluxer_app dev > dev/logs/fluxer_app.log 2>&1 &

    echo "Starting fluxer_gateway..."
    ./scripts/dev_gateway.sh > dev/logs/fluxer_gateway.log 2>&1 &

    echo "Starting marketing_dev..."
    FORCE_COLOR=1 pnpm --filter fluxer_marketing dev > dev/logs/marketing_dev.log 2>&1 &

    echo "Starting css_watch..."
    ./scripts/dev_css_watch.sh > dev/logs/css_watch.log 2>&1 &

    echo "Starting caddy..."
    caddy run --config dev/Caddyfile.dev --adapter caddyfile > dev/logs/caddy.log 2>&1 &

    echo "All app processes started. Logs in dev/logs/. Press Ctrl+C to stop."
    wait

# Full dev start: bootstrap + infra + apps
dev: bootstrap infra apps

# Stop everything
down: infra-down

# Cassandra: create migration
cassandra-mig-create name:
    cd {{repo_root}}/fluxer_api && pnpm tsx scripts/CassandraMigrate.tsx create "{{name}}"

# Cassandra: check migrations
cassandra-mig-check:
    cd {{repo_root}}/fluxer_api && pnpm tsx scripts/CassandraMigrate.tsx check

# Cassandra: migration status
cassandra-mig-status host="localhost" user="cassandra" pass="cassandra":
    cd {{repo_root}}/fluxer_api && pnpm tsx scripts/CassandraMigrate.tsx --host "{{host}}" --username "{{user}}" --password "{{pass}}" status

# Cassandra: run migrations up
cassandra-mig-up host="localhost" user="cassandra" pass="cassandra":
    cd {{repo_root}}/fluxer_api && pnpm tsx scripts/CassandraMigrate.tsx --host "{{host}}" --username "{{user}}" --password "{{pass}}" up

# License enforcement check
licence-check:
    cd {{repo_root}}/fluxer_api && pnpm tsx scripts/LicenseEnforcer.tsx

# Sync Python CI dependencies
ci-py-sync:
    cd {{repo_root}}/scripts/ci && uv sync --dev

# Run Python CI tests
ci-py-test:
    cd {{repo_root}}/scripts/ci && uv run pytest
