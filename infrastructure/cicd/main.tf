// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

# ---------------------------------------------------------------------------
# CI/CD workspace — GitHub Actions IAM roles and OIDC provider.
#
# This workspace is intentionally separate from the main site infrastructure
# workspace. It is run manually with SSO credentials. The main workspace has
# no knowledge of these resources and cannot modify them, eliminating the
# IAM self-update deadlock that occurs when a workspace manages its own
# execution roles.
#
# Run manually when role permissions need to change:
#   terraform init -backend-config=../shared/backend.hcl \
#                  -backend-config="key=cicd/terraform.tfstate"
#   terraform plan
#   terraform apply
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  project    = "brad-duhon"
  github_org  = "bradduhon"
  github_repo = "brad-duhon.com"

  common_tags = {
    Project     = "brad-duhon-site"
    Environment = "production"
    Owner       = "Brad Duhon"
    ManagedBy   = "Terraform"
  }

  # ARNs for state backend resources computed from naming convention.
  # These resources are managed by the bootstrap workspace, not this one.
  terraform_state_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.project}-terraform-state"
  terraform_locks_table_arn  = "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${local.project}-terraform-locks"
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Role: site-deploy — used by deploy-main.yml and deploy-lab.yml
# Trust: main branch pushes only.
#
# IAM gap analysis — no gaps, no actions broader than necessary:
#   s3:ListBucket             — enumerate objects for sync diff
#   s3:GetObject              — read object metadata (ETag) for sync comparison
#   s3:PutObject              — upload built assets
#   s3:DeleteObject           — remove stale files (sync --delete)
#   kms:GenerateDataKey       — encrypt objects on PutObject (SSE-KMS)
#   kms:Decrypt               — decrypt metadata on GetObject (SSE-KMS)
#   cloudfront:CreateInvalidation — purge CDN cache after deploy
#
# S3 scoped to brad-duhon-site-* by naming convention.
# KMS scoped by kms:ResourceAliases — works regardless of whether S3
# accesses the key via alias or direct ARN.
# CloudFront uses * — distributions have no predictable ARN pattern and
# CreateInvalidation alone cannot read or modify distribution config.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "site_deploy" {
  name               = "${local.project}-site-deploy"
  assume_role_policy = data.aws_iam_policy_document.site_deploy_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "site_deploy_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_org}/${local.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role_policy" "site_deploy" {
  name   = "${local.project}-site-deploy"
  role   = aws_iam_role.site_deploy.id
  policy = data.aws_iam_policy_document.site_deploy_permissions.json
}

data "aws_iam_policy_document" "site_deploy_permissions" {
  statement {
    sid       = "S3ListBuckets"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.project}-site-*"]
  }

  statement {
    sid    = "S3ReadWriteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.project}-site-*/*"]
  }

  statement {
    sid    = "KMSSiteKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.project}-site"]
    }
  }

  statement {
    sid       = "CloudFrontInvalidation"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["*"] # CloudFront distributions have no predictable ARN pattern
  }
}

# ---------------------------------------------------------------------------
# Role: terraform-plan — used by terraform-plan.yml (PR checks + main pushes)
# Trust: pull_request events AND main branch.
#
# IAM gap analysis — no gaps, no actions broader than necessary:
#
#   State backend (read + lock):
#     s3:GetObject, s3:PutObject, s3:ListBucket     — read state + write lock
#     dynamodb:GetItem, PutItem, DeleteItem,
#               DescribeTable                        — acquire/release lock + verify table
#     kms:Decrypt, GenerateDataKey, DescribeKey      — decrypt/re-encrypt state
#
#   Resource reads (Terraform refreshes all managed resources on plan):
#     S3 bucket config reads (14 actions)
#     CloudFront distribution, OAC, function, policy, cache policy reads
#     ACM certificate reads
#     Route53 zone and record reads
#     KMS site key metadata reads
#     kms:ListAliases (account-level, requires *)
#
# Note: No IAM permissions. The main workspace no longer manages IAM
# resources — those are owned by this cicd workspace only.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "terraform_plan" {
  name               = "${local.project}-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.terraform_plan_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "terraform_plan_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_org}/${local.github_repo}:pull_request",
        "repo:${local.github_org}/${local.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role_policy" "terraform_plan" {
  name   = "${local.project}-terraform-plan"
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.terraform_plan_permissions.json
}

data "aws_iam_policy_document" "terraform_plan_permissions" {
  statement {
    sid    = "StateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      local.terraform_state_bucket_arn,
      "${local.terraform_state_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "StateDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [local.terraform_locks_table_arn]
  }

  statement {
    sid    = "StateKMS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.project}-terraform-state"]
    }
  }

  statement {
    sid    = "S3Read"
    effect = "Allow"
    actions = [
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketTagging",
      "s3:GetBucketLocation",
      "s3:GetBucketAcl",
      "s3:GetBucketOwnershipControls",
      "s3:ListBucket",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.project}-site-*"]
  }

  statement {
    sid    = "CloudFrontRead"
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:ListDistributions",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:GetFunction",
      "cloudfront:DescribeFunction",
      "cloudfront:ListFunctions",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
      "cloudfront:GetCachePolicy",
      "cloudfront:ListCachePolicies",
      "cloudfront:ListTagsForResource",
    ]
    resources = ["*"] # CloudFront read APIs do not support resource-level restrictions
  }

  statement {
    sid    = "ACMRead"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
    ]
    resources = ["*"] # ACM DescribeCertificate requires * or specific cert ARNs unknown at plan time
  }

  statement {
    sid    = "Route53Read"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
      "route53:ListTagsForResource",
    ]
    resources = ["*"] # Route53 GetChange requires * (change IDs are opaque tokens)
  }

  statement {
    sid    = "KMSSiteRead"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.project}-site"]
    }
  }

  # kms:ListAliases is account-level — IAM does not support resource restrictions
  statement {
    sid       = "KMSListAliases"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }
}

# ---------------------------------------------------------------------------
# Role: terraform-apply — used by terraform-apply.yml (workflow_dispatch only)
# Trust: main branch only.
#
# IAM gap analysis — no gaps, no actions broader than necessary:
#
#   Includes all plan permissions plus write operations for:
#   S3: full bucket lifecycle management (scoped to brad-duhon-site-*)
#   CloudFront: create/update/delete distributions and all sub-resources
#   ACM: request and delete certificates
#   Route53: create/update/delete zones and records
#   KMS: create/update/delete site key and aliases
#
# Note: No IAM permissions. The main workspace no longer manages IAM
# resources — those are owned by this cicd workspace only. Removing IAM
# management from this role eliminates the privilege escalation vector
# that previously existed when a compromised apply workflow could modify
# its own permissions.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "terraform_apply" {
  name               = "${local.project}-terraform-apply"
  assume_role_policy = data.aws_iam_policy_document.terraform_apply_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "terraform_apply_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_org}/${local.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role_policy" "terraform_apply" {
  name   = "${local.project}-terraform-apply"
  role   = aws_iam_role.terraform_apply.id
  policy = data.aws_iam_policy_document.terraform_apply_permissions.json
}

data "aws_iam_policy_document" "terraform_apply_permissions" {
  statement {
    sid    = "StateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      local.terraform_state_bucket_arn,
      "${local.terraform_state_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "StateDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [local.terraform_locks_table_arn]
  }

  statement {
    sid    = "StateKMS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.project}-terraform-state"]
    }
  }

  statement {
    sid    = "S3BucketManagement"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetBucketLocation",
      "s3:GetBucketAcl",
      "s3:GetBucketOwnershipControls",
      "s3:ListBucket",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.project}-site-*"]
  }

  statement {
    sid    = "CloudFrontManagement"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:ListDistributions",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:CreateFunction",
      "cloudfront:UpdateFunction",
      "cloudfront:DeleteFunction",
      "cloudfront:GetFunction",
      "cloudfront:DescribeFunction",
      "cloudfront:PublishFunction",
      "cloudfront:ListFunctions",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:UpdateResponseHeadersPolicy",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
      "cloudfront:GetCachePolicy",
      "cloudfront:ListCachePolicies",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
    ]
    resources = ["*"] # CloudFront does not support resource-level IAM restrictions
  }

  statement {
    sid    = "ACMManagement"
    effect = "Allow"
    actions = [
      "acm:RequestCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate",
      "acm:ListTagsForCertificate",
    ]
    resources = ["*"] # ACM RequestCertificate requires *
  }

  statement {
    sid    = "Route53Management"
    effect = "Allow"
    actions = [
      "route53:CreateHostedZone",
      "route53:DeleteHostedZone",
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
      "route53:ChangeTagsForResource",
      "route53:ListTagsForResource",
    ]
    resources = ["*"] # Route53 GetChange requires *
  }

  statement {
    sid    = "KMSSiteKeyManagement"
    effect = "Allow"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:EnableKeyRotation",
      "kms:TagResource",
      "kms:ListResourceTags",
      "kms:ReplicateKey",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.project}-site"]
    }
  }

  # kms:CreateKey cannot be scoped to a specific key ARN (key does not exist yet)
  statement {
    sid       = "KMSCreateKey"
    effect    = "Allow"
    actions   = ["kms:CreateKey"]
    resources = ["*"]
  }

  statement {
    sid    = "KMSAliasManagement"
    effect = "Allow"
    actions = [
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/${local.project}-*",
      "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*",
    ]
  }

  # kms:ListAliases is account-level — IAM does not support resource restrictions
  statement {
    sid       = "KMSListAliases"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }
}
