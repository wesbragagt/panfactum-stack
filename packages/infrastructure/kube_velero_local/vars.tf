variable "velero_helm_version" {
  description = "The version of the velero helm chart"
  type        = string
  default     = "9.1.3"
}

variable "velero_image_repository" {
  description = "Repository of the Velero server and node-agent image"
  type        = string
  default     = "docker.io/velero/velero"
}

variable "velero_image_tag" {
  description = "Tag of the Velero server and node-agent image; may carry an @sha256 digest"
  type        = string
  default     = "v1.16.0"
}

variable "aws_plugin_image" {
  description = "Full reference of the velero-plugin-for-aws image"
  type        = string
  default     = "docker.io/velero/velero-plugin-for-aws:v1.12.0"
}

variable "bucket" {
  description = "Bucket of the default BackupStorageLocation; it must already exist"
  type        = string
}

variable "prefix" {
  description = "Directory under the bucket that holds this cluster's backups"
  type        = string
  default     = ""
}

variable "s3_url" {
  description = "S3-compatible endpoint URL reachable from Pods"
  type        = string
}

variable "region" {
  description = "Region label sent to the S3 endpoint"
  type        = string
  default     = "us-west-2"
}

variable "access_key" {
  description = "Static access key for the S3 endpoint"
  type        = string
  sensitive   = true
}

variable "secret_key" {
  description = "Static secret key for the S3 endpoint"
  type        = string
  sensitive   = true
}

variable "log_level" {
  description = "The log level for the Velero pods"
  type        = string
  default     = "warning"
}

variable "extra_helm_values" {
  description = "Explicit chart values applied after module defaults"
  type        = any
  default     = {}
}
