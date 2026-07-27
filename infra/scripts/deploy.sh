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

# Bring data services up first so migrate has something to talk to.
log "starting data plane"
compose up -d --remove-orphans db redis-cache redis-queue
compose up -d --no-deps configurator
compose up -d --no-deps backend

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

if compose exec -T backend bash -c "test -f sites/$SITE_NAME/site_config.json"; then
  log "site $SITE_NAME exists -- migrating"
  compose exec -T backend bench --site "$SITE_NAME" migrate
else
  log "site $SITE_NAME not found -- creating (first deploy)"
  compose exec -T backend bench new-site "$SITE_NAME" \
    --no-mariadb-socket \
    --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext \
    --install-app lending \
    --set-default
fi

log "starting full stack"
compose up -d

log "reclaiming disk from superseded images"
docker image prune -af --filter "until=168h" >/dev/null

log "deployed $IMAGE to $ENVIRONMENT"
