variable "service_account" {
  description = "The name of the service account that should be able to assume the AWS permissions."
  type        = string
}

variable "custom_oidc_enabled" {
  description = "Select custom OIDC at plan time when the provider ARN and issuer URL are created in the same plan."
  type        = bool
  default     = false
  nullable    = false
}

variable "cluster_name" {
  description = "Explicit Kubernetes cluster name. Defaults to Panfactum kubeconfig metadata."
  type        = string
  default     = null
}

variable "iam_tags" {
  description = "Existing IAM base tags to preserve during state adoption. Defaults to Panfactum AWS tags."
  type        = map(string)
  default     = null
}

variable "service_account_namespace" {
  description = "The namespace of the service account."
  type        = string
}

variable "iam_policy_json" {
  description = "An IAM policy document in rendered JSON string form."
  type        = string
}

variable "annotate_service_account" {
  description = "Whether or not to annotate the service account"
  type        = bool
  default     = true
}

variable "ip_allow_list" {
  description = "A list of IPs that can use the service account token to authenticate with AWS API"
  type        = list(string)
  default     = []
}

variable "allow_public_s3_presigned_urls" {
  description = "Whether to allow the service account to generate presigned URLs that will be publicly accessible"
  type        = bool
  default     = false
}


variable "oidc_provider_arn" {
  description = "Existing self-managed cluster OIDC provider ARN. Supply with oidc_issuer_url; null preserves EKS discovery."
  type        = string
  default     = null
  validation {
    condition     = var.oidc_provider_arn == null ? true : can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/.+", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be an IAM OIDC provider ARN."
  }
}
variable "oidc_issuer_url" {
  description = "HTTPS issuer URL paired with oidc_provider_arn. Custom identities require the exact namespace/service-account subject and sts.amazonaws.com audience."
  type        = string
  default     = null
  validation {
    condition     = var.oidc_issuer_url == null ? true : startswith(var.oidc_issuer_url, "https://") && !strcontains(var.oidc_issuer_url, "?")
    error_message = "oidc_issuer_url must be an HTTPS issuer URL without query parameters."
  }
}
variable "cluster_subnet_ids" {
  description = "Explicit cluster subnet IDs for IP restrictions. Null preserves tagged EKS subnet discovery; an empty set disables discovery."
  type        = set(string)
  default     = null
}
variable "ip_restrictions_enabled" {
  description = "Attach Panfactum source-IP deny policies (default true). Explicit false supports self-managed nodes with changing public egress; OIDC principal/subject/audience restrictions remain enforced."
  type        = bool
  default     = true
}

variable "local_static_credentials_enabled" {
  description = "Development simulators only: create an IAM user, access key and Kubernetes Secret <service_account>-aws-static instead of IRSA/EKS discovery. The role trusts only that user. Never use against real AWS."
  type        = bool
  default     = false
}
