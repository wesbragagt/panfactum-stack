variable "helm_version" {
  description = "Pinned Chaos Mesh chart version."
  type        = string
  default     = "2.8.8"
}

variable "container_runtime_socket" {
  description = "Host containerd CRI socket used by workload containers."
  type        = string
  default     = "/run/containerd/containerd.sock"
}
