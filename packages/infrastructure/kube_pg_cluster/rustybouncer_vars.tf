variable "pooler_implementation" {
  description = "Connection pooler owner: CNPG PgBouncer (default) or experimental standalone RustyBouncer. Switching existing endpoints requires a reviewed migration."
  type        = string
  default     = "pgbouncer"
  validation {
    condition     = contains(["pgbouncer", "rustybouncer"], var.pooler_implementation)
    error_message = "pooler_implementation must be pgbouncer or rustybouncer."
  }
}

variable "rustybouncer_image" {
  description = "Immutable image containing d9d985fbdfaa66e8f0ba9e9b54ae31c4758d5fe0 TLS/auth_query support or a verified compatible successor. Entrypoint must accept a positional TOML path. The older experimental image is incompatible."
  type        = string
  default     = null
  validation {
    condition     = var.rustybouncer_image == null ? true : can(regex("^[^@[:space:]]+@sha256:[0-9a-f]{64}$", var.rustybouncer_image))
    error_message = "rustybouncer_image must use an immutable repository@sha256:<64 lowercase hex> reference."
  }
}

variable "rustybouncer_image_pull_secrets" {
  description = "Existing namespace-local image pull Secret names for the RustyBouncer Pod. ECR node credential providers can instead authorize pulls."
  type        = list(string)
  default     = []
}

variable "rustybouncer_config" {
  description = "RustyBouncer-specific pool and timeout settings. PgBouncer protocol tuning inputs do not configure RustyBouncer; pgbouncer_* resource bounds and enable flags are shared. Only session/transaction pooling is supported."
  type = object({
    pool_mode               = optional(string, "session")
    max_clients             = optional(number, 1000)
    pool_size               = optional(number, 16)
    max_pool_backends       = optional(number, 64)
    pool_idle_timeout_ms    = optional(number, 30000)
    pool_server_lifetime_ms = optional(number, 300000)
    probe_interval_ms       = optional(number, 1000)
    probe_timeout_ms        = optional(number, 3000)
    wait_timeout_ms         = optional(number, 10000)
    startup_timeout_ms      = optional(number, 5000)
  })
  default = {}
  validation {
    condition     = contains(["session", "transaction"], var.rustybouncer_config.pool_mode)
    error_message = "RustyBouncer supports session or transaction pooling; statement pooling is unavailable."
  }
  validation {
    condition = alltrue([for key, value in var.rustybouncer_config :
      key == "pool_mode" ? true : try(value > 0 && floor(value) == value, false)
    ]) && var.rustybouncer_config.pool_size <= var.rustybouncer_config.max_pool_backends
    error_message = "RustyBouncer sizes/timeouts must be positive integers and pool_size must not exceed max_pool_backends."
  }
}
