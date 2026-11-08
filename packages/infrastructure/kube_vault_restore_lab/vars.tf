variable "namespace" {
  description = "Dedicated migration namespace; never an existing production namespace."
  type        = string
  default     = "vault-migration-lab"
  validation {
    condition     = startswith(var.namespace, "vault-migration-") && length(var.namespace) <= 63
    error_message = "Use a dedicated namespace beginning with vault-migration-."
  }
}
variable "name" {
  description = "Dedicated server and identity name."
  type        = string
  default     = "original-vault-restore"
  validation {
    condition     = length(var.name) <= 48 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "Use a lowercase DNS label of at most 48 characters."
  }
}
variable "create_namespace" {
  description = "Own the lab namespace and aggregate quota. Additional instances must reuse that owner's namespace without co-ownership."
  type        = bool
  default     = true
}
variable "memory_request_quota_mi" {
  description = "Aggregate lab memory request budget in MiB; only the namespace owner manages this quota."
  type        = number
  default     = 448
  validation {
    condition     = var.memory_request_quota_mi >= 128 && var.memory_request_quota_mi <= 448 && floor(var.memory_request_quota_mi) == var.memory_request_quota_mi
    error_message = "The aggregate lab request budget must be an integer between 128 and 448 MiB."
  }
}
variable "image" {
  description = "Immutable image containing the exact server and any preinstalled plugins."
  type        = string
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "An immutable image digest is required."
  }
}
variable "engine" {
  description = "Server configuration dialect; this never upgrades or restores data automatically."
  type        = string
  default     = "vault"
  validation {
    condition     = contains(["vault", "openbao"], var.engine)
    error_message = "Choose vault or openbao."
  }
}
variable "plugins" {
  description = "Preinstalled OpenBao plugins. Binary hashes must be verified against signed release artifacts."
  type = list(object({
    type      = string
    name      = string
    command   = string
    version   = string
    sha256sum = string
  }))
  default = []
  validation {
    condition = alltrue([for p in var.plugins :
      contains(["kms", "secret"], p.type) && can(regex("^[a-zA-Z0-9_-]+$", p.name)) &&
      can(regex("^[a-zA-Z0-9_-]+$", p.command)) && can(regex("^[0-9a-f]{64}$", p.sha256sum))
    ])
    error_message = "Declare only named KMS/secret plugins with a basename command and SHA256."
  }
}
variable "seal_key_arn" {
  description = "Existing regional Vault unseal key ARN; the module never owns or changes this key."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[^:]*:kms:[^:]+:[0-9]{12}:key/", var.seal_key_arn))
    error_message = "Supply the existing KMS key ARN, not an alias or wildcard."
  }
}
variable "server_enabled" {
  description = "Start the empty server only after effective network and IAM isolation are verified. Does not initialize or restore."
  type        = bool
  default     = false
}
variable "isolation_verified" {
  description = "Explicit assertion backed by current live isolation evidence, not by policy readiness alone."
  type        = bool
  default     = false
}
variable "storage_class" {
  description = "Existing encrypted storage class for the dedicated recovery PVC."
  type        = string
  default     = "ebs-standard-retained"
}
variable "storage_size" {
  description = "Dedicated bounded recovery volume capacity."
  type        = string
  default     = "1Gi"
}
variable "node_selector" {
  description = "Explicit placement within the approved migration capacity budget."
  type        = map(string)
}
variable "oidc_provider_arn" {
  description = "Explicit provider ARN for the self-managed cluster."
  type        = string
}
variable "oidc_issuer_url" {
  description = "Explicit issuer URL paired with the provider ARN."
  type        = string
}
