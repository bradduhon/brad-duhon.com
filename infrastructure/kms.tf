# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

# ---------------------------------------------------------------------------
# KMS CMK — encrypts both site S3 buckets.
#
# Key policy grants:
#   - Account root: full kms:* — allows IAM policies to delegate access.
#     The deploy role's IAM policy uses this to get kms:GenerateDataKey + kms:Decrypt.
#   - CloudFront service principal: kms:Decrypt + kms:GenerateDataKey scoped to
#     this account. S3 bucket policies (in the module) further restrict each
#     distribution via aws:SourceArn.
#
# The deploy role is intentionally NOT listed here — it inherits access through
# the root account statement + its own IAM policy. This avoids a circular
# dependency between this key and the IAM role (which needs the key ARN).
# ---------------------------------------------------------------------------

resource "aws_kms_key" "site" {
  description             = "Encrypts brad-duhon main and lab site S3 buckets"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true

  policy = data.aws_iam_policy_document.kms_site.json

  tags = merge(local.common_tags, { Purpose = "site-bucket-encryption" })
}

resource "aws_kms_alias" "site" {
  name          = "alias/${local.project}-site"
  target_key_id = aws_kms_key.site.key_id
}

data "aws_iam_policy_document" "kms_site" {
  statement {
    sid    = "EnableRootAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # CloudFront needs to decrypt objects when serving requests.
  # Scoped to this account; S3 bucket policies in the module add per-distribution
  # aws:SourceArn conditions as the second layer of restriction.
  statement {
    sid    = "AllowCloudFrontDecrypt"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}
