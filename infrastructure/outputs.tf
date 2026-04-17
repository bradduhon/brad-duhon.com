# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

# ---------------------------------------------------------------------------
# After apply:
#   1. route53_nameservers -> set at your domain registrar (NS delegation)
#   2. github_deploy_role_arn -> GitHub repo secret: AWS_ROLE_ARN
#   3. main_site_bucket -> GitHub repo secret: MAIN_SITE_BUCKET
#   4. lab_site_bucket -> GitHub repo secret: LAB_SITE_BUCKET
#   5. main_cloudfront_id -> GitHub repo secret: MAIN_CLOUDFRONT_ID
#   6. lab_cloudfront_id -> GitHub repo secret: LAB_CLOUDFRONT_ID
# ---------------------------------------------------------------------------

output "route53_nameservers" {
  description = "Set these as NS records at your domain registrar to delegate brad-duhon.com to Route 53"
  value       = aws_route53_zone.main.name_servers
}

output "route53_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "main_site_bucket" {
  description = "S3 bucket for brad-duhon.com — GitHub secret: MAIN_SITE_BUCKET"
  value       = module.main_site.bucket_id
}

output "lab_site_bucket" {
  description = "S3 bucket for lab.brad-duhon.com — GitHub secret: LAB_SITE_BUCKET"
  value       = module.lab_site.bucket_id
}

output "main_cloudfront_id" {
  description = "CloudFront distribution ID for brad-duhon.com — GitHub secret: MAIN_CLOUDFRONT_ID"
  value       = module.main_site.cloudfront_distribution_id
}

output "lab_cloudfront_id" {
  description = "CloudFront distribution ID for lab.brad-duhon.com — GitHub secret: LAB_CLOUDFRONT_ID"
  value       = module.lab_site.cloudfront_distribution_id
}

output "main_cloudfront_domain" {
  value = module.main_site.cloudfront_domain_name
}

output "lab_cloudfront_domain" {
  value = module.lab_site.cloudfront_domain_name
}

output "site_deploy_role_arn" {
  description = "IAM role ARN for site deploys — GitHub secret: AWS_ROLE_ARN"
  value       = aws_iam_role.site_deploy.arn
}

output "site_kms_key_arn" {
  value = aws_kms_key.site.arn
}
