# Optional Route53 record. When the zone lives in this account, Terraform
# points the site name at the instance directly, which removes the manual step
# that otherwise blocks Let's Encrypt from issuing a certificate.
#
# Leave route53_zone_id empty to manage DNS elsewhere.

resource "aws_route53_record" "app" {
  count = var.route53_zone_id == "" ? 0 : 1

  zone_id = var.route53_zone_id
  name    = var.site_name
  type    = "A"
  # Short TTL: the record is created in the same apply that creates the
  # instance, and ACME validation follows minutes later.
  ttl     = 60
  records = [aws_eip.app.public_ip]
}
