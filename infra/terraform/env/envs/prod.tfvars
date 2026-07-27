environment = "prod"

# 2 vCPU / 2 GiB Graviton -- the practical floor for the full stack.
instance_type    = "t4g.small"
root_volume_size = 30
swap_size_mb     = 2048

# Zone Z05246372B8WP53PMAZ01 is nexinfrasolutions.net in this same account, so
# Terraform creates the A record itself and Let's Encrypt can validate on the
# first deploy without a manual DNS step.
site_name       = "corebyte.nexinfrasolutions.net"
route53_zone_id = "Z05246372B8WP53PMAZ01"
enable_tls      = true
acme_email      = "amaditsha@gmail.com"

vpc_cidr = "10.20.0.0/16"

backup_retention_days = 30
backup_hour_utc       = 2
