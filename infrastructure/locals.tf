# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

locals {
  project     = "brad-duhon"
  main_domain = "brad-duhon.com"
  lab_domain  = "lab.brad-duhon.com"
  github_org  = "bradduhon"
  github_repo = "brad-duhon.com"

  common_tags = {
    Project     = "brad-duhon-site"
    Environment = "production"
    Owner       = "Brad Duhon"
    ManagedBy   = "Terraform"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
