terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Bucket and key are supplied at init time so one stack serves both
  # environments:
  #   terraform init -reconfigure \
  #     -backend-config=bucket=<state bucket from bootstrap> \
  #     -backend-config=key=prod/terraform.tfstate \
  #     -backend-config=region=us-east-1
  backend "s3" {
    encrypt      = true
    use_lockfile = true # S3-native locking; avoids a DynamoDB table
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
