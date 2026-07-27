#!/usr/bin/env bash
# Nightly backup to S3. Invoked by the lending-backup.timer systemd unit.
#
# `bench backup --with-files` produces a database dump plus public/private
# file tarballs. Retention is enforced by the bucket lifecycle rule in
# Terraform, not here.

set -euo pipefail

APP_DIR=/opt/lending
cd "$APP_DIR"

# shellcheck source=/dev/null
source "$APP_DIR/stack.env"   # ENVIRONMENT, REGION, BACKUP_BUCKET, SITE_NAME

STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
PREFIX="s3://$BACKUP_BUCKET/$ENVIRONMENT/$STAMP"

echo "[backup] creating dump for $SITE_NAME"
docker compose -p lending -f compose.yaml exec -T backend \
  bench --site "$SITE_NAME" backup --with-files

# bench writes into sites/<site>/private/backups inside the sites volume.
BACKUP_SRC="/var/lib/docker/volumes/lending_sites/_data/$SITE_NAME/private/backups"

echo "[backup] uploading newest set to $PREFIX"
find "$BACKUP_SRC" -maxdepth 1 -type f -mmin -30 -print0 \
  | xargs -0 -I{} aws s3 cp --region "$REGION" {} "$PREFIX/"

# Keep the local copy small; S3 is the system of record.
find "$BACKUP_SRC" -maxdepth 1 -type f -mtime +2 -delete

echo "[backup] done"
