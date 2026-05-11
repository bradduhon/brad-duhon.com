---
title: "Terraform Module: KMS Key with Automatic Rotation"
date: 2026-05-10
tags: [aws, kms, terraform, iac, cloud-security, encryption, iam]
description: "Building a reusable KMS CMK module with enforced rotation, admin/user separation in the key policy, and sensible prod defaults."
draft: false
---

Before you encrypt a single S3 object, sign a CloudWatch log, or lock down an API Gateway stage, you need a key management strategy. KMS is the cryptographic backbone of nearly every security control in AWS. The decisions you make here - key per service vs. shared key, rotation policy, key policy structure - ripple through everything downstream.

This is the first module in my Core AWS Security Modules series, and it gets built first deliberately. Every subsequent module references a KMS key ARN. Getting this right once means you are not bolting on encryption as an afterthought.

## CMKs vs. AWS Managed Keys

AWS managed keys are what you get when you tick "enable encryption" in the console. They exist per-service, cannot be controlled at the key-policy level, and cannot be shared across accounts. Customer Managed Keys (CMKs) are the only option when you need cross-account access, fine-grained key policies, or compliance evidence of key rotation.

This module creates CMKs. AWS managed keys are not an option here.

## What the Module Provisions

- A KMS CMK with configurable description and usage
- Automatic annual key rotation - hardcoded on, not a variable
- A key alias for stable, human-readable referencing
- A baseline key policy with separation between key administrators and key users
- Optional multi-region replication flag for DR scenarios
- `prevent_destroy` lifecycle control driven by a variable

## Module Structure

```
modules/kms-key/
├── main.tf
├── variables.tf
├── outputs.tf
└── README.md
```

## `variables.tf`

```hcl
variable "alias" {
  description = "Alias for the KMS key. Will be prefixed with 'alias/'. Example: 'prod/s3-data'."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9:/_-]+$", var.alias))
    error_message = "Alias must contain only alphanumeric characters, colons, slashes, underscores, or hyphens."
  }
}

variable "description" {
  description = "Human-readable description of what this key protects."
  type        = string
}

variable "key_administrators" {
  description = "List of IAM ARNs permitted to manage the key (administer, not use). Typically a break-glass role or security team role."
  type        = list(string)
}

variable "key_users" {
  description = "List of IAM ARNs permitted to use the key for cryptographic operations (encrypt/decrypt)."
  type        = list(string)
}

variable "multi_region" {
  description = "Whether to create a multi-region primary key. Required for cross-region replication scenarios."
  type        = bool
  default     = false
}

variable "deletion_window_days" {
  description = "Number of days to wait before key deletion after scheduled deletion is requested. Min 7, max 30."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_days >= 7 && var.deletion_window_days <= 30
    error_message = "Deletion window must be between 7 and 30 days."
  }
}

variable "prevent_destroy" {
  description = "Toggle Terraform lifecycle prevent_destroy. Set true in prod to guard against accidental key deletion."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to the KMS key and alias."
  type        = map(string)
  default     = {}
}
```

## `main.tf`

The key policy is the primary access control for a KMS key. IAM policies alone are not sufficient - a key policy must explicitly allow the action, AND the IAM policy must allow it. Both gates must pass.

The policy here has three statements: root account ownership, key administrators, and key users. Each is intentionally separate.

```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "key_policy" {

  # Statement 1: Root account ownership
  # Required. Without this, the key can only be managed via the key policy
  # itself -- losing all admins means losing the key permanently.
  statement {
    sid    = "RootAccountOwnership"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Statement 2: Key administrators
  # Can manage the key (update policy, schedule deletion, describe) but
  # cannot perform cryptographic operations. Separation of duties.
  statement {
    sid    = "KeyAdministrators"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.key_administrators
    }

    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]

    resources = ["*"]
  }

  # Statement 3: Key users
  # Can perform cryptographic operations only. Cannot manage the key.
  statement {
    sid    = "KeyUsers"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.key_users
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  deletion_window_in_days = var.deletion_window_days
  enable_key_rotation     = true   # Always on -- not a variable.
  multi_region            = var.multi_region
  policy                  = data.aws_iam_policy_document.key_policy.json

  tags = merge(var.tags, {
    "kms:alias" = "alias/${var.alias}"
  })

  lifecycle {
    prevent_destroy = var.prevent_destroy
  }
}

# Aliases provide stable, human-readable references. Services and IAM policies
# should reference the alias ARN rather than the key ARN wherever supported --
# this allows key rotation without updating every downstream reference.
resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
```

## `outputs.tf`

```hcl
output "key_id" {
  description = "The KMS key ID."
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "The KMS key ARN. Use this when configuring encryption on AWS resources."
  value       = aws_kms_key.this.arn
}

output "alias_name" {
  description = "The KMS alias name (e.g. alias/prod/s3-data)."
  value       = aws_kms_alias.this.name
}

output "alias_arn" {
  description = "The KMS alias ARN. Prefer this over key_arn in IAM policies and service configs."
  value       = aws_kms_alias.this.arn
}
```

## Calling the Module

### Dev Environment

```hcl
module "kms_s3" {
  source = "../../modules/kms-key"

  alias       = "dev/s3-data"
  description = "Encrypts S3 data bucket objects in the dev environment"

  key_administrators = [
    "arn:aws:iam::123456789012:role/security-admin-role"
  ]

  key_users = [
    "arn:aws:iam::123456789012:role/dev-app-role",
    "arn:aws:iam::123456789012:role/dev-terraform-role",
  ]

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
    Service     = "s3"
  }
}
```

### Production Environment

```hcl
module "kms_s3_prod" {
  source = "../../modules/kms-key"

  alias                = "prod/s3-data"
  description          = "Encrypts S3 data bucket objects in the prod environment"
  deletion_window_days = 30
  prevent_destroy      = true   # Blocks accidental Terraform deletion

  key_administrators = [
    "arn:aws:iam::123456789012:role/security-break-glass-role"
  ]

  key_users = [
    "arn:aws:iam::123456789012:role/prod-app-role",
    "arn:aws:iam::123456789012:role/prod-terraform-deploy-role",
  ]

  tags = {
    Environment  = "prod"
    ManagedBy    = "terraform"
    Service      = "s3"
    Compliance   = "soc2"
    DataCategory = "confidential"
  }
}
```

### Referencing in a Downstream Module

```hcl
module "s3_data" {
  source = "../../modules/s3-secure"

  bucket_name = "my-org-data-prod"
  kms_key_arn = module.kms_s3_prod.key_arn   # passed in from this module

  # ...
}
```

## Design Decisions Worth Calling Out

### Rotation is always on

`enable_key_rotation` is hardcoded to `true` and not exposed as a variable. Annual automatic rotation is a baseline security control and a CIS AWS Benchmark requirement (3.7). If a caller needs rotation off, they should not be using this module. That is a signal to audit the use case, not accommodate it.

### Administrators cannot use the key

The separation between `key_administrators` and `key_users` is a deliberate least-privilege decision. An administrator who can also decrypt data can exfiltrate it without leaving a clear trace - the blast radius of a compromised admin role is the key policy, not the data. Keep these lists separate. Review them independently.

### The root account statement is required

Omitting the root account statement from a key policy is a common mistake. If every principal in `KeyAdministrators` is deleted or loses access, you have no recovery path. The root statement is not a security weakness - it is a safety net that still requires root credentials to invoke.

### Deletion window at 30 days in prod

The maximum deletion window gives you the largest possible recovery window if a key is accidentally scheduled for deletion. In dev, 7 days keeps cleanup cycles clean. In prod, 30 days is the right default.

### Alias ARN over key ARN in downstream references

AWS supports referencing KMS keys by alias ARN in most service configurations. Using the alias ARN means you can rotate to a new key - different key ID - and update only the alias target, without touching every downstream resource or IAM policy that references it.

## Security Checklist

- [ ] `enable_key_rotation = true` confirmed hardcoded, not variable-exposed
- [ ] `key_administrators` and `key_users` are separate lists with separate ARNs
- [ ] Root account statement present in key policy
- [ ] `prevent_destroy = true` in prod environment tfvars
- [ ] `deletion_window_days = 30` in prod
- [ ] Alias ARN used in downstream references rather than raw key ARN
- [ ] Tags include environment, service, and data classification
- [ ] Key administrators are break-glass or security team roles - not application roles
- [ ] Key users are scoped to the minimum set of roles that need cryptographic access

## Compliance Coverage

| Control | Framework | How This Module Satisfies It |
|---|---|---|
| Automatic key rotation | CIS AWS 3.7 | `enable_key_rotation = true` hardcoded |
| CMK over AWS managed key | CIS AWS / SOC 2 CC6 | Module only creates CMKs |
| Key policy least privilege | SOC 2 CC6.3 | Admin/user separation in key policy |
| Key deletion protection | Internal / SOC 2 | `prevent_destroy` + deletion window |
| Key usage auditing | SOC 2 CC7 | CloudTrail captures all KMS API calls automatically |

One thing worth noting on auditing: CloudTrail logs all KMS API calls by default - `kms:Decrypt`, `kms:GenerateDataKey`, `kms:Encrypt` - at no additional configuration cost. You get a full audit trail of who used the key, when, and from which service. Treat your CloudTrail as your KMS audit log.

## Up Next

With the key module in place, the next article covers the S3 Secure Bucket module - which references this key's ARN for SSE-KMS object encryption, and enforces Block Public Access, access logging, and lifecycle policies as non-negotiable defaults.
