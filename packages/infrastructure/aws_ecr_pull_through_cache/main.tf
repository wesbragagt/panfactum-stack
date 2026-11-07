terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

data "pf_aws_tags" "tags" {
  module = "aws_ecr_pull_through_cache"
}


##########################################################################
## Rule Setup
##########################################################################

resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"
  upstream_registry_url = "quay.io"
}

resource "aws_ecr_pull_through_cache_rule" "kubernetes" {
  ecr_repository_prefix = "kubernetes"
  upstream_registry_url = "registry.k8s.io"
}


resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

resource "aws_secretsmanager_secret" "docker" {
  lifecycle {
    precondition {
      condition     = var.docker_hub_username != null && var.docker_hub_access_token != null
      error_message = "Upstream username and token are required."
    }
  }
  count       = var.authenticated_upstreams_enabled ? 1 : 0
  name_prefix = "ecr-pullthroughcache/docker-hub-"
  description = "Used for authenticating with Docker Hub by the ECR pull through cache"
  tags        = data.pf_aws_tags.tags.tags
}

resource "aws_secretsmanager_secret_version" "docker" {
  count     = var.authenticated_upstreams_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.docker[0].id
  secret_string = jsonencode({
    username    = var.docker_hub_username
    accessToken = var.docker_hub_access_token
  })
}

resource "aws_ecr_pull_through_cache_rule" "docker" {
  count                 = var.authenticated_upstreams_enabled ? 1 : 0
  ecr_repository_prefix = "docker-hub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = aws_secretsmanager_secret.docker[0].arn
  depends_on            = [aws_secretsmanager_secret_version.docker]
}

resource "aws_secretsmanager_secret" "github" {
  lifecycle {
    precondition {
      condition     = var.github_username != null && var.github_access_token != null
      error_message = "Upstream username and token are required."
    }
  }
  count       = var.authenticated_upstreams_enabled ? 1 : 0
  name_prefix = "ecr-pullthroughcache/github-"
  description = "Used for authenticating with GitHub by the ECR pull through cache"
  tags        = data.pf_aws_tags.tags.tags
}

resource "aws_secretsmanager_secret_version" "github" {
  count     = var.authenticated_upstreams_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.github[0].id
  secret_string = jsonencode({
    username    = var.github_username
    accessToken = var.github_access_token
  })
}

resource "aws_ecr_pull_through_cache_rule" "github" {
  count                 = var.authenticated_upstreams_enabled ? 1 : 0
  ecr_repository_prefix = "github"
  upstream_registry_url = "ghcr.io"
  credential_arn        = aws_secretsmanager_secret.github[0].arn
  depends_on            = [aws_secretsmanager_secret_version.github]
}

# Preserve addresses for callers using the default five-rule configuration.
moved {
  from = aws_secretsmanager_secret.docker
  to   = aws_secretsmanager_secret.docker[0]
}
moved {
  from = aws_secretsmanager_secret.github
  to   = aws_secretsmanager_secret.github[0]
}
moved {
  from = aws_secretsmanager_secret_version.docker
  to   = aws_secretsmanager_secret_version.docker[0]
}
moved {
  from = aws_secretsmanager_secret_version.github
  to   = aws_secretsmanager_secret_version.github[0]
}
moved {
  from = aws_ecr_pull_through_cache_rule.docker
  to   = aws_ecr_pull_through_cache_rule.docker[0]
}
moved {
  from = aws_ecr_pull_through_cache_rule.github
  to   = aws_ecr_pull_through_cache_rule.github[0]
}

resource "aws_ecr_repository_creation_template" "cache" {
  for_each             = var.repository_creation_templates
  prefix               = each.key
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "MUTABLE"
  encryption_configuration { encryption_type = "AES256" }
  lifecycle_policy = each.value
}
