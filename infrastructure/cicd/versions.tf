// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial backend config — connection details supplied at init time:
  #   terraform init -backend-config=../shared/backend.hcl \
  #                  -backend-config="key=cicd/terraform.tfstate"
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"
}
