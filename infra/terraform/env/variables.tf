variable "project" {
  description = "Name prefix shared with the bootstrap stack."
  type        = string
  default     = "lending"
}

variable "environment" {
  description = "Environment name. Drives resource names, the SSM parameter prefix, and the backup key prefix."
  type        = string

  validation {
    condition     = contains(["prod", "staging"], var.environment)
    error_message = "environment must be prod or staging."
  }
}

variable "aws_region" {
  description = "Must match the bootstrap stack's region."
  type        = string
  default     = "af-south-1"
}

# t4g.small (2 GiB) is the practical floor for the full stack -- MariaDB plus
# gunicorn plus three workers does not fit in 1 GiB without constant swapping.
# Both environments run it so staging behaves like prod under load.
variable "instance_type" {
  description = "Graviton instance type for the application host."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size" {
  description = "Root EBS volume in GiB. Holds Docker images (~2 GB each) plus the database."
  type        = number
  default     = 30
}

variable "swap_size_mb" {
  description = "Swap file size. Cheap insurance against OOM on small instances."
  type        = number
  default     = 2048
}

# Use the real domain if you have one; otherwise any stable placeholder works
# and the app stays reachable by IP. Changing this after the first deploy
# strands the existing site -- it is the directory name under sites/.
variable "site_name" {
  description = "The Frappe site name."
  type        = string
}

variable "enable_tls" {
  description = "Put Traefik in front and issue Let's Encrypt certs. Requires site_name to be a domain whose A record already resolves to this host."
  type        = bool
  default     = false
}

variable "acme_email" {
  description = "Contact address for Let's Encrypt. Required when enable_tls is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_tls || length(var.acme_email) > 0
    error_message = "acme_email is required when enable_tls is true."
  }
}

variable "allowed_web_cidrs" {
  description = "Who may reach ports 80/443. Narrow this for staging."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "backup_retention_days" {
  description = "How long nightly backups live in S3 before the lifecycle rule expires them."
  type        = number
  default     = 30
}

variable "backup_hour_utc" {
  description = "Hour (UTC) the nightly backup timer fires."
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR for this environment's VPC."
  type        = string
  default     = "10.20.0.0/16"
}
