variable "images" {
  description = "Talos AMIs to build, keyed by image name."
  type = map(object({
    talos_version = string
    architecture  = optional(string, "arm64")
    extensions    = optional(list(string), ["siderolabs/ecr-credential-provider", "siderolabs/util-linux-tools"])
  }))
  validation {
    condition     = alltrue([for image in var.images : contains(["arm64", "amd64"], image.architecture)])
    error_message = "architecture must be arm64 or amd64."
  }
  validation {
    condition     = alltrue([for image in var.images : startswith(image.talos_version, "v")])
    error_message = "talos_version must start with v, for example v1.14.6."
  }
}

variable "name_prefix" {
  description = "Prefix for AMI, snapshot and IAM role names."
  type        = string
  default     = "talos"
}

variable "subnet_id" {
  description = "Private subnet with NAT egress for the helper instance that stages images in S3."
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile for the helper launch script. Omit to use the ambient AWS credentials."
  type        = string
  default     = null
}
