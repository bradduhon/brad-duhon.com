# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "brad-duhon-terraform-state"
    key            = "brad-duhon-site/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "brad-duhon-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/brad-duhon-terraform-state"
  }
}
