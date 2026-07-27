environment = "prod"

# 2 vCPU / 2 GiB Graviton -- the practical floor for the full stack.
instance_type    = "t4g.small"
root_volume_size = 30
swap_size_mb     = 2048

# Replace with your domain, then set enable_tls = true once its A record
# points at the instance's public_ip output. Until then the app is served
# over plain HTTP by IP and this value is just the site directory name.
site_name  = "lending.example.com"
enable_tls = false
acme_email = ""

vpc_cidr = "10.20.0.0/16"

backup_retention_days = 30
backup_hour_utc       = 2
