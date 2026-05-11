---
title: "Terraform Module: S3 Secure Bucket"
date: 2026-05-10
tags: [aws, s3, terraform, iac, cloud-security, kms, encryption]
description: "Building a reusable S3 module that defaults to locked down: SSE-KMS, Block Public Access, access logging, versioning, and a bucket policy that enforces TLS."
draft: false
---

S3 is the most commonly misconfigured AWS service. Not because it is complicated, but because AWS spent years defaulting to open and treating security as opt-in. Block Public Access was not retroactively enforced. Encryption was not on by default until January 2023. Access logging has never been automatic.

This is the second module in my Core AWS Security Modules series. It builds on `modules/kms-key` from the first entry - if you have not read that one, the encryption section will make more sense after you do.

## The Problem with S3 Defaults

AWS enabled SSE-S3 encryption by default for new buckets in 2023. That is better than nothing. SSE-S3 uses AWS-managed keys with no key policy control, no rotation visibility, no cross-account capability, and no CloudTrail evidence of individual decrypt operations. It is encryption you cannot audit or prove.

The result in most environments: a long tail of buckets with SSE-S3 instead of SSE-KMS, missing access logs, missing versioning, and a "no bucket policy" treated as a security control rather than an absence of one.

This module takes the opposite stance. Everything is locked down by default. Callers must explicitly opt into relaxed settings - not the other way around.

## What the Module Provisions

- An S3 bucket with a name validated against AWS constraints
- Block Public Access enabled on all four settings - no exceptions, not exposed as variables
- SSE-KMS encryption using a caller-supplied KMS key ARN
- A dedicated access logging bucket, or an existing logging bucket ARN if you already have one
- Versioning enabled by default, with a variable to disable for transient/scratch buckets
- A lifecycle policy for noncurrent version expiration to control storage costs
- A bucket policy with an explicit deny on non-HTTPS requests
- An explicit deny on `s3:DeleteBucket` as belt-and-suspenders alongside `prevent_destroy`
- Optional Object Lock in COMPLIANCE mode for WORM use cases

## Module Structure

```
modules/s3-secure/
├── main.tf
├── variables.tf
├── outputs.tf
└── README.md
```

## `variables.tf`

```hcl
variable "bucket_name" {
  description = "Name of the S3 bucket. Must be globally unique, lowercase, 3-63 characters."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name must be 3-63 lowercase alphanumeric characters or hyphens, and cannot start or end with a hyphen."
  }
}

variable "kms_key_arn" {
  description = "ARN of the KMS CMK used for SSE-KMS encryption. Use the output from modules/kms-key."
  type        = string
}

variable "logging_bucket_id" {
  description = "ID of an existing S3 bucket to receive access logs. If not provided, a dedicated logging bucket is created."
  type        = string
  default     = null
}

variable "logging_prefix" {
  description = "Prefix for access log objects written to the logging bucket."
  type        = string
  default     = null  # Defaults to bucket_name/ in locals if not supplied
}

variable "versioning_enabled" {
  description = "Enable S3 versioning. Recommended true for all non-transient buckets."
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days before noncurrent object versions are permanently deleted. Applies only when versioning is enabled."
  type        = number
  default     = 90
}

variable "enable_object_lock" {
  description = "Enable S3 Object Lock for WORM compliance use cases. Cannot be disabled after bucket creation."
  type        = bool
  default     = false
}

variable "object_lock_retention_days" {
  description = "Default Object Lock retention period in days. Only used when enable_object_lock is true."
  type        = number
  default     = 365
}

variable "force_destroy" {
  description = "Allow Terraform to destroy the bucket even if it contains objects. Set false in prod."
  type        = bool
  default     = false
}

variable "prevent_destroy" {
  description = "Toggle Terraform lifecycle prevent_destroy. Set true in prod."
  type        = bool
  default     = false
}

variable "allowed_principals" {
  description = "List of IAM ARNs explicitly permitted to perform s3:GetObject and s3:PutObject. All others are implicitly denied by the bucket policy."
  type        = list(string)
  default     = []
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

locals {
  logging_prefix = coalesce(var.logging_prefix, "${var.bucket_name}/")

  # Use the provided logging bucket or fall back to the one created by this module
  logging_bucket_id = coalesce(
    var.logging_bucket_id,
    try(aws_s3_bucket.access_logs[0].id, null)
  )
}

# ---------------------------------------------------------------------------
# Access Logging Bucket
# Creates a dedicated logging bucket only when one isn't supplied by the caller.
# The logging bucket itself does NOT log (avoids recursive logging) and uses
# SSE-S3 since KMS-encrypted logging buckets require additional grant config.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "access_logs" {
  count = var.logging_bucket_id == null ? 1 : 0

  bucket        = "${var.bucket_name}-access-logs"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Purpose = "access-logs"
    LogsFor = var.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "access_logs" {
  count  = var.logging_bucket_id == null ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count  = var.logging_bucket_id == null ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"   # SSE-S3 for log buckets -- avoids KMS grant complexity
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count  = var.logging_bucket_id == null ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count  = var.logging_bucket_id == null ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      days = 365   # Retain logs for 1 year by default
    }
  }
}

# ---------------------------------------------------------------------------
# Primary Bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  # Object Lock must be enabled at bucket creation -- it cannot be added later.
  dynamic "object_lock_configuration" {
    for_each = var.enable_object_lock ? [1] : []

    content {
      object_lock_enabled = "Enabled"
    }
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = var.prevent_destroy
  }
}

# ---------------------------------------------------------------------------
# Block Public Access -- All Four Settings
# These four settings together prevent any public access path:
#   block_public_acls:       Rejects PUT requests that include a public ACL
#   block_public_policy:     Rejects bucket policies that grant public access
#   ignore_public_acls:      Ignores any existing public ACLs on the bucket/objects
#   restrict_public_buckets: Restricts access to the bucket to AWS services and
#                            authorized principals only, regardless of ACLs or policy
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# SSE-KMS Encryption
# bucket_key_enabled = true reduces KMS API call costs significantly for
# high-throughput buckets by generating a per-bucket data key rather than
# calling KMS for every object operation.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

# ---------------------------------------------------------------------------
# Versioning
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Disabled"
  }
}

# ---------------------------------------------------------------------------
# Access Logging
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_logging" "this" {
  bucket        = aws_s3_bucket.this.id
  target_bucket = local.logging_bucket_id
  target_prefix = local.logging_prefix
}

# ---------------------------------------------------------------------------
# Lifecycle Configuration
# Noncurrent version expiration prevents unbounded storage growth when
# versioning is enabled. Objects are not deleted -- only noncurrent versions
# older than the threshold are removed.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.versioning_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "noncurrent-version-expiration"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# ---------------------------------------------------------------------------
# Object Lock Default Retention
# Only configured when enable_object_lock is true. WORM (Write Once Read Many)
# prevents objects from being deleted or overwritten for the retention period --
# including by the root account.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_object_lock_configuration" "this" {
  count  = var.enable_object_lock ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = "COMPLIANCE"   # COMPLIANCE = cannot be overridden even by root
      days = var.object_lock_retention_days
    }
  }
}

# ---------------------------------------------------------------------------
# Bucket Policy
# Two explicit denies that apply regardless of IAM policy:
#   1. Deny any request not using TLS (enforces HTTPS-only access)
#   2. Deny s3:DeleteBucket (belt-and-suspenders alongside prevent_destroy)
#
# Note: Explicit denies in bucket policies override IAM allow statements.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "bucket_policy" {

  # Deny all non-HTTPS requests
  statement {
    sid    = "DenyNonHTTPS"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Deny bucket deletion from any principal
  statement {
    sid    = "DenyBucketDeletion"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:DeleteBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  # Allow explicitly permitted principals to read and write objects
  dynamic "statement" {
    for_each = length(var.allowed_principals) > 0 ? [1] : []

    content {
      sid    = "AllowedPrincipals"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.allowed_principals
      }

      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]

      resources = [
        aws_s3_bucket.this.arn,
        "${aws_s3_bucket.this.arn}/*",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket_policy.json

  # Ensure BPA is applied before the policy to avoid race condition
  depends_on = [aws_s3_bucket_public_access_block.this]
}
```

## `outputs.tf`

```hcl
output "bucket_id" {
  description = "The S3 bucket name (ID)."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "The S3 bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "bucket_domain_name" {
  description = "The bucket's regional domain name. Use this as a CloudFront S3 origin domain."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "logging_bucket_id" {
  description = "The ID of the access logging bucket (created or supplied)."
  value       = local.logging_bucket_id
}
```

## Calling the Module

### Dev Environment

```hcl
module "kms_s3" {
  source = "../../modules/kms-key"

  alias              = "dev/s3-app-data"
  description        = "Encrypts app data bucket in dev"
  key_administrators = ["arn:aws:iam::123456789012:role/security-admin-role"]
  key_users          = ["arn:aws:iam::123456789012:role/dev-app-role"]

  tags = { Environment = "dev", ManagedBy = "terraform" }
}

module "s3_app_data" {
  source = "../../modules/s3-secure"

  bucket_name = "my-org-app-data-dev"
  kms_key_arn = module.kms_s3.key_arn

  allowed_principals = [
    "arn:aws:iam::123456789012:role/dev-app-role",
  ]

  tags = { Environment = "dev", ManagedBy = "terraform" }
}
```

### Production Environment

```hcl
module "kms_s3_prod" {
  source = "../../modules/kms-key"

  alias                = "prod/s3-app-data"
  description          = "Encrypts app data bucket in prod"
  deletion_window_days = 30
  prevent_destroy      = true
  key_administrators   = ["arn:aws:iam::123456789012:role/security-break-glass-role"]
  key_users = [
    "arn:aws:iam::123456789012:role/prod-app-role",
    "arn:aws:iam::123456789012:role/prod-cloudfront-role",
  ]

  tags = { Environment = "prod", ManagedBy = "terraform", Compliance = "soc2" }
}

module "s3_app_data_prod" {
  source = "../../modules/s3-secure"

  bucket_name                        = "my-org-app-data-prod"
  kms_key_arn                        = module.kms_s3_prod.key_arn
  prevent_destroy                    = true
  force_destroy                      = false
  noncurrent_version_expiration_days = 365

  allowed_principals = [
    "arn:aws:iam::123456789012:role/prod-app-role",
    "arn:aws:iam::123456789012:role/prod-cloudfront-role",
  ]

  tags = {
    Environment  = "prod"
    ManagedBy    = "terraform"
    Compliance   = "soc2"
    DataCategory = "confidential"
  }
}
```

### Referencing in a Downstream Module

```hcl
module "cdn" {
  source = "../../modules/cloudfront-edge-entry"

  s3_bucket_id          = module.s3_app_data_prod.bucket_id
  s3_bucket_arn         = module.s3_app_data_prod.bucket_arn
  s3_origin_domain_name = module.s3_app_data_prod.bucket_domain_name

  # ...
}
```

## Design Decisions Worth Calling Out

### Block Public Access is not a variable

All four BPA settings are hardcoded to `true` and not exposed as variables. There is no legitimate use case for a secure bucket module to allow public access. If a bucket needs to be public, it should not use this module. This is a deliberate constraint, not an oversight.

### SSE-S3 for the logging bucket

The access logging bucket uses SSE-S3 (AES256) rather than SSE-KMS. This is intentional: the S3 log delivery service requires either SSE-S3 or a KMS key grant explicitly added for the log delivery principal. Using SSE-S3 on the logging bucket avoids that complexity while still encrypting the logs at rest. The primary data bucket always uses SSE-KMS.

### `bucket_key_enabled = true`

S3 Bucket Keys reduce KMS API call volume by generating a short-lived per-bucket data key locally rather than making a KMS API call for every `PutObject` and `GetObject`. For high-throughput buckets this matters for both cost and latency. There is no security tradeoff - the data is still encrypted with your CMK.

### `DenyNonHTTPS` applies to all principals including root

The `aws:SecureTransport = false` condition in the bucket policy denies any request not made over TLS, including from IAM principals that would otherwise have full S3 access. This enforces encryption in transit as a bucket-level guarantee, not a client-side assumption.

### `depends_on` for the bucket policy

The `aws_s3_bucket_policy` resource has an explicit `depends_on` for `aws_s3_bucket_public_access_block`. Without it, Terraform may attempt to apply the bucket policy before BPA is fully enforced. The result is a brief window where a policy allowing access is active without the BPA guardrail in place.

### Object Lock uses COMPLIANCE mode

When Object Lock is enabled, this module defaults to `COMPLIANCE` mode rather than `GOVERNANCE` mode. In COMPLIANCE mode, no user - including the root account - can delete or overwrite objects before the retention period expires. GOVERNANCE mode allows users with `s3:BypassGovernanceRetention` to override it. If you need WORM guarantees for compliance (FINRA, SEC 17a-4, HIPAA), COMPLIANCE mode is the only defensible choice.

## Security Checklist

- [ ] Block Public Access all four settings confirmed `true`
- [ ] SSE-KMS with caller-supplied CMK ARN - not SSE-S3
- [ ] `bucket_key_enabled = true` for cost-efficient KMS usage
- [ ] Access logging enabled and pointing to a dedicated logging bucket
- [ ] Versioning enabled for all non-transient buckets
- [ ] Noncurrent version expiration configured to prevent storage sprawl
- [ ] `DenyNonHTTPS` in bucket policy - enforces TLS for all requests
- [ ] `DenyBucketDeletion` in bucket policy as belt-and-suspenders
- [ ] `force_destroy = false` in prod
- [ ] `prevent_destroy = true` in prod
- [ ] `allowed_principals` scoped to minimum required set of roles
- [ ] Object Lock enabled for any WORM/compliance use cases

## Compliance Coverage

| Control | Framework | How This Module Satisfies It |
|---|---|---|
| Encryption at rest | CIS AWS 2.1.1 / SOC 2 CC6.1 | SSE-KMS with CMK, hardcoded |
| Encryption in transit | CIS AWS 2.1.2 / SOC 2 CC6.7 | `DenyNonHTTPS` bucket policy statement |
| Block Public Access | CIS AWS 2.1.5 | All four BPA settings hardcoded true |
| Access logging | CIS AWS 2.1.3 | Dedicated logging bucket, always enabled |
| Versioning | CIS AWS 2.1.3 | Enabled by default, exposed as variable |
| Object Lock (WORM) | SEC 17a-4 / HIPAA | Optional flag, COMPLIANCE mode |
| Key rotation | CIS AWS 3.7 | Inherited from `modules/kms-key` |

## Up Next

With KMS and S3 covered, the next entry in this series is the WAF Baseline module - a managed rule group configuration with rate limiting, geo-blocking, and request logging to S3 using this module's output as the log destination.
