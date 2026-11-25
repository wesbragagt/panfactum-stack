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

variable "instance_type" {
  description = "Arm64 instance type for the jump host."
  type        = string
  default     = "t4g.nano"
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
