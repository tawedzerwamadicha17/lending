# Amazon Linux 2023, arm64. AL2023 ships the SSM agent preinstalled, which is
# what makes the no-SSH deploy path work out of the box.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    project        = var.project
    environment    = var.environment
    region         = var.aws_region
    ecr_registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    ecr_repository = var.project
    config_bucket  = aws_s3_bucket.data.id
    ssm_prefix     = "/${var.project}/${var.environment}"
    site_name      = var.site_name
    enable_tls     = var.enable_tls
    acme_email     = var.acme_email
    swap_size_mb   = var.swap_size_mb
    backup_hour    = var.backup_hour_utc
  })

  # Replacing the instance destroys the Docker volumes holding the database.
  # Deploys go through SSM and never touch this resource; changing user_data
  # intentionally should be paired with a restore from S3.
  user_data_replace_on_change = false

  tags = {
    Name    = "${var.project}-${var.environment}"
    Project = var.project # SendCommand is scoped on this tag
  }

  lifecycle {
    ignore_changes = [ami] # do not silently replace the box when AL2023 republishes
  }
}

# Static address so DNS survives a stop/start. An attached public IPv4 is
# billed either way (~$3.65/month), so this is free in practice.
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = { Name = "${var.project}-${var.environment}" }
}
