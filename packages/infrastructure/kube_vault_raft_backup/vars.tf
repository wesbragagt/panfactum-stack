variable "name" {
  description = "Dedicated CronJob and ServiceAccount name."
  type        = string
  default     = "vault-raft-backup"
}
variable "namespace" {
  description = "Existing namespace; this module never owns or deletes it."
  type        = string
  default     = "vault"
}
variable "vault_address" {
  description = "Existing private Vault-compatible API endpoint."
  type        = string
  default     = "http://vault-active.vault.svc.cluster.local:8200"
}
variable "vault_auth_mount" {
  description = "Existing Kubernetes auth mount, without auth/ prefix."
  type        = string
  default     = "kubernetes"
}
variable "image" {
  description = "Digest-pinned image containing bash, curl, jq, aws CLI and sha256sum. Supply an index digest for multiple architectures."
  type        = string
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "The backup image must have an immutable SHA256 digest."
  }
}
variable "s3_bucket" {
  description = "Existing private snapshot bucket; its policy, lifecycle and contents remain separately owned."
  type        = string
}
variable "aws_cli_cache_directory" {
  description = "The chosen image's absolute HOME/.aws path, mounted as private ephemeral workspace so AWS CLI web-identity caching works with a read-only root filesystem."
  type        = string
  validation {
    condition     = startswith(var.aws_cli_cache_directory, "/") && endswith(var.aws_cli_cache_directory, "/.aws") && !strcontains(var.aws_cli_cache_directory, "..")
    error_message = "Supply the image's absolute .aws directory, without traversal components."
  }
}
variable "s3_prefix" {
  description = "Dedicated object prefix, excluding every production etcd prefix."
  type        = string
  default     = "vault/raft-scheduled"
  validation {
    condition     = length(trim(var.s3_prefix, "/")) > 0 && !strcontains(var.s3_prefix, "..")
    error_message = "A nonempty dedicated object prefix without traversal components is required."
  }
}
variable "s3_kms_key_arn" {
  description = "Existing SSE-KMS key ARN required by the bucket, not the Vault unseal key."
  type        = string
}
variable "schedule" {
  description = "Cron expression. Check the cluster power schedule before selecting it."
  type        = string
  default     = "20 * * * *"
}
variable "time_zone" {
  description = "IANA time zone for CronJob scheduling."
  type        = string
  default     = "Etc/UTC"
}
variable "suspended" {
  description = "Suspend scheduled jobs while still permitting controlled manual verification."
  type        = bool
  default     = false
}
variable "max_snapshot_mb" {
  description = "Snapshot size bound; workspace reserves space for the snapshot and a downloaded verification copy."
  type        = number
  default     = 64
  validation {
    condition     = var.max_snapshot_mb >= 1 && var.max_snapshot_mb <= 1024 && floor(var.max_snapshot_mb) == var.max_snapshot_mb
    error_message = "Snapshot size bound must be an integer from 1 through 1024 MiB."
  }
}
variable "node_selector" {
  description = "Explicit placement; reserve backup resources before installation."
  type        = map(string)
  default     = {}
}
variable "tolerations" {
  description = "Pod tolerations for the selected backup nodes."
  type        = list(object({ key = optional(string), operator = optional(string), value = optional(string), effect = optional(string) }))
  default     = []
}
variable "labels" {
  description = "Additional metadata labels; immutable image/cache-safety labels are controlled by the module."
  type        = map(string)
  default     = {}
}
variable "oidc_provider_arn" {
  description = "Explicit self-managed issuer provider; null retains the nested module's EKS discovery behavior."
  type        = string
  default     = null
}
variable "oidc_issuer_url" {
  description = "Explicit HTTPS issuer paired with oidc_provider_arn."
  type        = string
  default     = null
}
variable "ip_restrictions_enabled" {
  description = "Use the nested auth module's source-IP restrictions; false is an explicit self-managed-cluster choice."
  type        = bool
  default     = true
}
variable "cluster_subnet_ids" {
  description = "Explicit subnet IDs for IAM source-IP restrictions; null preserves tagged discovery."
  type        = set(string)
  default     = null
}
