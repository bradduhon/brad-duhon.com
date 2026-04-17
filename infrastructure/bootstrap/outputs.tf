# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

output "state_bucket_name" {
  description = "Terraform state S3 bucket name — use in backend config"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  value = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for state locking — use in backend config"
  value       = aws_dynamodb_table.terraform_locks.name
}

output "kms_key_arn" {
  description = "KMS key ARN for state encryption — use in backend config"
  value       = aws_kms_key.terraform_state.arn
}

output "kms_key_alias" {
  value = aws_kms_alias.terraform_state.name
}
