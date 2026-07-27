# Secrets are generated here and stored as SecureString parameters. The
# instance reads them at deploy time via its instance role; they never appear
# in the repo, in user-data, or on the instance's disk.
#
# Note: generated values DO land in Terraform state. That is why the state
# bucket created by the bootstrap stack is encrypted and private.

resource "random_password" "db_root" {
  length  = 32
  special = false # MariaDB CLI + compose interpolation both mangle some specials
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "db_root_password" {
  name        = "/${var.project}/${var.environment}/db_root_password"
  description = "MariaDB root password for ${var.environment}"
  type        = "SecureString"
  value       = random_password.db_root.result
}

resource "aws_ssm_parameter" "admin_password" {
  name        = "/${var.project}/${var.environment}/admin_password"
  description = "Frappe Administrator password for ${var.environment}"
  type        = "SecureString"
  value       = random_password.admin.result
}
