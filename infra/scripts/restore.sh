#!/usr/bin/env bash
# Restore a site from an S3 backup set. Destructive -- it drops and rebuilds
# the target site's database.
#
#   ./restore.sh 2026-07-27T02-00-00Z
#
# List available sets with:
#   aws s3 ls s3://<bucket>/<environment>/

set -euo pipefail

STAMP="${1:?usage: restore.sh <backup-timestamp>}"
APP_DIR=/opt/lending
cd "$APP_DIR"

# shellcheck source=/dev/null
source "$APP_DIR/stack.env"   # ENVIRONMENT, REGION, BACKUP_BUCKET, SITE_NAME, SSM_PREFIX, COMPOSE_PROJECT

read -rp "This overwrites site $SITE_NAME in $ENVIRONMENT. Type the environment name to confirm: " CONFIRM
[[ "$CONFIRM" == "$ENVIRONMENT" ]] || { echo "aborted"; exit 1; }

compose() { docker compose -p "$COMPOSE_PROJECT" -f compose.yaml "$@"; }

# Stage the download inside the sites volume so the container can see it.
REL_DIR="private/backups/restore-$STAMP"
HOST_DIR="/var/lib/docker/volumes/${COMPOSE_PROJECT}_sites/_data/$SITE_NAME/$REL_DIR"
mkdir -p "$HOST_DIR"
aws s3 cp --region "$REGION" --recursive "s3://$BACKUP_BUCKET/$ENVIRONMENT/$STAMP/" "$HOST_DIR/"

pick() { find "$HOST_DIR" -maxdepth 1 -name "$1" | head -1; }

SQL="$(pick '*-database.sql.gz')"
[[ -n "$SQL" ]] || { echo "no database dump in backup set $STAMP" >&2; exit 1; }

# Paths as the container sees them.
in_site() { echo "sites/$SITE_NAME/$REL_DIR/$(basename "$1")"; }

RESTORE_ARGS=(--force "$(in_site "$SQL")")

PUBLIC="$(pick '*-files.tar')"
[[ -n "$PUBLIC" ]] && RESTORE_ARGS+=(--with-public-files "$(in_site "$PUBLIC")")

PRIVATE="$(pick '*-private-files.tar')"
[[ -n "$PRIVATE" ]] && RESTORE_ARGS+=(--with-private-files "$(in_site "$PRIVATE")")

DB_ROOT_PASSWORD="$(aws ssm get-parameter --region "$REGION" \
  --name "$SSM_PREFIX/db_root_password" --with-decryption \
  --query Parameter.Value --output text)"
RESTORE_ARGS+=(--db-root-password "$DB_ROOT_PASSWORD")

echo "[restore] stopping workers"
compose stop scheduler queue-short queue-long

echo "[restore] restoring $(basename "$SQL")"
compose exec -T backend bench --site "$SITE_NAME" restore "${RESTORE_ARGS[@]}"

echo "[restore] migrating"
compose exec -T backend bench --site "$SITE_NAME" migrate

compose up -d
rm -rf "$HOST_DIR"
echo "[restore] $SITE_NAME restored from $STAMP"
