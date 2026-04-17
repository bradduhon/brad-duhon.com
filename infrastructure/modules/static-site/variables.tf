# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

variable "domain_name" {
  description = "Full domain name for this site (e.g. brad-duhon.com or lab.brad-duhon.com)"
  type        = string
}

variable "site_label" {
  description = "Short label used in resource names (e.g. 'main' or 'lab')"
  type        = string
}

variable "project" {
  description = "Project prefix used in resource names"
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone ID for the parent domain"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN used to encrypt the S3 bucket"
  type        = string
}

variable "cf_function_arn" {
  description = "ARN of the shared CloudFront viewer-request URL rewrite function"
  type        = string
}

variable "cf_response_headers_policy_id" {
  description = "ID of the shared CloudFront response headers policy"
  type        = string
}

variable "cf_cache_policy_id" {
  description = "ID of the CloudFront cache policy to apply"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
