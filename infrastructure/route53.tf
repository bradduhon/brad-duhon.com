# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

# ---------------------------------------------------------------------------
# Route 53 hosted zone for brad-duhon.com.
#
# After apply: copy the nameservers from the `route53_nameservers` output
# and set them at your domain registrar. ACM cert validation (inside the
# static-site module) proceeds once NS delegation is live.
#
# lab.brad-duhon.com is a subdomain — its records are managed within this
# same hosted zone. No separate zone needed.
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  name = local.main_domain
  tags = local.common_tags
}
