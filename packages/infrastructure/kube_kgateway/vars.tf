variable "namespace" {
  type    = string
  default = "kgateway-system"
}

variable "gateway_name" {
  type    = string
  default = "public"
}

variable "domain" {
  description = "The listener accepts *.<domain>."
  type        = string
}

variable "dns_hostnames" {
  description = "Hostnames external-dns publishes for the NLB."
  type        = list(string)
}

variable "load_balancer_name" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "tls_secret_name" {
  type    = string
  default = "ingress-tls"
}

variable "tls_secret_namespace" {
  type    = string
  default = "cert-manager"
}

variable "controller_replicas" {
  type    = number
  default = 1
}

variable "proxy_replicas" {
  type    = number
  default = 2
}

variable "node_selector" {
  type    = map(string)
  default = {}
}

variable "tolerations" {
  description = "Tolerations for the kgateway controller and gateway proxy pods"
  type        = list(map(string))
  default     = []
}
