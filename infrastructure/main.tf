# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

module "main_site" {
  source = "./modules/static-site"

  domain_name                   = local.main_domain
  site_label                    = "main"
  project                       = local.project
  zone_id                       = aws_route53_zone.main.zone_id
  kms_key_arn                   = aws_kms_key.site.arn
  cf_function_arn               = aws_cloudfront_function.url_rewrite.arn
  cf_response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  cf_cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
  tags                          = local.common_tags
}

module "lab_site" {
  source = "./modules/static-site"

  domain_name                   = local.lab_domain
  site_label                    = "lab"
  project                       = local.project
  zone_id                       = aws_route53_zone.main.zone_id
  kms_key_arn                   = aws_kms_key.site.arn
  cf_function_arn               = aws_cloudfront_function.url_rewrite.arn
  cf_response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  cf_cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
  tags                          = local.common_tags
}
