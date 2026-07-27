environment = "staging"

# Matched to prod's instance type so staging is a real rehearsal for it --
# memory pressure and migration timings observed here mean something. Smaller
# disk, since staging holds no long-lived data.
instance_type    = "t4g.small"
root_volume_size = 20
swap_size_mb     = 2048

site_name  = "staging.lending.example.com"
enable_tls = false
acme_email = ""

# Distinct range from prod so the two VPCs stay peer-able if that is ever
# wanted.
vpc_cidr = "10.30.0.0/16"

# Staging backups exist to test the restore path, not to be retained.
backup_retention_days = 7
backup_hour_utc       = 1

# Recommended: lock staging to your office/VPN egress rather than the world.
# allowed_web_cidrs = ["203.0.113.4/32"]
