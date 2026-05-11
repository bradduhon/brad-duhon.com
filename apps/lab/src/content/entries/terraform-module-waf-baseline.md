---
title: "Terraform Module: WAF Baseline"
date: 2026-05-10
tags: [aws, waf, terraform, cloudfront, cloud-security, iac, kinesis-firehose]
description: "Building a reusable WAF WebACL for CloudFront with managed rule groups, rate limiting, geo-restriction, and full request logging to S3."
draft: false
---

WAF deployed with defaults is not really WAF. This is the third module in my Core AWS Security Modules series, and it covers the one piece I see skipped or half-implemented most often: a WAF configuration you can actually audit, tune, and prove is working.

This `waf-baseline` module builds a WAFv2 WebACL scoped to CloudFront. It depends on `modules/kms-key` and `modules/s3-secure` from earlier entries in the series -- if you have not read those, the logging and encryption pieces will make more sense after you do.

## Why at the Edge

Positioning WAF at the CloudFront layer means bad requests are rejected before they reach your S3 origin or API Gateway. The alternative -- attaching WAF regionally at API Gateway -- works, but it leaves CloudFront unprotected and means your origin absorbs the load of inspecting traffic.

The default managed rule groups are a reasonable start. They are not sufficient on their own. Without rate limiting, geo-controls, and logging, you have a control you cannot audit or tune. This module adds all three.

## What the Module Provisions

- A WAFv2 WebACL scoped to `CLOUDFRONT`
- Four AWS managed rule groups: Core Rule Set, Known Bad Inputs, Amazon IP Reputation List, Anonymous IP List
- A rate-based rule with a configurable threshold (default: 2000 requests per 5-minute window)
- Optional geo-match rule supporting both ALLOW and BLOCK modes
- A Kinesis Firehose delivery stream to ship WAF logs to S3
- An IAM role scoped to let Firehose write to the logging bucket
- CloudWatch metrics enabled per rule

One hard AWS requirement worth knowing upfront: CloudFront-scoped WAF WebACLs MUST be created in `us-east-1`, regardless of where the rest of your infrastructure lives. This module enforces that via a provider alias -- callers must pass a `us-east-1` provider.

## Module Structure

```
modules/waf-baseline/
├── main.tf
├── variables.tf
├── outputs.tf
└── README.md
```

## `variables.tf`

```hcl
variable "name" {
  description = "Name prefix for the WebACL and associated resources."
  type        = string
}

variable "logging_bucket_arn" {
  description = "ARN of the S3 bucket to receive WAF logs via Kinesis Firehose. Use the output from modules/s3-secure."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS CMK used to encrypt the Firehose delivery stream and WAF logs."
  type        = string
}

variable "rate_limit_threshold" {
  description = "Maximum number of requests allowed from a single IP in any 5-minute window before the rate rule triggers."
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit_threshold >= 100
    error_message = "Rate limit threshold must be at least 100 (AWS minimum)."
  }
}

variable "enable_geo_restriction" {
  description = "Whether to apply a geo-match rule."
  type        = bool
  default     = false
}

variable "geo_restriction_type" {
  description = "Whether the geo rule ALLOWs only the listed countries, or BLOCKs them. Valid values: ALLOW, BLOCK."
  type        = string
  default     = "BLOCK"

  validation {
    condition     = contains(["ALLOW", "BLOCK"], var.geo_restriction_type)
    error_message = "geo_restriction_type must be ALLOW or BLOCK."
  }
}

variable "geo_country_codes" {
  description = "List of ISO 3166-1 alpha-2 country codes for the geo-match rule. Only used when enable_geo_restriction is true."
  type        = list(string)
  default     = []
}

variable "managed_rule_groups" {
  description = "List of AWS managed rule groups to attach. Defaults cover the recommended baseline."
  type = list(object({
    name     = string
    priority = number
  }))
  default = [
    { name = "AWSManagedRulesCommonRuleSet",        priority = 10 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 },
    { name = "AWSManagedRulesAnonymousIpList",       priority = 40 },
  ]
}

variable "tags" {
  description = "Tags to apply to all resources created by this module."
  type        = map(string)
  default     = {}
}
```

## `main.tf`

```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# IAM Role for Kinesis Firehose
# Firehose needs permission to write to the S3 logging bucket and to use
# the KMS key for encrypting log records in transit through the stream.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "firehose_policy" {
  statement {
    sid    = "S3LogDelivery"
    effect = "Allow"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]

    resources = [
      var.logging_bucket_arn,
      "${var.logging_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "KMSEncryption"
    effect = "Allow"

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]

    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.name}-waf-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "firehose" {
  name   = "${var.name}-waf-firehose-policy"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose_policy.json
}

# ---------------------------------------------------------------------------
# Kinesis Firehose Delivery Stream
# WAF logging requires a Firehose stream -- it cannot log directly to S3.
# The stream name MUST be prefixed with "aws-waf-logs-" (AWS requirement).
# ---------------------------------------------------------------------------
resource "aws_kinesis_firehose_delivery_stream" "waf_logs" {
  name        = "aws-waf-logs-${var.name}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = var.logging_bucket_arn
    prefix              = "waf-logs/${var.name}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "waf-logs-errors/${var.name}/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/"
    buffering_interval  = 300
    buffering_size      = 5

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/${var.name}-waf-logs"
      log_stream_name = "S3Delivery"
    }
  }

  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = var.kms_key_arn
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# WAF WebACL
# Priority ordering matters -- lower number = evaluated first.
#   10  AWSManagedRulesCommonRuleSet         -- OWASP Top 10, common exploits
#   20  AWSManagedRulesKnownBadInputsRuleSet -- Log4Shell, Spring4Shell, SSRF
#   30  AWSManagedRulesAmazonIpReputationList -- Bots, scanners, TOR exit nodes
#   40  AWSManagedRulesAnonymousIpList        -- VPNs, proxies, hosting providers
#   50  GeoRestriction (optional)
#   60  RateLimit                             -- catch-all for what slips through
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.enable_geo_restriction ? [1] : []

    content {
      name     = "GeoRestriction"
      priority = 50

      action {
        dynamic "block" {
          for_each = var.geo_restriction_type == "BLOCK" ? [1] : []
          content {}
        }

        dynamic "allow" {
          for_each = var.geo_restriction_type == "ALLOW" ? [1] : []
          content {}
        }
      }

      statement {
        geo_match_statement {
          country_codes = var.geo_country_codes
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "GeoRestriction"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "RateLimit"
    priority = 60

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_threshold
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# WAF Logging Configuration
# Connects the WebACL to the Firehose delivery stream.
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl_logging_configuration" "this" {
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
```

## `outputs.tf`

```hcl
output "web_acl_arn" {
  description = "The ARN of the WAF WebACL. Pass this to the CloudFront distribution's web_acl_id."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "The ID of the WAF WebACL."
  value       = aws_wafv2_web_acl.this.id
}

output "firehose_stream_arn" {
  description = "The ARN of the Kinesis Firehose delivery stream receiving WAF logs."
  value       = aws_kinesis_firehose_delivery_stream.waf_logs.arn
}
```

## Calling the Module

CloudFront WAF must live in `us-east-1`. Your environment's `providers.tf` needs an alias before the module will work:

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

### Dev

```hcl
module "waf" {
  source = "../../modules/waf-baseline"

  providers = {
    aws = aws.us_east_1
  }

  name                 = "my-org-dev"
  logging_bucket_arn   = module.s3_waf_logs.bucket_arn
  kms_key_arn          = module.kms_waf.key_arn
  rate_limit_threshold = 5000

  tags = { Environment = "dev", ManagedBy = "terraform" }
}
```

### Production

```hcl
module "waf_prod" {
  source = "../../modules/waf-baseline"

  providers = {
    aws = aws.us_east_1
  }

  name                 = "my-org-prod"
  logging_bucket_arn   = module.s3_waf_logs_prod.bucket_arn
  kms_key_arn          = module.kms_waf_prod.key_arn
  rate_limit_threshold = 2000

  enable_geo_restriction = true
  geo_restriction_type   = "ALLOW"
  geo_country_codes      = ["US", "CA", "GB"]

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "soc2"
  }
}
```

Passing the WebACL into a downstream CloudFront module:

```hcl
module "cdn" {
  source = "../../modules/cloudfront-edge-entry"

  web_acl_arn = module.waf_prod.web_acl_arn

  # ...
}
```

## Design Decisions Worth Calling Out

### Firehose is the only supported WAF log destination

AWS WAFv2 does not support logging directly to S3. Logs must flow through Kinesis Firehose. The stream name prefix `aws-waf-logs-` is an AWS hard requirement -- the WAF logging configuration will reject any stream name that does not match it. The module enforces this naming in the resource definition so you cannot misconfigure it.

### Managed rule groups run in `none` override mode

`override_action { none {} }` tells WAF to respect each managed rule group's own action decisions. The alternative, `override_action { count {} }`, puts all matched requests into count-only mode. That is useful during initial rollout. If you are onboarding WAF to an existing application, consider temporarily switching to `count {}` per rule group, reviewing sampled requests in CloudWatch, then switching back to `none {}` once you have confirmed there are no false positives. I have not validated this against high-traffic production patterns yet -- your mileage may vary.

### Rate limiting is evaluated last

The rate-based rule sits at priority 60, after all managed rule groups. AWS managed rules catch known bad actors early. The rate limiter acts as a catch-all for high-volume requests that do not match a known signature. Putting rate limiting first would block legitimate burst traffic before managed rules have a chance to evaluate request content.

### `authorization` and `cookie` headers are redacted from logs

WAF logs capture full request headers. The `authorization` and `cookie` headers frequently contain bearer tokens, session identifiers, and credentials. Redacting them means your log pipeline -- Firehose, S3, any downstream SIEM -- never sees those values. This is not optional in environments handling authenticated sessions.

### Geo restriction: ALLOW vs BLOCK

`BLOCK` is appropriate when you have a known set of high-risk countries generating abuse traffic. `ALLOW` is more appropriate when your application has a defined geographic user base and you want to reject everything outside it. The distinction matters: ALLOW is a positive allowlist (deny everything not on the list), BLOCK is a negative denylist (allow everything not on the list). For compliance-bounded applications, ALLOW with a tight country list is the stronger control.

### CloudWatch metrics per rule

Every rule has `cloudwatch_metrics_enabled = true` and `sampled_requests_enabled = true`. Per-rule match counts in CloudWatch are the primary mechanism for tuning WAF over time. Without them, you have no visibility into which rules are firing, which are silent, and whether your rate limit threshold makes sense for your actual traffic patterns.

## Security Checklist

- [ ] WebACL scope is `CLOUDFRONT` -- not `REGIONAL`
- [ ] Module deployed to `us-east-1` via provider alias
- [ ] All four AWS managed rule groups attached at correct priorities
- [ ] Rate limit threshold reviewed against actual traffic baselines
- [ ] `authorization` and `cookie` headers redacted from WAF logs
- [ ] Firehose stream name prefixed with `aws-waf-logs-`
- [ ] Firehose encryption using CMK -- not AWS managed key
- [ ] Logging configuration connected to WebACL
- [ ] CloudWatch metrics enabled per rule
- [ ] Geo restriction mode (ALLOW vs BLOCK) is intentional, not default

## Compliance Notes

| Control | Framework | How This Module Satisfies It |
|---|---|---|
| WAF for public endpoints | CIS AWS 5.4 / SOC 2 CC6.6 | WebACL attached to CloudFront |
| WAF logging enabled | SOC 2 CC7.2 | Firehose to S3, always on |
| Log encryption at rest | SOC 2 CC6.1 | Firehose stream CMK encrypted |
| Log encryption in transit | SOC 2 CC6.7 | Firehose uses TLS by default |
| Sensitive field redaction | SOC 2 CC6.1 | `authorization` and `cookie` redacted |
| IP reputation blocking | CIS AWS / SOC 2 | AWSManagedRulesAmazonIpReputationList |
| Rate limiting | SOC 2 CC6.6 | Rate-based rule at priority 60 |

## Up Next

With KMS, S3, and WAF modules in place, the next article in this series assembles them into the CloudFront Edge Entry Point -- a CloudFront distribution with an S3 origin locked to OAC, an API Gateway origin, and the WAF WebACL attached end to end.

## References

- [AWS WAFv2 Documentation](https://docs.aws.amazon.com/waf/latest/developerguide/what-is-aws-waf.html)
- [AWS Managed Rule Groups](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html)
- [WAF Logging with Kinesis Firehose](https://docs.aws.amazon.com/waf/latest/developerguide/logging-kinesis.html)
- [CIS AWS Foundations Benchmark v2.0](https://www.cisecurity.org/benchmark/amazon_web_services)
- [Terraform aws_wafv2_web_acl Resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl)
- [Terraform aws_kinesis_firehose_delivery_stream Resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream)
