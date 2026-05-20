terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend configurado via -backend-config en el pipeline (o variables de entorno TF_VAR_*):
  #   bucket         → nombre del bucket S3 para el estado
  #   key            → "online-store-<env>.tfstate"
  #   region         → us-east-1
  #   dynamodb_table → tabla DynamoDB para el lock
  #   encrypt        → true
  #
  # Pre-requisito (ejecutar una sola vez):
  #   aws s3 mb s3://<bucket> --region us-east-1
  #   aws dynamodb create-table --table-name <tabla> \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST --region us-east-1
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}
