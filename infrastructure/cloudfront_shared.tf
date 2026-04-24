# Copyright (c) 2026 Brad Duhon. All Rights Reserved.
# Confidential and Proprietary.
# Unauthorized copying of this file is strictly prohibited.

# ---------------------------------------------------------------------------
# Shared CloudFront resources — used by both site distributions via the module.
# ---------------------------------------------------------------------------

# URL rewrite function — Astro static output generates /about/index.html but
# visitors request /about. Without this rewrite, CloudFront returns 403 from S3.
resource "aws_cloudfront_function" "url_rewrite" {
  name    = "${local.project}-url-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrites extensionless URIs to /index.html for Astro static output"
  publish = true

  code = <<-EOF
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      if (!uri.includes('.')) {
        request.uri = uri.endsWith('/') ? uri + 'index.html' : uri + '/index.html';
      }

      return request;
    }
  EOF
}

# Security response headers — applied to both distributions.
# TODO Phase 4: tighten CSP once Astro island hydration patterns are confirmed.
# 'unsafe-inline' is required for Astro's hydration scripts until nonce-based
# CSP is implemented.
resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${local.project}-security-headers"
  comment = "Security headers for brad-duhon.com and lab.brad-duhon.com"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self';"
      override                = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = true
    }

    referrer_policy {
      referrer_policy = "no-referrer-when-downgrade"
      override        = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }

    content_type_options {
      override = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=()"
      override = true
    }
  }
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}
