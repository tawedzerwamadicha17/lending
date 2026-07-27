#!/usr/bin/env bash
# Roll the stack onto a new image. Executed on the instance by SSM
# Send-Command from the CD workflow; safe to run by hand over SSM Session
# Manager too.
#
#   ./deploy.sh <full-image-uri>
#
# Creates the site on first run, migrates on every subsequent run.

set -euo pipefail

IMAGE="${1:?usage: deploy.sh <image-uri>}"
APP_DIR=/opt/lending
cd "$APP_DIR"

# shellcheck source=/dev/null
source "$APP_DIR/stack.env"   # written by cloud-init: ENVIRONMENT, REGION, SSM_PREFIX, SITE_NAME, ENABLE_TLS, ACME_EMAIL, COMPOSE_PROJECT

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }

fetch_secret() {
  aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/$1" \
    --with-decryption --query Parameter.Value --output text
}

# Exactly one overlay publishes port 80: Traefik when TLS is on, the plain
# host binding otherwise.
COMPOSE_FILES=(-f compose.yaml)
if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
  COMPOSE_FILES+=(-f compose.traefik.yaml)
else
  COMPOSE_FILES+=(-f compose.ports.yaml)
fi
compose() { docker compose -p "$COMPOSE_PROJECT" "${COMPOSE_FILES[@]}" "$@"; }

log "resolving secrets from SSM Parameter Store"
DB_ROOT_PASSWORD="$(fetch_secret db_root_password)"
ADMIN_PASSWORD="$(fetch_secret admin_password)"

# Consumed by compose via the environment, never written to disk.
export IMAGE SITE_NAME DB_ROOT_PASSWORD ACME_EMAIL

log "authenticating to ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${IMAGE%%/*}"

log "pulling $IMAGE"
compose pull --quiet

# --wait blocks until the db healthcheck passes. Without it, compose reports
# success as soon as the container starts, and MariaDB's first-boot
# initialisation takes 20-60s -- long enough for `bench new-site` to fail with
# "Can't connect to server on 'db'".
#
# --no-deps is deliberately NOT used here: it would skip the very
# depends_on/service_healthy conditions that order this correctly.
log "starting data plane"
compose up -d --remove-orphans --wait --wait-timeout 300 db redis-cache redis-queue

# Pulls in configurator via depends_on: service_completed_successfully.
log "starting backend"
compose up -d backend

# Workers must not process jobs against a half-migrated schema.
log "pausing workers for migration"
compose stop scheduler queue-short queue-long 2>/dev/null || true

wait_for_backend() {
  for _ in $(seq 1 30); do
    if compose exec -T backend bash -c 'test -f sites/apps.txt'; then return 0; fi
    sleep 2
  done
  echo "backend never became ready" >&2
  return 1
}
wait_for_backend

# A site is only really present if its database exists too. `bench new-site`
# writes site_config.json before creating the schema, so a run that dies in
# between leaves a directory that looks like a site but has nothing behind it
# -- and keying purely off the config file would send every later deploy down
# the migrate path, failing forever.
site_config_exists() {
  compose exec -T backend bash -c "test -f sites/$SITE_NAME/site_config.json"
}

site_database_exists() {
  local db
  db=$(compose exec -T backend bash -c \
    "python -c \"import json;print(json.load(open('sites/$SITE_NAME/site_config.json'))['db_name'])\"" \
    2>/dev/null | tr -d '\r\n')
  [[ -n "$db" ]] || return 1
  compose exec -T db sh -c \
    "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -N -B -e \"SHOW DATABASES LIKE '$db'\"" \
    2>/dev/null | grep -qx "$db"
}

if site_config_exists && site_database_exists; then
  log "site $SITE_NAME exists -- migrating"
  compose exec -T backend bench --site "$SITE_NAME" migrate
else
  if site_config_exists; then
    # Safe to recreate: the database is absent, so there is nothing to lose.
    # Guarded on that check specifically -- never force when a database is
    # merely unreachable.
    log "site $SITE_NAME has config but no database -- previous creation did not finish; recreating"
    FORCE=--force
  else
    log "site $SITE_NAME not found -- creating (first deploy)"
    FORCE=""
  fi

  # shellcheck disable=SC2086
  compose exec -T backend bench new-site "$SITE_NAME" $FORCE \
    --no-mariadb-socket \
    --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext \
    --install-app lending \
    --set-default
fi

# Converge the installed app set. A site can exist with apps missing -- a
# new-site run that creates the database and then dies partway through
# installing apps leaves exactly that -- and the migrate path alone would
# never notice, silently serving a site without erpnext or lending.
ensure_app() {
  local app="$1"
  if compose exec -T backend bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "$app"; then
    return 0
  fi
  log "installing missing app: $app"
  compose exec -T backend bench --site "$SITE_NAME" install-app "$app"
}

ensure_app erpnext
ensure_app lending

log "starting full stack"
compose up -d

log "reclaiming disk from superseded images"
docker image prune -af --filter "until=168h" >/dev/null

log "deployed $IMAGE to $ENVIRONMENT"
