#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Defaults
RATE=1500
DURATION=60
HOST=10.10.1.2
PORT=5432
ROWS=100000
KEEP_DB=false
PROFILE="std"       # empty = no bg; "std" = pgvec + bg
BG_PORT=3001
NUM_BG=4

RUN_MODE="scx"

REMOTE_MACHINE=n0
REMOTE_USER=hmng
REMOTE_DIR="~/pgvec-exp"
OUTDIR="out/$PROFILE/$RUN_MODE"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --rate       N     Target requests/sec sent to Postgres (default: $RATE)
  --duration   N     Test duration in seconds (default: $DURATION)
  --host       ADDR  Postgres host (default: $HOST)
  --port       N     Postgres port; also sets the Docker host-side port (default: $PORT)
  --rows       N     Seed row count; skipped if table already has >= N rows (default: $ROWS)
  --profile    NAME  Docker Compose profile to activate, e.g. "std" to include bg (default: none)
  --run-mode   MODE  Scheduling mode: "unedited" (default) or "scx" (starts scx_h and moves postgres workers to SCHED_EXT)
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
    --profile)   PROFILE="$2";   shift 2 ;;
    --run-mode)  RUN_MODE="$2";  shift 2 ;;
    --keep-db)   KEEP_DB=true;   shift   ;;
    --help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Build compose command — add --profile only when a profile is set.
COMPOSE="sudo docker compose -f $REMOTE_DIR/server/docker-compose.yml"
if [[ -n "$PROFILE" ]]; then
  COMPOSE="$COMPOSE --profile $PROFILE"
fi

# ── Build ──────────────────────────────────────────────────────────────────────
echo "==> Building seed binary..."
(cd "$REPO_ROOT/seed"   && GOFLAGS=-mod=mod go build -o "$REPO_ROOT/seed_bin"   .)

echo "==> Building client binary..."
(cd "$REPO_ROOT/client" && GOFLAGS=-mod=mod go build -o "$REPO_ROOT/client_bin" .)

# ── Start scx scheduler (scx mode only) ───────────────────────────────────────
if [[ "$RUN_MODE" == "scx" ]]; then
  echo "==> Starting scx_h scheduler on $REMOTE_MACHINE..."
  ssh $REMOTE_MACHINE "cd ~/scx-gw && (nohup sudo ./scx_h  > ~/scx-gw/scx_h.log 2>&1 & echo \$! > sched_ext.pid) &" &

  # ssh $REMOTE_MACHINE "cd ~/scx-gw && (nohup sudo cat /sys/kernel/debug/tracing/trace_pipe > x.txt & echo \$! > cat.pid) && echo 1 | sudo tee /sys/kernel/debug/tracing/tracing_on &" &
fi

# ── Start Postgres on remote ───────────────────────────────────────────────────
echo "==> Starting containers on $REMOTE_MACHINE (profile=${PROFILE:-none}, port=$PORT, mode=$RUN_MODE)..."
mkdir -p "$REPO_ROOT/$OUTDIR"
ssh $REMOTE_MACHINE "cd $REMOTE_DIR && mkdir -p $OUTDIR"
ssh $REMOTE_MACHINE "cd $REMOTE_DIR && PGPORT=$PORT $COMPOSE up -d --wait"
echo "    Containers are ready."

sleep 2

# ── Move postgres workers to SCHED_EXT (scx mode only) ────────────────────────
if [[ "$RUN_MODE" == "scx" ]]; then
  echo "==> Moving postgres workers to SCHED_EXT..."
  ssh $REMOTE_MACHINE "pgrep -x postgres | xargs sudo $REMOTE_DIR/utils/build/set_sched_ext"
fi

sleep 2

# ── Seed ───────────────────────────────────────────────────────────────────────
current_rows=$(
  ssh $REMOTE_MACHINE "PGPORT=$PORT docker compose -f $REMOTE_DIR/server/docker-compose.yml exec -T pgvec \
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

# ── Run load test (background so we can trigger bg workload mid-run) ───────────
echo "==> Running load test: rate=${RATE} req/s, duration=${DURATION}s..."
"$REPO_ROOT/client_bin" \
  --rate     "$RATE" \
  --duration "$DURATION" \
  --host     "$HOST" \
  --port     "$PORT" \
  --out      "$REPO_ROOT/$OUTDIR" \
  > "$REPO_ROOT/$OUTDIR/summary.txt" &
clnt_pid=$!

# ── Trigger bg workload at 5/6 of the run ─────────────────────────────────────
if [[ -n "$PROFILE" ]]; then
  BG_START_OFFSET=$(( DURATION * 5 / 6 ))
  echo "==> Waiting ${BG_START_OFFSET}s before starting bg workload..."
  sleep "$BG_START_OFFSET"

  echo "==> Starting bg ($NUM_BG concurrent /img_resize requests)..."
  date +%s%6N > "$REPO_ROOT/$OUTDIR/bg_start.txt"
  for ((i=1; i<=NUM_BG; i++)); do
    (curl -s "http://$HOST:$BG_PORT/img_resize" > /dev/null && echo "bg $i done") &
  done
fi

wait $clnt_pid
cat "$REPO_ROOT/$OUTDIR/summary.txt"

# ── Collect results ────────────────────────────────────────────────────────────
ssh $REMOTE_MACHINE "sudo kill -9 \$(cat $REMOTE_DIR/gen_util.pid)" || true
scp $REMOTE_USER@$REMOTE_MACHINE:$REMOTE_DIR/$OUTDIR/utils.txt "$REPO_ROOT/$OUTDIR/"

# ── Teardown ───────────────────────────────────────────────────────────────────
if [[ "$KEEP_DB" == "false" ]]; then
  echo "==> Stopping containers (data volume retained for next run)..."
  ssh $REMOTE_MACHINE "cd $REMOTE_DIR && PGPORT=$PORT $COMPOSE down"
fi

if [[ "$RUN_MODE" == "scx" ]]; then
  echo "==> Stopping scx_h scheduler..."
  ssh $REMOTE_MACHINE "sudo kill \$(cat ~/scx-gw/scx_h.pid) 2>/dev/null || true"
  
  # ssh $REMOTE_MACHINE "echo 0 | sudo tee /sys/kernel/debug/tracing/tracing_on"
  # ssh $REMOTE_MACHINE "sudo kill \$(cat ~/scx-gw/cat.pid)"
  # scp $REMOTE_USER@$REMOTE_MACHINE:~/scx-gw/x.txt $OUTDIR
fi

echo "==> Done. Results in $REPO_ROOT/$OUTDIR/"
