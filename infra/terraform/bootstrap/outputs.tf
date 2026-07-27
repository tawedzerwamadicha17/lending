output "state_bucket" {
  description = "Pass to the env stack as -backend-config=bucket=..."
  value       = aws_s3_bucket.state.id
}

output "ecr_repository_url" {
  description = "Set as the ECR_REPOSITORY repo variable in GitHub."
  value       = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repo variable in GitHub."
  value       = aws_iam_role.ci.arn
}
