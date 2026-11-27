variable "provisioner_image" {
  description = "Digest-pinned local-path-provisioner image."
  type        = string
  default     = "docker.io/rancher/local-path-provisioner:v0.0.37@sha256:e757967a5ec338f6a9b371c5a9688bedaa8c3578ea3dd4db329ea0084be0a86f"
}

variable "helper_image" {
  description = "Digest-pinned helper image used to create and remove volume directories."
  type        = string
  default     = "docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"
}

variable "host_path" {
  description = "Node directory for volumes. /var is writable on both kind and Talos nodes."
  type        = string
  default     = "/var/local-path-provisioner"
}

variable "reclaim_policy" {
  description = "StorageClass reclaim policy. Retain keeps volume data when a PVC is deleted."
  type        = string
  default     = "Retain"
  validation {
    condition     = contains(["Retain", "Delete"], var.reclaim_policy)
    error_message = "reclaim_policy must be Retain or Delete."
  }
}

variable "storage_class_name" {
  description = "Name of the StorageClass."
  type        = string
  default     = "local-path"
}

variable "default_storage_class_enabled" {
  description = "Mark the StorageClass as the cluster default."
  type        = bool
  default     = true
}

variable "namespace_labels" {
  description = "Additional labels on the local-path-storage namespace, e.g. Pod Security for the hostPath helper pods"
  type        = map(string)
  default     = {}
}

variable "kyverno_cel_policies_enabled" {
  description = "Use the CEL policy required by Kyverno 1.20 and later."
  type        = bool
  default     = false
}
