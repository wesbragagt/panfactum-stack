variable "vault_name" {
  description = "The name of the vault instance. Must be unique in the Authentik system."
  type        = string
}

variable "vault_domain" {
  description = "The domain name of the Vault instance"
  type        = string
}

variable "authentik_domain" {
  description = "The domain name of the authentik instance"
  type        = string
}

variable "organization_name" {
  description = "The name of your organization"
  type        = string
}

variable "ui_description" {
  description = "The description to display in the Authentik web dashboard"
  type        = string
  default     = "A Hashicorp Vault cluster"
}

variable "ui_group" {
  description = "The section in the Authentik web dashboard that this will appear in"
  type        = string
  default     = "Vault"
}

variable "allowed_groups" {
  description = "Only members of these groups can access AWS"
  type        = set(string)
  default     = []
}

variable "media_configmap" {
  description = "The configmap holding the static media that Authentik will use"
  type        = string
}

variable "authentik_namespace" {
  description = "The kubernetes namespace where Authentik is deployed"
  type        = string
}


variable "vault_url" {
  description = "Origin (scheme, host and optional port) of the Vault instance. Null uses https://<vault_domain>."
  type        = string
  default     = null
}

variable "authentik_url" {
  description = "Origin (scheme, host and optional port) of the Authentik instance. Null uses https://<authentik_domain>."
  type        = string
  default     = null
}

variable "grant_types" {
  description = "OAuth2 grant types allowed for the Vault client. Authentik 2026.8 rejects authorization_code when the provider has none. Null leaves the attribute unset."
  type        = list(string)
  default     = null
}

variable "redirect_uri_type" {
  description = "Set redirect_uri_type on every allowed redirect URI. Provider 2026.8 reads back \"authorization\", so leaving it unset replans an update forever. Null leaves the attribute unset."
  type        = string
  default     = "authorization"
}
