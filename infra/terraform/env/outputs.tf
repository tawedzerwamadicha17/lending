output "instance_id" {
  description = "SendCommand target. The CD workflow resolves this by tag, so it is informational."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Point the site_name A record here."
  value       = aws_eip.app.public_ip
}

output "app_url" {
  value = var.enable_tls ? "https://${var.site_name}" : "http://${aws_eip.app.public_ip}"
}

output "data_bucket" {
  description = "Holds stack config under config/ and backups under <environment>/."
  value       = aws_s3_bucket.data.id
}

output "shell_command" {
  description = "Interactive shell on the box without SSH."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}"
}

output "admin_password_command" {
  description = "Retrieve the generated Frappe Administrator password."
  value       = "aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.admin_password.name} --with-decryption --query Parameter.Value --output text"
}
