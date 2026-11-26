variable "cluster_name" {
  description = "The name of the Talos cluster. Used for the Talos/Kubernetes cluster name and AWS resource names."
  type        = string
}

variable "vpc_id" {
  description = "The id for the VPC that the cluster should be deployed into"
  type        = string
}

variable "control_plane_private_ips" {
  description = "Optional fixed private IPs for control plane nodes, one per node in control_plane_subnets order. A fixed address lets an SSM tunnel target the controller before it exists, so the first bootstrap needs no public ingress. Changing it replaces the nodes."
  type        = list(string)
  default     = []
}

variable "control_plane_subnets" {
  description = "Subnet names (Name tag), one per control plane node in order. Use PUBLIC subnets only with control_plane_public_ip_enabled. Names must be unique. Node state is keyed by list position, so only append entries; reordering or removing one replaces nodes."
  type        = list(string)
  default     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]

  validation {
    condition     = length(distinct(var.control_plane_subnets)) == length(var.control_plane_subnets)
    error_message = "control_plane_subnets must not repeat a subnet name."
  }
}

variable "bootstrap_control_plane" {
  description = "Subnet name of the controller that runs talos_machine_bootstrap and serves as the cluster endpoint fallback. Null uses the first entry of control_plane_subnets. Must be one of the active subnets."
  type        = string
  default     = null
}

variable "worker_subnets" {
  description = "Subnet names (Name tag) for the worker nodes. PRIVATE subnets need a NAT route for outbound access; PUBLIC subnets also need worker_public_ip_enabled."
  type        = list(string)
  default     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
}

variable "control_plane_count" {
  description = "Number of on-demand control plane nodes, placed in control_plane_subnets order. Above 1 requires private_api_dns_name so nodes do not depend on one controller's address."
  type        = number
  default     = 1

  # etcd quorum: 3 members tolerate one loss and 5 tolerate two; even counts add no tolerance.
  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3 or 5."
  }
}

variable "controller_instance_profile" {
  description = "IAM instance profile name for controllers. Changing it on a running controller re-associates the profile in place."
  type        = string
  default     = null
}

variable "control_plane_public_ip_enabled" {
  description = "Give controllers a public IP and an Elastic IP API endpoint. Off by default: controllers sit in private subnets and operators reach them through an SSM tunnel, which needs private_api_dns_name or control_plane_private_ips."
  type        = bool
  default     = false
}

variable "private_api_dns_name" {
  description = "Optional private DNS name (e.g. api.example.internal) used as the cluster endpoint. Creates a private Route 53 A record with every controller private IP. Clients handle failover between those addresses. Node-local components can use KubePrism."
  type        = string
  default     = null
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes. T2 types are not supported by Talos."
  type        = string
  default     = "t4g.medium"
}

variable "control_plane_instance_types" {
  description = "Optional per-node instance types in control_plane_subnets order, overriding control_plane_instance_type. A change resizes that controller in place (stop, modify, start)."
  type        = list(string)
  default     = []
}

variable "control_plane_workloads_enabled" {
  description = "Whether controllers join the Panfactum controller class: they get the panfactum.com/class=controller label, lose the default control-plane taint and get the controller=true:NoSchedule taint. When false, controllers keep the default Talos control-plane taint and no class label."
  type        = bool
  default     = true
}

variable "worker_count" {
  description = "Number of Spot worker nodes in the worker ASG. 0 creates no Spot ASG, for clusters where Karpenter launches every worker."
  type        = number
  default     = 0
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes. T2 types are not supported by Talos."
  type        = string
  default     = "t4g.medium"
}

variable "worker_instance_types" {
  description = "Optional Spot instance types for workers, tried by price and capacity. Overrides worker_instance_type when set."
  type        = list(string)
  default     = []
}

variable "on_demand_worker_subnets" {
  description = "Optional subnet names (Name tag) that each get one on-demand worker, in a separate ASG from the Spot workers. Remove these subnets from worker_subnets to keep Spot out of those zones."
  type        = list(string)
  default     = []
}

variable "root_volume_size_gb" {
  description = "Size of each node's root EBS volume in GB."
  type        = number
  default     = 20
}

variable "talos_version" {
  description = "Talos version. Selects the official Sidero Labs AMI and the machine config contract."
  type        = string
  default     = "v1.14.6"
}

variable "kube_version" {
  description = "Kubernetes version (e.g., 1.36.5). Pinned so a talos provider upgrade does not change it; upgrade with `talosctl upgrade-k8s`."
  type        = string
  default     = "1.36.5"
}

variable "talos_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Talos API (TCP 50000). Empty by default; operators reach the API through the SSM tunnel instead."
  type        = list(string)
  default     = []
}

variable "kube_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API (TCP 6443) on the control plane's Elastic IP."
  type        = list(string)
  default     = []
}

variable "talos_api_endpoint" {
  description = "Override the Talos API endpoint for the provider and talosconfig, with optional port. An empty string derives the endpoint from talos_access_transport. Null uses the Elastic IP and requires control_plane_public_ip_enabled."
  type        = string
  default     = ""
}

variable "talos_access_transport" {
  description = "Talos operator transport. bootstrap_public selects the temporary public load balancer. vpn selects the configured bootstrap controller's fixed private IP. ssm selects the module hook's loopback address and enables loopback SANs. The empty default retains legacy loopback behavior."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = contains(["", "vpn", "ssm", "bootstrap_public"], var.talos_access_transport)
    error_message = "talos_access_transport must be vpn, ssm, bootstrap_public, or empty."
  }
}

variable "bootstrap_public" {
  description = "Overrides for the temporary public NLB. Public transport enables it and detects the runner's public IPv4 address by default. Set operator_cidr to override discovery. Set enabled to false after verifying private access to retire the public NLB."
  type = object({
    enabled       = optional(bool, true)
    operator_cidr = optional(string)
  })
  default = null

  validation {
    condition     = try(var.bootstrap_public.operator_cidr, null) == null || try(cidrnetmask(var.bootstrap_public.operator_cidr) != "0.0.0.0", false)
    error_message = "bootstrap_public.operator_cidr must be an IPv4 CIDR narrower than /0."
  }
}

variable "kube_api_extra_sans" {
  description = "Additional DNS names or IPs in the Kubernetes API certificate."
  type        = list(string)
  default     = []
}

variable "talos_api_extra_sans" {
  description = "Additional DNS names or IPs in the Talos API certificate. Include the endpoint name or IP if Talos does not discover it on boot."
  type        = list(string)
  default     = []
}

variable "kube_api_source_security_groups" {
  description = "Security group IDs allowed to reach Kubernetes TCP 6443, keyed by stable caller-chosen names."
  type        = map(string)
  default     = {}
}

variable "talos_api_source_security_groups" {
  description = "Security group IDs allowed to reach Talos TCP 50000, keyed by stable caller-chosen names."
  type        = map(string)
  default     = {}
}

variable "api_dns" {
  description = "Optional public DNS name for the Kubernetes API. Creates an A record to the Elastic IP in this Route53 zone and makes the name the cluster endpoint."
  type = object({
    zone_id = string
    name    = string
  })
  default = null
}

variable "core_dns_enabled" {
  description = "Whether Talos deploys its own CoreDNS. Disabled by default for Panfactum kube_core_dns."
  type        = bool
  default     = false
}

variable "cilium_enabled" {
  description = "Disable Talos-managed Flannel and kube-proxy on every node before installing Cilium with kube-proxy replacement."
  type        = bool
  default     = true
}

variable "etcd_backup_retention_days" {
  description = "Days to keep etcd snapshots in S3."
  type        = number
  default     = 7
}

variable "etcd_backup_schedule" {
  description = "Cron schedule for etcd backups in UTC."
  type        = string
  default     = "0 * * * *"
}

variable "etcd_pre_membership_snapshot_enabled" {
  description = "Run the etcd-backup CronJob and wait for it before creating controllers that join an existing cluster."
  type        = bool
  default     = true
}

variable "etcd_pre_membership_snapshot_kubeconfig" {
  description = "Path to a kubeconfig that reaches the API through the operator tunnel. Required only when an apply adds controllers to an existing cluster; kubectl must be on PATH."
  type        = string
  default     = null
}

variable "etcd_pre_membership_snapshot_timeout_seconds" {
  description = "Seconds to wait for the pre-membership snapshot job to complete."
  type        = number
  default     = 600
}

variable "machine_secrets" {
  description = "Talos secrets bundle in the siderolabs/talos provider machine_secrets shape. Generate it once with scripts/gen_talos_secrets.py and keep it SOPS-encrypted; it is the only source of the cluster PKI."
  type = object({
    certs = object({
      etcd               = object({ cert = string, key = string })
      k8s                = object({ cert = string, key = string })
      k8s_aggregator     = object({ cert = string, key = string })
      k8s_serviceaccount = object({ key = string })
      os                 = object({ cert = string, key = string })
    })
    cluster = object({ id = string, secret = string })
    secrets = object({
      bootstrap_token             = string
      secretbox_encryption_secret = string
      aescbc_encryption_secret    = optional(string)
    })
    trustdinfo = object({ token = string })
  })
  sensitive = true
  default   = null
}

variable "client_configuration" {
  description = "Talos admin client credentials (base64 CA, certificate, key) that Terraform uses for the Talos API. Signed by the os CA in machine_secrets; produced by scripts/gen_talos_secrets.py."
  type = object({
    ca_certificate     = string
    client_certificate = string
    client_key         = string
  })
  sensitive = true
  default   = null
}

variable "control_plane_config_patches" {
  description = "Additional Talos configuration patches for control plane nodes."
  type        = list(string)
  default     = []
}

variable "worker_config_patches" {
  description = "Additional Talos configuration patches for workers."
  type        = list(string)
  default     = []
}

variable "secrets_bundle" {
  description = "Decrypted talosctl secrets bundle, including clientconfig. Keep the source SOPS-encrypted."
  type        = any
  default     = null
  sensitive   = true
}

variable "ami_id" {
  description = "Optional custom Talos AMI ID."
  type        = string
  default     = null
}

variable "installer_image" {
  description = "Optional Talos factory installer image matching the AMI."
  type        = string
  default     = null
}

variable "pod_subnets" {
  description = "Kubernetes pod network ranges."
  type        = list(string)
  default     = ["10.244.0.0/16"]
}

variable "service_subnets" {
  description = "Kubernetes service network ranges."
  type        = list(string)
  default     = ["10.96.0.0/12"]
}

variable "aws_node_config_enabled" {
  description = "Preserve the AWS launch configuration of explicitly managed legacy worker groups. Karpenter workers and controllers use AWS configuration automatically."
  type        = bool
  default     = false
}

variable "controller_provider_id_kube_api_server" {
  description = "Optional HTTPS Kubernetes API URL for setting AWS controller provider IDs. VPN and public access derive the URL automatically. For SSM, keep a Kubernetes forward running and set its loopback URL to enable provider ID reconciliation."
  type        = string
  default     = null

  validation {
    condition     = var.controller_provider_id_kube_api_server == null ? true : startswith(var.controller_provider_id_kube_api_server, "https://")
    error_message = "controller_provider_id_kube_api_server must be an HTTPS URL."
  }
}

variable "worker_instance_profile_arn" {
  description = "Worker IAM instance profile ARN."
  type        = string
  default     = null
}

variable "worker_public_ip_enabled" {
  description = "Assign public IPv4 addresses to workers. Only useful in PUBLIC subnets; PRIVATE subnets route outbound through NAT."
  type        = bool
  default     = false
}

variable "worker_capacity_rebalance" {
  description = "Replace Spot workers on EC2 rebalance notices."
  type        = bool
  default     = false
}

variable "worker_suspended_processes" {
  description = "ASG processes to suspend for Spot workers."
  type        = list(string)
  default     = []
}

variable "worker_identity" {
  description = "Deprecated alias for the Talos controller identity settings. Worker IAM is managed by Karpenter."
  type = object({
    name_prefix                            = optional(string)
    ecr_cache_prefixes                     = optional(set(string), [])
    controller_instance_profile_enabled    = optional(bool, false)
    controller_additional_ecr_repositories = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.worker_identity.name_prefix == null || can(regex("^[A-Za-z0-9+=,.@_-]{1,24}$", var.worker_identity.name_prefix))
    error_message = "name_prefix must be 1-24 IAM-compatible characters so generated role and profile names fit AWS limits."
  }
  validation {
    condition     = alltrue([for prefix in var.worker_identity.ecr_cache_prefixes : contains(["github", "docker-hub", "quay", "kubernetes", "ecr-public"], prefix)])
    error_message = "Only the five established pull-through cache prefixes are allowed."
  }
  validation {
    condition = alltrue([for name in var.worker_identity.controller_additional_ecr_repositories :
      length(name) >= 2 && length(name) <= 256 && can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", name))
    ])
    error_message = "Use exact lowercase ECR repository names without wildcards or ARNs."
  }
}

variable "controller_identity" {
  description = "IAM naming and ECR access settings for the optional Talos controller identity."
  type = object({
    name_prefix                            = optional(string)
    ecr_cache_prefixes                     = optional(set(string), [])
    controller_instance_profile_enabled    = optional(bool, false)
    controller_additional_ecr_repositories = optional(set(string), [])
  })
  default = null

  validation {
    condition     = var.controller_identity == null ? true : (var.controller_identity.name_prefix == null || can(regex("^[A-Za-z0-9+=,.@_-]{1,24}$", var.controller_identity.name_prefix)))
    error_message = "name_prefix must be 1-24 IAM-compatible characters so generated role and profile names fit AWS limits."
  }
  validation {
    condition     = var.controller_identity == null ? true : alltrue([for prefix in var.controller_identity.ecr_cache_prefixes : contains(["github", "docker-hub", "quay", "kubernetes", "ecr-public"], prefix)])
    error_message = "Only the five established pull-through cache prefixes are allowed."
  }
  validation {
    condition = var.controller_identity == null ? true : alltrue([for name in var.controller_identity.controller_additional_ecr_repositories :
      length(name) >= 2 && length(name) <= 256 && can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", name))
    ])
    error_message = "Use exact lowercase ECR repository names without wildcards or ARNs."
  }
}
