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
  description = "Subnet names (Name tag), one per control plane node in order. Use PUBLIC subnets only with control_plane_public_ip_enabled. Repeating a subnet places several nodes in one AZ, which an AZ outage takes down together."
  type        = list(string)
  default     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
}

variable "worker_subnets" {
  description = "Subnet names (Name tag) for the worker nodes. PRIVATE subnets need a NAT route for outbound access; PUBLIC subnets also need worker_public_ip_enabled."
  type        = list(string)
  default     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
}

variable "control_plane_count" {
  description = "Number of control plane nodes, placed in control_plane_subnets order. 3 requires private_api_dns_name so nodes do not depend on one controller's address."
  type        = number
  default     = 1

  # etcd quorum: 3 members tolerate one loss; 2 tolerate none.
  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "control_plane_count must be 1 or 3."
  }

}

variable "control_plane_spot_enabled" {
  description = "Run control planes as persistent Spot instances that stop (keeping their disk, private IP and etcd membership) on interruption and can be stopped to suspend the cluster."
  type        = bool
  default     = false
}

variable "control_plane_public_ip_enabled" {
  description = "Give controllers a public IP and an Elastic IP API endpoint. Off by default: controllers sit in private subnets and operators reach them through an SSM tunnel, which needs private_api_dns_name or control_plane_private_ips."
  type        = bool
  default     = false
}

variable "private_api_dns_name" {
  description = "Optional private DNS name (e.g. api.example.internal) used as the cluster endpoint. Creates a private Route53 zone for the parent domain with an A record to every control plane private IP."
  type        = string
  default     = null
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes. T2 types are not supported by Talos."
  type        = string
  default     = "t4g.medium"
}

variable "control_plane_instance_types" {
  description = "Optional per-node instance types in control_plane_subnets order, overriding control_plane_instance_type. Lets each Spot node use a type with capacity in its AZ."
  type        = list(string)
  default     = []
}

variable "control_plane_workloads_enabled" {
  description = "Allow ordinary workloads on control planes for small clusters; they share resources with etcd and the API server."
  type        = bool
  default     = false
}

variable "worker_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 1
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
  description = "Kubernetes version (e.g., 1.37.0). Pinned so a talos provider upgrade does not change it; upgrade with `talosctl upgrade-k8s`."
  type        = string
  default     = "1.37.0"
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
  description = "Talos API endpoint for the provider and talosconfig. The default reaches the controller through an SSM tunnel forwarding 127.0.0.1:50000. Null uses the Elastic IP (requires control_plane_public_ip_enabled)."
  type        = string
  default     = "127.0.0.1"
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
  description = "Configure primary-interface DHCP, ECR credentials, external CCM and worker lifecycle labels for AWS."
  type        = bool
  default     = false
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
