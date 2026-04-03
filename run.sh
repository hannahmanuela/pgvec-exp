#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Defaults
RATE=100
DURATION=60
HOST=10.10.1.2
PORT=5432
ROWS=100000
KEEP_DB=false

REMOTE_MACHINE=n0
REMOTE_USER=hmng
REMOTE_DIR="~/pgvec-exp"
OUTDIR="out"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --rate       N     Target requests/sec sent to Postgres (default: $RATE)
  --duration   N     Test duration in seconds (default: $DURATION)
  --host       ADDR  Postgres host (default: $HOST)
  --port       N     Postgres port; also sets the Docker host-side port (default: $PORT)
  --rows       N     Seed row count; skipped if table already has >= N rows (default: $ROWS)
  --keep-db          Do not stop the Docker container after the run
  --help             Show this message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rate)     RATE="$2";     shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --host)     HOST="$2";     shift 2 ;;
    --port)     PORT="$2";     shift 2 ;;
    --rows)     ROWS="$2";     shift 2 ;;
    --keep-db)  KEEP_DB=true;  shift   ;;
    --help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

COMPOSE="docker compose -f $REMOTE_DIR/server/docker-compose.yml"

# ── Build ──────────────────────────────────────────────────────────────────────
echo "==> Building seed binary..."
(cd "$REPO_ROOT/seed"   && GOFLAGS=-mod=mod go build -o "$REPO_ROOT/seed_bin"   .)

echo "==> Building client binary..."
(cd "$REPO_ROOT/client" && GOFLAGS=-mod=mod go build -o "$REPO_ROOT/client_bin" .)

# ── Start Postgres on remote ───────────────────────────────────────────────────
echo "==> Starting pgvector container on $REMOTE_MACHINE (port $PORT)..."
mkdir -p "$REPO_ROOT/$OUTDIR"
ssh $REMOTE_MACHINE "cd $REMOTE_DIR && mkdir -p $OUTDIR"
ssh $REMOTE_MACHINE "cd $REMOTE_DIR && PGPORT=$PORT $COMPOSE up -d --wait"
echo "    Postgres is ready."

# ── Seed ───────────────────────────────────────────────────────────────────────
current_rows=$(
  ssh $REMOTE_MACHINE "PGPORT=$PORT $COMPOSE exec -T pgvec \
    psql -U bench -d benchdb -tAc 'SELECT COUNT(*) FROM items'" 2>/dev/null \
  || echo 0
)
current_rows="${current_rows//[[:space:]]/}"

if [[ "$current_rows" -lt "$ROWS" ]]; then
  echo "==> Seeding ($current_rows rows present, target $ROWS)..."
  "$REPO_ROOT/seed_bin" --host "$HOST" --port "$PORT" --rows "$ROWS"
else
  echo "==> Seed skipped ($current_rows rows already present)."
fi

# ── Start background measurement ───────────────────────────────────────────────
ssh $REMOTE_MACHINE "cd $REMOTE_DIR && (nohup ./utils/build/measure_cpu_util $REMOTE_DIR/$OUTDIR/utils.txt & echo \$! > gen_util.pid) &" &

# ── Run load test ──────────────────────────────────────────────────────────────
echo "==> Running load test: rate=${RATE} req/s, duration=${DURATION}s..."
"$REPO_ROOT/client_bin" \
  --rate     "$RATE" \
  --duration "$DURATION" \
  --host     "$HOST" \
  --port     "$PORT" \
  --out      "$REPO_ROOT/$OUTDIR" \
  | tee "$REPO_ROOT/$OUTDIR/summary.txt"

# ── Collect results ────────────────────────────────────────────────────────────
ssh $REMOTE_MACHINE "sudo kill -9 \$(cat $REMOTE_DIR/gen_util.pid)" || true
scp $REMOTE_USER@$REMOTE_MACHINE:$REMOTE_DIR/$OUTDIR/utils.txt "$REPO_ROOT/$OUTDIR/"

# ── Teardown ───────────────────────────────────────────────────────────────────
if [[ "$KEEP_DB" == "false" ]]; then
  echo "==> Stopping container (data volume retained for next run)..."
  ssh $REMOTE_MACHINE "cd $REMOTE_DIR && PGPORT=$PORT $COMPOSE down"
fi

echo "==> Done. Results in $REPO_ROOT/$OUTDIR/"
