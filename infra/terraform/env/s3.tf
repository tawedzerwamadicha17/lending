data "aws_caller_identity" "current" {}

# One bucket per environment holding both the nightly backups and the stack
# config (compose files + scripts) that the instance pulls on boot and on
# every deploy.
resource "aws_s3_bucket" "data" {
  bucket = "${var.project}-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "expire-backups"
    status = "Enabled"

    filter {
      prefix = "${var.environment}/"
    }

    # Backups are small and read rarely; transitioning to a colder class
    # before expiry costs more in retrieval than it saves in storage at this
    # volume, so this just expires them.
    expiration {
      days = var.backup_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Stack config shipped to the instance
# ---------------------------------------------------------------------------
# terraform apply publishes the current working-copy versions so a fresh box
# boots correctly. The CD workflow re-publishes them on every deploy, so
# compose changes ship with the code that needs them.

locals {
  repo_root = "${path.module}/../../.."

  config_files = {
    "compose.yaml"         = "${local.repo_root}/docker/compose.yaml"
    "compose.ports.yaml"   = "${local.repo_root}/docker/compose.ports.yaml"
    "compose.traefik.yaml" = "${local.repo_root}/docker/compose.traefik.yaml"
    "deploy.sh"            = "${local.repo_root}/infra/scripts/deploy.sh"
    "backup.sh"            = "${local.repo_root}/infra/scripts/backup.sh"
    "restore.sh"           = "${local.repo_root}/infra/scripts/restore.sh"
  }
}

resource "aws_s3_object" "config" {
  for_each = local.config_files

  bucket = aws_s3_bucket.data.id
  key    = "config/${each.key}"
  source = each.value
  etag   = filemd5(each.value)
}
