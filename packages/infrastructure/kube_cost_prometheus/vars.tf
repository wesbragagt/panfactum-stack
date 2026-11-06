variable "prometheus_chart_version" {
  description = "Pinned prometheus-community/prometheus chart version"
  type        = string
  default     = "29.43.0"
}
variable "namespace" {
  description = "Dedicated namespace for the local cost metrics backend"
  type        = string
  default     = "cost-monitoring"
}
variable "storage_class_name" {
  description = "Retained EBS storage class for local metrics; the PVC is protected from destroy"
  type        = string
  default     = "ebs-standard-retained"
}
variable "wait" {
  description = "Wait for the release and automatically roll back failed installs/upgrades"
  type        = bool
  default     = true
}
variable "extra_helm_values" {
  description = "Explicit chart overrides applied after the small-cluster profile"
  type        = any
  default     = {}
}
