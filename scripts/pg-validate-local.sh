#!/usr/bin/env bash
# Runs the PostgreSQL validation harness locally against a throwaway container.
#
#   ./scripts/pg-validate-local.sh
#   ./scripts/pg-validate-local.sh --only join
#
# Starts (or reuses) a Postgres container, runs `spago test` to emit the corpus,
# then replays it with scripts/validate-sql.mjs. Extra arguments are forwarded
# to the validator. Prefer the Makefile targets: `make validate`, `make sql`.
#
#   SQLD_PG_PORT=55432   host port to bind
#   SQLD_PG_IMAGE        Postgres image (default: postgres:16-alpine)
#   SQLD_PG_STOP=1       remove the container when finished
#   SQLD_SKIP_TEST=1     skip `spago test`, reuse the existing corpus

set -euo pipefail

IMAGE="${SQLD_PG_IMAGE:-postgres:16-alpine}"
PORT="${SQLD_PG_PORT:-55432}"
NAME="sqld-pg-validate"
DB="sqld_validate"

cd "$(dirname "$0")/.."

if ! docker info >/dev/null 2>&1; then
  echo "pg-validate-local: docker is not running" >&2
  exit 1
fi

if [ -z "$(docker ps -q -f "name=^${NAME}$")" ]; then
  # Clear out a stopped container left over from a previous run.
  if [ -n "$(docker ps -aq -f "name=^${NAME}$")" ]; then
    docker rm -f "$NAME" >/dev/null
  fi

  echo "pg-validate-local: starting ${IMAGE} on port ${PORT}"
  docker run -d --rm \
    --name "$NAME" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB="$DB" \
    -p "${PORT}:5432" \
    "$IMAGE" >/dev/null

  # Probe over TCP from the host rather than with `docker exec pg_isready`.
  # The entrypoint runs a temporary server on a Unix socket while it
  # bootstraps, then shuts it down and restarts; an in-container check sees
  # that temporary server and reports ready too early. The temporary server
  # never listens on TCP, so connecting from here cannot race it.
  ready() {
    psql "postgres://postgres:postgres@localhost:${PORT}/${DB}" \
      -X -q -t -c 'SELECT 1' >/dev/null 2>&1
  }

  printf "pg-validate-local: waiting for postgres"
  for _ in $(seq 1 60); do
    if ready; then
      echo " ready"
      break
    fi
    printf "."
    sleep 1
  done

  if ! ready; then
    echo
    echo "pg-validate-local: postgres did not become ready" >&2
    docker logs "$NAME" >&2
    exit 1
  fi
else
  echo "pg-validate-local: reusing running container ${NAME}"
fi

cleanup() {
  if [ "${SQLD_PG_STOP:-0}" = "1" ]; then
    echo "pg-validate-local: removing container ${NAME}"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "${SQLD_SKIP_TEST:-0}" != "1" ]; then
  echo "pg-validate-local: emitting corpus via spago test"
  spago test
fi

export DATABASE_URL="postgres://postgres:postgres@localhost:${PORT}/${DB}"

# Any extra arguments are forwarded to the validator, so --only / --sql work
# through this script too. `|| status=$?` keeps `set -e` from aborting before
# the teardown hint below.
status=0
node scripts/validate-sql.mjs "$@" || status=$?

if [ "${SQLD_PG_STOP:-0}" != "1" ]; then
  echo
  echo "pg-validate-local: container ${NAME} left running (stop it with: docker rm -f ${NAME})"
fi

exit $status
