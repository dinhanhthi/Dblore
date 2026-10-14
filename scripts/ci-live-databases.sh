#!/usr/bin/env bash
# Starts or stops the live test databases of the CI integration job.
#
#   scripts/ci-live-databases.sh start postgres mysql
#   scripts/ci-live-databases.sh stop postgres mysql
#
# Runs the docker/*/docker-compose.test.yml files under the compose project "dblore-ci" with
# their own container, volume and network names and their own host ports, so it never touches
# the local test containers (5435, 3307, 3308) on the same Mac. `stop` runs `down -v`: nothing
# is left on the runner. The tests read the ports from TEST_RUNNER_TEST_DB_PORT,
# TEST_RUNNER_TEST_MYSQL_PORT and TEST_RUNNER_TEST_MARIADB_PORT (see ci.yml).
#
# A new service is one start_<name>/stop_<name> pair below plus its name on the command line.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="dblore-ci"

export DBLORE_TEST_NAME_PREFIX="$project"
export DBLORE_PG_TEST_PORT="${DBLORE_PG_TEST_PORT:-15435}"
export DBLORE_MYSQL_TEST_PORT="${DBLORE_MYSQL_TEST_PORT:-13307}"
export DBLORE_MARIADB_TEST_PORT="${DBLORE_MARIADB_TEST_PORT:-13308}"
# Every service file shares the project; the others' containers are not orphans.
export COMPOSE_IGNORE_ORPHANS=1

usage() {
  echo "usage: $0 start|stop postgres|mysql..." >&2
  exit 2
}

compose() {
  local file="$1"
  shift
  docker compose -p "$project" -f "$repo_root/$file" "$@"
}

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "error: Docker is not reachable. Start Docker Desktop (or the Docker daemon) and retry." >&2
    exit 1
  fi
}

require_free_port() {
  local port="$1"
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "error: port $port is already in use; the $project databases need it:" >&2
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
    echo "Free it or pick another port through DBLORE_PG_TEST_PORT / DBLORE_MYSQL_TEST_PORT / DBLORE_MARIADB_TEST_PORT." >&2
    exit 1
  fi
}

# --- postgres: PostgreSQL 16 ------------------------------------------------------------------

postgres_file="docker/postgresql/docker-compose.test.yml"

start_postgres() {
  # Leftovers of a killed run (restart: unless-stopped) would hold the ports; only dblore-ci.
  compose "$postgres_file" down -v
  require_free_port "$DBLORE_PG_TEST_PORT"
  compose "$postgres_file" up -d --wait --wait-timeout 180
}

stop_postgres() {
  compose "$postgres_file" down -v
}

# --- mysql: MySQL 8.4 and MariaDB 11.4 (one compose file) ------------------------------------

mysql_file="docker/mysql/docker-compose.test.yml"

start_mysql() {
  # Leftovers of a killed run (restart: unless-stopped) would hold the ports; only dblore-ci.
  compose "$mysql_file" down -v
  require_free_port "$DBLORE_MYSQL_TEST_PORT"
  require_free_port "$DBLORE_MARIADB_TEST_PORT"
  compose "$mysql_file" up -d --wait --wait-timeout 180
}

stop_mysql() {
  compose "$mysql_file" down -v
}

# ----------------------------------------------------------------------------------------------

[ "$#" -ge 2 ] || usage
action="$1"
shift

for service in "$@"; do
  case "$service" in
    postgres | mysql) ;;
    *)
      echo "error: unknown service '$service' (known: postgres, mysql)" >&2
      exit 2
      ;;
  esac
done

case "$action" in
  start)
    require_docker
    for service in "$@"; do
      echo "Starting $service ($project)..."
      "start_$service"
    done
    ;;
  stop)
    # Runs as an always() step: try every service even when one fails.
    failed=0
    for service in "$@"; do
      echo "Stopping $service ($project)..."
      "stop_$service" || failed=1
    done
    exit "$failed"
    ;;
  *)
    usage
    ;;
esac
