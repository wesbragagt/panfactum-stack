
variable "alloy_chart_version" {
  description = "The version of the grafana/alloy helm chart to deploy"
  type        = string
  default     = "0.3.1"
}

variable "pull_through_cache_enabled" {
  description = "Whether to use the ECR pull through cache for the deployed images"
  type        = bool
  default     = true
}

variable "log_level" {
  description = "The log level for the Alloy pods"
  type        = string
  default     = "warn"
  validation {
    condition     = contains(["info", "error", "debug", "warn"], var.log_level)
    error_message = "Invalid log_level provided."
  }
}

variable "vpa_enabled" {
  description = "Whether the VPA resources should be enabled"
  type        = bool
  default     = true
}

variable "monitoring_enabled" {
  description = "Whether to add active monitoring to the deployed systems"
  type        = bool
  default     = false
}

variable "wait" {
  description = "Wait for resources to be in a ready state before proceeding. Disabling this flag will allow upgrades to proceed faster but will disable automatic rollbacks. As a result, manual intervention may be required for deployment failures."
  type        = bool
  default     = true
}


variable "extra_helm_values" {
  description = "Additional chart values applied after module defaults for explicit deployment-specific overrides"
  type        = any
  default     = {}
}

variable "kubernetes_events_enabled" {
  description = "Collect cluster-wide Kubernetes events using one independent Alloy collector."
  type        = bool
  default     = false
}
variable "kubernetes_events_image" {
  description = "Events collector image; default matches Alloy chart 0.3.1."
  type        = string
  default     = "docker.io/grafana/alloy:v1.1.0"
}

variable "redaction_enabled" {
  description = "Opt in to raw-line redaction before parsing or forwarding (not historical logs)."
  type        = bool
  default     = false
}
variable "redaction_categories" {
  description = "Enabled pattern categories. Phone and explicit personal fields are opt in; operational IPs/names remain intact."
  type        = list(string)
  default     = ["credentials", "email", "ssn", "cards"]
  validation {
    condition     = alltrue([for c in var.redaction_categories : contains(["credentials", "email", "ssn", "cards", "phones", "personal_fields"], c)])
    error_message = "Unknown redaction category."
  }
}
variable "redaction_extra_patterns" {
  description = "Additional RE2 expressions with exactly one value capture; no secret literals. Validate with the pinned Alloy binary before deployment."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for p in var.redaction_extra_patterns : can(regexall(p, "")) && length(p) > 0 && length(p) <= 2048])
    error_message = "Extra patterns must be valid nonempty RE2 expressions up to 2048 characters."
  }
}

variable "redaction_profiles_enabled" {
  description = "Enable annotation-selected additional Pod redaction; requires global baseline enabled. Events remain global."
  type        = bool
  default     = false
}
variable "redaction_profiles" {
  description = "Central additional categories per allowed Pod profile; baseline always runs once."
  type        = map(list(string))
  default     = { standard = [], strict = ["phones", "personal_fields"] }
  validation {
    condition     = alltrue([for k, categories in var.redaction_profiles : contains(["standard", "strict"], k) && alltrue([for c in categories : contains(["credentials", "email", "ssn", "cards", "phones", "personal_fields"], c)])])
    error_message = "Only standard/strict profiles and catalog categories are supported."
  }
}
