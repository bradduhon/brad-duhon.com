// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

output "site_deploy_role_arn" {
  description = "IAM role for site deploys — GitHub secret: AWS_ROLE_ARN"
  value       = aws_iam_role.site_deploy.arn
}

output "terraform_plan_role_arn" {
  description = "IAM role for terraform plan — GitHub secret: TF_PLAN_ROLE_ARN"
  value       = aws_iam_role.terraform_plan.arn
}

output "terraform_apply_role_arn" {
  description = "IAM role for terraform apply — GitHub secret: TF_APPLY_ROLE_ARN"
  value       = aws_iam_role.terraform_apply.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}
