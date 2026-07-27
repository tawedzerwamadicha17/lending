#!/usr/bin/env bash
# docker compose wrapper for this stack.
#
#   sudo /opt/lending/stack.sh ps
#   sudo /opt/lending/stack.sh logs -f backend
#   sudo /opt/lending/stack.sh restart scheduler
#
# compose.yaml requires IMAGE, SITE_NAME and DB_ROOT_PASSWORD to be set, so a
# bare `docker compose ps` fails with "required variable ... is missing a
# value". This supplies them: the site config from stack.env, the image from
# whatever is currently running, and the database password from SSM at the
# moment it is needed -- it is never written to disk.

set -euo pipefail
cd /opt/lending

# set -a exports everything sourced, which is what compose interpolation needs.
set -a
# shellcheck source=/dev/null
source ./stack.env
set +a

# The deployed image changes every release and is deliberately not persisted;
# read it back from the running container.
if [[ -z "${IMAGE:-}" ]]; then
  IMAGE="$(docker inspect -f '{{.Config.Image}}' "${COMPOSE_PROJECT}-backend-1" 2>/dev/null || true)"
fi
if [[ -z "$IMAGE" ]]; then
  echo "Could not determine the running image, and IMAGE is not set." >&2
  echo "If nothing is running yet, deploy first: the CD workflow does this." >&2
  exit 1
fi
export IMAGE

export DB_ROOT_PASSWORD="$(aws ssm get-parameter --region "$REGION" \
  --name "$SSM_PREFIX/db_root_password" --with-decryption \
  --query Parameter.Value --output text)"

FILES=(-f compose.yaml)
if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
  FILES+=(-f compose.traefik.yaml)
else
  FILES+=(-f compose.ports.yaml)
fi

exec docker compose -p "$COMPOSE_PROJECT" "${FILES[@]}" "$@"
