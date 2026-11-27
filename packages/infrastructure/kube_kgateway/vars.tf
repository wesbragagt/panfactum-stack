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

variable "enable_public_load_balancer" {
  description = "Provision an AWS Network Load Balancer for the HTTPS Gateway. Disable to serve HTTPS through a ClusterIP Service."
  type        = bool
  default     = true
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

variable "local_http_port" {
  description = "Local clusters only: serve plain HTTP on this port from a ClusterIP Service instead of HTTPS behind an NLB"
  type        = number
  default     = null
}

variable "local_routes" {
  description = "Local mode only: HTTPRoutes attached to the gateway, keyed by route name"
  type = map(object({
    hostname  = string
    namespace = string
    service   = string
    port      = number
  }))
  default = {}
}

variable "crd_drift_engine" {
  description = "kubectl_manifest drift_engine for the kgateway CRDs. null keeps the provider default (client); \"server\" compares against an SSA dry-run, so int64 schema maximums stop showing as drift on every plan."
  type        = string
  default     = null
}
