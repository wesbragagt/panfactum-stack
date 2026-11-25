variable "cluster_name" {
  description = "Cluster name used for the jump host and its IAM resources. Must be unique in the AWS account."
  type        = string
}

variable "vpc_id" {
  description = "ID of the existing VPC."
  type        = string
}

variable "subnet_id" {
  description = "ID of the existing private subnet with outbound connectivity for the SSM agent."
  type        = string
}

variable "secondary_subnet_id" {
  description = "Optional private subnet in a different AZ of the same VPC, with independent outbound connectivity for the second SSM agent."
  type        = string
  default     = null
}

variable "resource_name" {
  description = "Optional IAM role, instance profile and security group name override. Instance discovery tags still use cluster_name."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "Arm64 instance type for the jump host."
  type        = string
  default     = "t4g.nano"
}

variable "talos_access" {
  description = "Private Kubernetes endpoint, controller addresses, and API security groups."
  type = object({
    kubernetes = object({
      host              = string
      security_group_id = string
    })
    talos = object({
      controller_ips    = list(string)
      security_group_id = string
    })
  })
  default = null
}

variable "talos_bootstrap" {
  description = "Fixed Talos document destinations for a new cluster that manages its own API ingress. Existing talos_access settings take precedence."
  type = object({
    kubernetes_host = string
    controller_ips  = list(string)
  })
  default = null
}

variable "port_forwarding_documents" {
  description = "Session Manager port forwarding documents keyed by a caller-defined name."
  type = map(object({
    name        = string
    host        = string
    port        = number
    description = optional(string, "")
  }))
  default = {}
}
