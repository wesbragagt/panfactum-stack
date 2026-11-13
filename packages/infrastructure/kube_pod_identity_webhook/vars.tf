variable "region" {
  description = "AWS region injected as AWS_REGION and AWS_DEFAULT_REGION into mutated pods."
  type        = string
}

variable "name" {
  description = "Name of the Deployment, Service, PDB, certificates, RBAC and webhook configuration. Must differ from a running Helm release's name."
  type        = string
  default     = "pod-identity-webhook"
  validation {
    condition     = length(var.name) <= 48 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase DNS label of at most 48 characters."
  }
}

variable "namespace" {
  description = "Namespace for the webhook. kube-system exists before any add-on and is excluded from Kyverno mutation."
  type        = string
  default     = "kube-system"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a lowercase DNS label."
  }
}

variable "create_namespace" {
  description = "Create the namespace with kube_namespace. Leave false for kube-system or another existing namespace."
  type        = bool
  default     = false
}

variable "image" {
  description = "Webhook image pinned by digest."
  type        = string
  default     = "public.ecr.aws/eks/amazon-eks-pod-identity-webhook:v0.6.17@sha256:3071570e8e8cba6d5aff01e86d52bc91025a0578782aa9cd2b681480845b0a50"
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned with an @sha256 digest."
  }
}

variable "token_expiration_seconds" {
  description = "Lifetime of the projected service-account token passed to --token-expiration."
  type        = number
  default     = 86400
  validation {
    condition     = var.token_expiration_seconds >= 3600 && floor(var.token_expiration_seconds) == var.token_expiration_seconds
    error_message = "token_expiration_seconds must be an integer of at least 3600."
  }
}

variable "service_account_lookup_grace_period" {
  description = "Go duration a replica waits for an uncached ServiceAccount (fetched from the API) before admitting the pod without credentials. 0 disables the fallback."
  type        = string
  default     = "2s"
  validation {
    condition     = can(regex("^[1-9][0-9]*(ms|s)$", var.service_account_lookup_grace_period))
    error_message = "service_account_lookup_grace_period must be a positive Go duration in ms or s, such as 2s."
  }
}

variable "mutating_webhook_enabled" {
  description = "Create the MutatingWebhookConfiguration. Set false during migration while another webhook still mutates pods."
  type        = bool
  default     = true
}

variable "bootstrap_exempt_selector_expressions" {
  description = "objectSelector matchExpressions (ANDed) exempting pods the cluster needs before this webhook can answer. Never exempt a pod whose ServiceAccount uses IRSA."
  type = list(object({
    key      = string
    operator = string
    values   = optional(list(string), [])
  }))
  default = [
    { key = "k8s-app", operator = "NotIn", values = ["cilium", "cilium-envoy", "kube-dns"] },
    { key = "io.cilium/app", operator = "NotIn", values = ["operator"] },
  ]
  validation {
    condition     = alltrue([for e in var.bootstrap_exempt_selector_expressions : contains(["In", "NotIn", "Exists", "DoesNotExist"], e.operator)])
    error_message = "bootstrap_exempt_selector_expressions operators must be In, NotIn, Exists or DoesNotExist."
  }
}

variable "replicas" {
  description = "Webhook replicas. Each needs its own controller node; set 1 on a single-controller cluster."
  type        = number
  default     = 2
}
