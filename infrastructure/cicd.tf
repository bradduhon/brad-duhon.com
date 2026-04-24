# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

# ---------------------------------------------------------------------------
# Data sources — bootstrap-created resources referenced in IAM policies
# ---------------------------------------------------------------------------

data "aws_s3_bucket" "terraform_state" {
  bucket = "${local.project}-terraform-state"
}

# ARNs for bootstrap-created resources computed from naming convention.
# Avoids data source lookups (dynamodb:DescribeTable, kms:ListAliases) that
# would create an IAM self-update deadlock when this role is missing those
# permissions. The naming convention is authoritative — see bootstrap/main.tf.
locals {
  terraform_locks_table_arn      = "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${local.project}-terraform-locks"
  terraform_state_kms_alias_arn  = "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/${local.project}-terraform-state"
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider
#
# If this account already has an OIDC provider for GitHub Actions, import it:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
#
# Thumbprints: verify at
# https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
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
# Role: site deploy — used by deploy-main.yml and deploy-lab.yml
# Trust: main branch pushes only.
#
# IAM gap analysis — no gaps, no actions broader than necessary:
#   s3:ListBucket         — enumerate existing objects for sync diff
#   s3:GetObject          — read object metadata (ETag) for sync comparison
#   s3:PutObject          — upload built assets
#   s3:DeleteObject       — remove stale files (sync --delete)
#   kms:GenerateDataKey   — encrypt objects on PutObject (SSE-KMS)
#   kms:Decrypt           — decrypt metadata on GetObject (SSE-KMS)
#   cloudfront:CreateInvalidation — purge CDN cache after deploy
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
    resources = [module.main_site.bucket_arn, module.lab_site.bucket_arn]
  }

  statement {
    sid    = "S3ReadWriteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${module.main_site.bucket_arn}/*",
      "${module.lab_site.bucket_arn}/*",
    ]
  }

  statement {
    sid    = "KMSSiteKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]
    resources = [aws_kms_key.site.arn]
  }

  statement {
    sid       = "CloudFrontInvalidation"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [module.main_site.cloudfront_distribution_arn, module.lab_site.cloudfront_distribution_arn]
  }
}

# ---------------------------------------------------------------------------
# Role: terraform-plan — used by terraform-plan.yml (PR checks)
# Trust: pull_request events AND main branch (for plan-on-push visibility).
#
# IAM gap analysis — no gaps, no actions broader than necessary:
#
#   State backend (read + lock):
#     s3:GetObject, s3:PutObject, s3:ListBucket — read state + write lock object
#     dynamodb:GetItem, PutItem, DeleteItem      — acquire and release state lock
#     kms:Decrypt, GenerateDataKey, DescribeKey  — decrypt/re-encrypt state file
#
#   Resource reads (Terraform refreshes all managed resources on plan):
#     S3 bucket configuration reads
#     CloudFront distribution, OAC, function, headers policy, cache policy reads
#     ACM certificate reads
#     Route53 zone and record reads
#     KMS key metadata reads
#     IAM role, policy, OIDC provider reads
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
  # State backend — plan still acquires a lock and reads current state
  statement {
    sid    = "StateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      data.aws_s3_bucket.terraform_state.arn,
      "${data.aws_s3_bucket.terraform_state.arn}/*",
    ]
  }

  statement {
    sid    = "StateDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable", # S3 backend calls this during init to verify the lock table exists
    ]
    resources = [local.terraform_locks_table_arn]
  }

  # kms:ResourceAliases is evaluated against the key's configured aliases,
  # not the access method — works whether S3 or Terraform uses the key ARN
  # directly or via alias. Avoids needing the exact key ARN at policy-write time.
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

  # S3 — read current bucket configuration
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
      "s3:GetBucketAcl",              # provider reads ACL on every bucket refresh
      "s3:GetBucketOwnershipControls", # provider v5+ reads this on every bucket refresh
      "s3:ListBucket",
    ]
    resources = [
      module.main_site.bucket_arn,
      module.lab_site.bucket_arn,
    ]
  }

  # CloudFront — read distributions, OAC, functions, policies
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
      "cloudfront:DescribeFunction", # provider uses DescribeFunction (not GetFunction) on refresh
      "cloudfront:ListFunctions",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
      "cloudfront:GetCachePolicy",
      "cloudfront:ListCachePolicies",
      "cloudfront:ListTagsForResource",
    ]
    resources = ["*"] # CloudFront read APIs do not support resource-level restrictions
  }

  # ACM — read certificate status (needed for validation resource refresh)
  statement {
    sid    = "ACMRead"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
    ]
    resources = ["*"] # ACM DescribeCertificate requires * or specific cert ARNs (unknown at plan time)
  }

  # Route53 — read hosted zone and records
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
    resources = ["*"] # Route53 read APIs require * for GetChange (change IDs are dynamic)
  }

  # KMS — read site key metadata (scoped to known key ARN)
  statement {
    sid    = "KMSRead"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
    ]
    resources = [aws_kms_key.site.arn]
  }

  # kms:ListAliases is an account-level list operation — IAM does not support
  # resource-level restrictions on it; resource must be *.
  statement {
    sid       = "KMSListAliases"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }

  # IAM — read roles and OIDC provider
  statement {
    sid    = "IAMRead"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:ListRoleTags",
    ]
    resources = [
      aws_iam_role.site_deploy.arn,
      aws_iam_role.terraform_plan.arn,
      aws_iam_role.terraform_apply.arn,
      aws_iam_openid_connect_provider.github.arn,
    ]
  }
}

# ---------------------------------------------------------------------------
# Role: terraform-apply — used by terraform-apply.yml (workflow_dispatch only)
# Trust: main branch only. workflow_dispatch sub claim is ref:refs/heads/main.
#
# IAM gap analysis — no gaps, no actions broader than necessary:
#
#   Includes all plan permissions (state backend + resource reads) plus:
#   S3: bucket lifecycle management
#   CloudFront: create/update/delete distributions, OAC, functions, policies
#   ACM: request and delete certificates
#   Route53: create/update/delete zones and records
#   KMS: create/update/delete keys and aliases (scoped to project prefix)
#   IAM: create/update/delete project roles, OIDC provider
#
#   Justification for resource wildcards:
#     CloudFront, ACM, Route53 APIs do not support resource-level ARN restrictions
#     on create/mutate operations at the IAM level. Scoped by aws:RequestedRegion
#     and account-level trust boundary.
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
  # State backend — identical to plan role
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
      data.aws_s3_bucket.terraform_state.arn,
      "${data.aws_s3_bucket.terraform_state.arn}/*",
    ]
  }

  statement {
    sid    = "StateDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable", # S3 backend calls this during init to verify the lock table exists
    ]
    resources = [local.terraform_locks_table_arn]
  }

  # kms:ResourceAliases is evaluated against the key's configured aliases,
  # not the access method — works whether S3 or Terraform uses the key ARN
  # directly or via alias. Avoids needing the exact key ARN at policy-write time.
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

  # S3 — full management of project site buckets (scoped by name prefix)
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
      "s3:GetBucketAcl",               # provider reads ACL on every bucket refresh
      "s3:GetBucketOwnershipControls",  # provider v5+ reads this on every bucket refresh
      "s3:ListBucket",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.project}-*"]
  }

  # CloudFront — create/update/delete all distribution components
  # * resource required: CloudFront APIs do not support resource-level restrictions
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
      "cloudfront:DescribeFunction", # provider uses DescribeFunction (not GetFunction) on refresh
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

  # ACM — request and manage certificates
  # * resource required: RequestCertificate does not accept resource-level ARN
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

  # Route53 — manage hosted zone and all record sets
  # GetChange requires * (change IDs are opaque tokens, not predictable ARNs)
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
    resources = ["*"] # Route53 GetChange requires *; ChangeResourceRecordSets scoped at zone level
  }

  # KMS — manage site encryption key (scoped directly to known key ARN).
  # kms:RequestAlias condition removed: the condition is absent when Terraform
  # calls DescribeKey/GetKeyPolicy with a key ID (not an alias), which causes
  # StringLike to evaluate false and deny the action.
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
    resources = [aws_kms_key.site.arn]
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

  # kms:ListAliases is an account-level list operation — IAM does not support
  # resource-level restrictions on it; resource must be *.
  statement {
    sid       = "KMSListAliases"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }

  # IAM — manage project roles and OIDC provider only (scoped by name prefix)
  statement {
    sid    = "IAMRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:UpdateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.project}-*"]
  }

  statement {
    sid    = "IAMOIDCManagement"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }
}

# ---------------------------------------------------------------------------
# Outputs — role ARNs referenced in GitHub Actions workflows
# ---------------------------------------------------------------------------

output "terraform_plan_role_arn" {
  description = "IAM role for terraform plan — GitHub secret: TF_PLAN_ROLE_ARN"
  value       = aws_iam_role.terraform_plan.arn
}

output "terraform_apply_role_arn" {
  description = "IAM role for terraform apply — GitHub secret: TF_APPLY_ROLE_ARN"
  value       = aws_iam_role.terraform_apply.arn
}
