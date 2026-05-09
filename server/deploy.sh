#!/bin/bash
# deploy.sh -- One-shot SilentRaven deploy onto an existing
# looter-d4share docker compose project.  Idempotent: safe to re-run.
#
# Steps:
#   1. Copy silentraven_export.py into the upstream app/ dir.
#   2. Run apply_patches.py (idempotent edits to pipeline.py + api.py).
#   3. docker compose up -d --build looter-d4share (recreates container).
#   4. Wait for /health to return 200.
#   5. Run the generator standalone via docker exec so caches.lua is
#      written immediately instead of waiting for the next nightly
#      pipeline run at 02:00 UTC.
#   6. Smoke-test the public endpoint.
#
# Defaults assume the canonical d4data host layout:
#   PROJECT_DIR = /opt/looter-d4share
#   CONTAINER   = looter-d4share
#   API_BASE    = http://127.0.0.1:8002
# Override via env vars if your layout differs.

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/looter-d4share}"
CONTAINER="${CONTAINER:-looter-d4share}"
API_BASE="${API_BASE:-http://127.0.0.1:8002}"

SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "==> SilentRaven server deploy"
echo "    PROJECT_DIR : $PROJECT_DIR"
echo "    CONTAINER   : $CONTAINER"
echo "    API_BASE    : $API_BASE"
echo "    SERVER_DIR  : $SERVER_DIR"
echo

if [[ ! -d "$PROJECT_DIR/app" ]]; then
    echo "ERROR: $PROJECT_DIR/app does not exist." >&2
    echo "       Set PROJECT_DIR to your looter-d4share compose dir." >&2
    exit 1
fi

# 1. Copy generator (always overwrite -- canonical source is this repo).
install -m 0644 "$SERVER_DIR/silentraven_export.py" "$PROJECT_DIR/app/silentraven_export.py"
echo "==> [1/6] copied silentraven_export.py"

# 2. Apply patches (idempotent).
python3 "$SERVER_DIR/apply_patches.py" "$PROJECT_DIR/app"
echo "==> [2/6] applied patches"

# 3. Rebuild + restart the container.
( cd "$PROJECT_DIR" && docker compose up -d --build "$CONTAINER" )
echo "==> [3/6] rebuilt + restarted container"

# 4. Wait for /health.
echo -n "==> [4/6] waiting for /health"
for _ in $(seq 1 30); do
    if curl -fsS "$API_BASE/health" > /dev/null 2>&1; then
        echo " ... up"
        break
    fi
    echo -n "."
    sleep 1
done

# 5. Generate caches.lua immediately.  Standalone exec so we don't have
# to trigger the full nightly pipeline (Wowhead scrape etc.).
echo "==> [5/6] generating caches.lua via standalone exec"
docker exec -e PYTHONPATH=/app "$CONTAINER" python -c \
    'from silentraven_export import generate_silentraven_caches; n = generate_silentraven_caches(); print(f"wrote {n} entries")'

# 6. Smoke test.
echo "==> [6/6] smoke-testing endpoint"
SIZE="$(curl -fsS "$API_BASE/d4/silentraven/caches.lua" | wc -c)"
COUNT="$(curl -fsS "$API_BASE/d4/silentraven/caches.lua" | grep -c '^    \[')"
echo "    served $SIZE bytes, $COUNT entries"

echo
echo "==> done.  Public URL: $API_BASE/d4/silentraven/caches.lua"
