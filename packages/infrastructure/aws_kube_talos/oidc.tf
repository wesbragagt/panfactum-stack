data "aws_caller_identity" "oidc" {}

data "external" "oidc_jwks" {
  program = ["python3", "${path.module}/oidc-jwks.py"]
  query = {
    private_key = local.machine_secrets.certs.k8s_serviceaccount.key
  }
}

# Public JWKS must retain every active signing key during rotation.
locals {
  canary_oidc_issuer_url = format("https://%s", aws_s3_bucket.canary_oidc[0].bucket_regional_domain_name)
  canary_oidc_jwks       = jsondecode(nonsensitive(data.external.oidc_jwks.result.jwks_json))
}

resource "aws_s3_bucket" "canary_oidc" {
  count         = 1
  bucket        = "${var.cluster_name}-oidc-${data.aws_caller_identity.oidc.account_id}"
  force_destroy = false
  tags = merge(data.pf_aws_tags.tags.tags, {
    Name    = "${var.cluster_name}-oidc"
    Purpose = "Public talos-2 service-account OIDC discovery and verification keys"
  })
}

resource "aws_s3_bucket_ownership_controls" "canary_oidc" {
  count  = 1
  bucket = aws_s3_bucket.canary_oidc[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "canary_oidc" {
  count                   = 1
  bucket                  = aws_s3_bucket.canary_oidc[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "canary_oidc" {
  count  = 1
  bucket = aws_s3_bucket.canary_oidc[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "canary_oidc" {
  count  = 1
  bucket = aws_s3_bucket.canary_oidc[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "canary_oidc_jwks" {
  count         = 1
  bucket        = aws_s3_bucket.canary_oidc[0].id
  key           = "keys.json"
  content       = jsonencode(local.canary_oidc_jwks)
  content_type  = "application/json"
  cache_control = "public, max-age=60"
  depends_on = [
    aws_s3_bucket_versioning.canary_oidc[0],
    aws_s3_bucket_server_side_encryption_configuration.canary_oidc[0],
    aws_s3_bucket_ownership_controls.canary_oidc[0],
  ]
}

resource "aws_s3_object" "canary_oidc_discovery" {
  count  = 1
  bucket = aws_s3_bucket.canary_oidc[0].id
  key    = ".well-known/openid-configuration"
  content = jsonencode({
    issuer                                = local.canary_oidc_issuer_url
    jwks_uri                              = format("%s/keys.json", local.canary_oidc_issuer_url)
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })
  content_type  = "application/json"
  cache_control = "public, max-age=60"
  depends_on = [
    aws_s3_bucket_versioning.canary_oidc[0],
    aws_s3_bucket_server_side_encryption_configuration.canary_oidc[0],
    aws_s3_bucket_ownership_controls.canary_oidc[0],
  ]
}

resource "aws_s3_bucket_policy" "canary_oidc" {
  count  = 1
  bucket = aws_s3_bucket.canary_oidc[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicOIDCDiscoveryOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          format("%s/.well-known/openid-configuration", aws_s3_bucket.canary_oidc[0].arn),
          format("%s/keys.json", aws_s3_bucket.canary_oidc[0].arn),
        ]
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.canary_oidc[0].arn,
          format("%s/*", aws_s3_bucket.canary_oidc[0].arn),
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.canary_oidc[0]]
}

# AWS verifies S3-hosted JWKS TLS using its trusted CA library. Omit a hard-coded
# thumbprint list; IAM retrieves the top intermediate thumbprint on creation.
# https://docs.aws.amazon.com/IAM/latest/APIReference/API_CreateOpenIDConnectProvider.html
resource "aws_iam_openid_connect_provider" "canary_oidc" {
  count          = 1
  url            = local.canary_oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]
  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-oidc"
  })
  depends_on = [
    aws_s3_bucket_policy.canary_oidc[0],
    aws_s3_object.canary_oidc_jwks[0],
    aws_s3_object.canary_oidc_discovery[0],
  ]
}

output "oidc_issuer_url" {
  description = "Public service-account issuer; configure Talos to sign tokens with this issuer."
  value       = local.canary_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider for sts.amazonaws.com service-account tokens."
  value       = aws_iam_openid_connect_provider.canary_oidc[0].arn
}
