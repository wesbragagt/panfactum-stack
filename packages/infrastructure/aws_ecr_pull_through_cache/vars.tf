variable "docker_hub_username" {
  description = "The username of the Docker Hub user that will be used to pull images from Docker Hub"
  default     = null
  type        = string
}

variable "docker_hub_access_token" {
  description = "The access token of the Docker Hub user that will be used to pull images from Docker Hub"
  default     = null
  type        = string
  sensitive   = true
}

variable "github_username" {
  description = "The username of the GitHub user that will be used to pull images from GitHub"
  default     = null
  type        = string
}

variable "github_access_token" {
  description = "The access token of the GitHub user that will be used to pull images from GitHub"
  default     = null
  type        = string
  sensitive   = true
}

variable "authenticated_upstreams_enabled" {
  description = "Create GHCR/Docker Hub rules and secrets; false stages the three public rules without credentials."
  type        = bool
  default     = true

}
variable "repository_creation_templates" {
  description = "Optional prefix to lifecycle-policy JSON map. Empty preserves upstream defaults; null policy retains all images. AES256 encryption and mutable tags permit upstream cache refresh."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for prefix in keys(var.repository_creation_templates) : contains(["github", "docker-hub", "quay", "kubernetes", "ecr-public"], prefix)])
    error_message = "Only established cache prefixes may be managed."
  }
}
