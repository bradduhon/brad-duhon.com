# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

output "bucket_id" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.site.id
}

output "bucket_arn" {
  value = aws_s3_bucket.site.arn
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — use in cache invalidation"
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_distribution_arn" {
  value = aws_cloudfront_distribution.site.arn
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.site.domain_name
}
