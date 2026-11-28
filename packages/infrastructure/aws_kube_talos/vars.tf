variable "cluster_name" {
  description = "The name of the Talos cluster. Used for the Talos/Kubernetes cluster name and AWS resource names."
  type        = string
}

variable "vpc_id" {
  description = "The id for the VPC that the cluster should be deployed into"
  type        = string
}

variable "control_plane" {
  description = "Control plane nodes, one entry each: subnet (Name tag, required), optional fixed private_ip (null lets AWS assign one) and optional instance_type. The first entry bootstraps talos_cluster and is the endpoint fallback. Node state is keyed by list position, so only append entries; reordering or removing one replaces nodes. A fixed private_ip lets the VPN transport target the controller before it exists. An instance_type change resizes that controller in place (stop, modify, start); T2 types are not supported by Talos. More than one entry requires private_api_dns_name."
  type = list(object({
    subnet        = string
    private_ip    = optional(string)
    instance_type = optional(string, "t4g.medium")
  }))
  default = [{ subnet = "PRIVATE_A" }]

  # etcd quorum: 3 members tolerate one loss and 5 tolerate two; even counts add no tolerance.
  validation {
    condition     = contains([1, 3, 5], length(var.control_plane))
    error_message = "control_plane must have 1, 3 or 5 entries."
  }

  validation {
    condition     = length(distinct(var.control_plane[*].subnet)) == length(var.control_plane)
    error_message = "control_plane must not repeat a subnet name."
  }
}

variable "controller_instance_profile" {
  description = "IAM instance profile name for controllers. Changing it on a running controller re-associates the profile in place."
  type        = string
  default     = null
}

variable "control_plane_public_ip_enabled" {
  description = "Give controllers a public IP and an Elastic IP API endpoint. Off by default: controllers sit in private subnets and operators reach them through the VPN or bootstrap_public transport, which needs private_api_dns_name or a control_plane private_ip."
  type        = bool
  default     = false
}

variable "private_api_dns_name" {
  description = "Optional private DNS name (e.g. api.example.internal) used as the cluster endpoint. Creates a private Route 53 A record with every controller private IP. Clients handle failover between those addresses. Node-local components can use KubePrism."
  type        = string
  default     = null
}

variable "api_load_balancer_enabled" {
  description = "Put an internal network load balancer in front of the controllers and point the private_api_dns_name record at it. Its HTTPS /readyz health check stops traffic to a controller that accepts TCP but is not ready. Has no effect without private_api_dns_name."
  type        = bool
  default     = true
}

variable "control_plane_workloads_enabled" {
  description = "Whether controllers join the Panfactum controller class: they get the panfactum.com/class=controller label, lose the default control-plane taint and get the controller=true:NoSchedule taint. When false, controllers keep the default Talos control-plane taint and no class label."
  type        = bool
  default     = true
}

variable "control_plane_register_with_fqdn" {
  description = "Whether controllers register Nodes under the EC2 private DNS name so the external cloud provider can resolve them and set spec.providerID. New clusters register under it by default. Clusters created with the old default must set this to false explicitly, because changing it renames controller Nodes."
  type        = bool
  default     = true
}

variable "bootstrap_mode_enabled" {
  description = "Controllers skip the controller=true:NoSchedule and control-plane taints so workloads run on them until Karpenter launches workers; set to false after that."
  type        = bool
  default     = false
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
  description = "Kubernetes version (e.g., 1.36.5). The Talos cluster resource manages upgrades. Raise it one minor version at a time."
  type        = string
  default     = "1.36.5"
}

variable "version_upgrades_enabled" {
  description = "Run `talosctl upgrade` on each controller when talos_version changes. Needs talosctl on PATH and the Talos API reachable at talos_api_endpoint during apply."
  type        = bool
  default     = true
}

variable "talos_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Talos API (TCP 50000). Empty by default; operators reach the API through talos_api_source_security_groups or the bootstrap_public load balancer instead."
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
  description = "Talos operator transport. bootstrap_public selects the temporary public load balancer. vpn selects the configured bootstrap controller's fixed private IP. The empty default keeps the legacy 127.0.0.1 endpoint."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = contains(["", "vpn", "bootstrap_public"], var.talos_access_transport)
    error_message = "talos_access_transport must be vpn, bootstrap_public, or empty."
  }
}

variable "bootstrap_public" {
  description = "Overrides for the temporary public NLB. Public transport enables it and detects the runner's public IPv4 address by default. Set operator_cidr to override discovery. Set dns_zone_id to a public Route 53 zone for private_api_dns_name and keep it when setting enabled to false after verifying private access."
  type = object({
    enabled       = optional(bool, true)
    operator_cidr = optional(string)
    dns_zone_id   = optional(string)
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

variable "lifecycle_lock" {
  description = "Disable force_destroy on the etcd backup and service account OIDC buckets. Set to false for disposable clusters to allow deletion of both S3 buckets and their contents."
  type        = bool
  default     = true
  nullable    = false
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
  description = "Path to a kubeconfig that reaches the private Kubernetes API and has a context named cluster_name. The caller sets it only for an apply that adds controllers to an existing cluster; kubectl must be on PATH."
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

variable "panfactum_scheduler_enabled" {
  description = "Enable the Panfactum Kubernetes scheduler profile alongside the default scheduler."
  type        = bool
  default     = false
}

variable "control_plane_config_patches" {
  description = "Additional Talos configuration patches for control plane nodes."
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
  description = "Optional explicit Talos installer image. Mutually exclusive with image_factory_schematic_id. When both are null, the module builds an Image Factory schematic with the ecr-credential-provider and util-linux-tools extensions."
  type        = string
  default     = null
}

variable "image_factory_schematic_id" {
  description = "Optional Talos Image Factory schematic ID that replaces the module-built default (ecr-credential-provider and util-linux-tools). Derives the AWS installer from talos_version and reconciles the schematic on existing controllers."
  type        = string
  default     = null

  validation {
    condition     = var.image_factory_schematic_id == null || can(regex("^[a-f0-9]{64}$", var.image_factory_schematic_id))
    error_message = "image_factory_schematic_id must be a 64-character lowercase hexadecimal ID."
  }

  validation {
    condition     = var.image_factory_schematic_id == null || var.installer_image == null
    error_message = "Set either image_factory_schematic_id or installer_image."
  }
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

variable "controller_identity" {
  description = "IAM naming and ECR access settings for the Talos controller identity. The controller instance profile is on by default because the kubelet ECR credential provider needs instance credentials."
  type = object({
    name_prefix                            = optional(string)
    ecr_cache_prefixes                     = optional(set(string), [])
    controller_instance_profile_enabled    = optional(bool, true)
    controller_additional_ecr_repositories = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.controller_identity.name_prefix == null || can(regex("^[A-Za-z0-9+=,.@_-]{1,24}$", var.controller_identity.name_prefix))
    error_message = "name_prefix must be 1-24 IAM-compatible characters so generated role and profile names fit AWS limits."
  }
  validation {
    condition     = alltrue([for prefix in var.controller_identity.ecr_cache_prefixes : contains(["github", "docker-hub", "quay", "kubernetes", "ecr-public"], prefix)])
    error_message = "Only the five established pull-through cache prefixes are allowed."
  }
  validation {
    condition = alltrue([for name in var.controller_identity.controller_additional_ecr_repositories :
      length(name) >= 2 && length(name) <= 256 && can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", name))
    ])
    error_message = "Use exact lowercase ECR repository names without wildcards or ARNs."
  }
}

variable "extra_principal_arns" {
  description = "IAM principal ARNs, such as IAM users with static keys, mapped to Panfactum groups for Talos IAM login. Each key matches the aws_eks extra_*_principal_arns input of the same group. Identity Center roles and the account root user are added automatically."
  type = object({
    superusers         = optional(list(string), [])
    admins             = optional(list(string), [])
    readers            = optional(list(string), [])
    restricted_readers = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = length(distinct(flatten(values(var.extra_principal_arns)))) == length(flatten(values(var.extra_principal_arns)))
    error_message = "An IAM principal ARN may appear in only one extra_principal_arns group."
  }
}
