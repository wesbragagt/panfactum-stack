output "cluster_name" {
  description = "The name of the Talos cluster."
  value       = var.cluster_name
}

output "cluster_url" {
  description = "The URL of the Kubernetes API server (use as kube_api_server in region.yaml)."
  value       = local.cluster_endpoint
}

output "cluster" {
  description = "Talos cluster connection metadata for Karpenter."
  value = {
    type              = "talos"
    name              = var.cluster_name
    endpoint          = local.cluster_endpoint
    oidc_provider_arn = aws_iam_openid_connect_provider.service_account_oidc[0].arn
    oidc_issuer_url   = local.service_account_oidc_issuer_url
  }
}

output "kubernetes_version" {
  description = "Configured Kubernetes version for the Talos cluster."
  value       = var.kube_version
}

output "dns_service_ip" {
  description = "CoreDNS service address in the primary service CIDR."
  # NOTE: Talos computes the kube-dns service address by advancing ten addresses from the CIDR base.
  value = try(cidrhost(var.service_subnets[0], 10), null)
}

output "cluster_ca_data" {
  description = "Base64-encoded Kubernetes cluster CA certificate."
  # The CA certificate is public; only machine_secrets as a whole is sensitive
  value = nonsensitive(local.machine_secrets.certs.k8s.cert)
}

output "iam_login" {
  description = "Public operator metadata for scripts/iam_login.py: `tofu output -json iam_login > operator.json`. A role with no matching IAM role is null, which the script rejects."
  value = {
    issuer         = data.aws_iam_outbound_web_identity_federation.iam_login.issuer_identifier
    audience       = var.cluster_name
    region         = data.aws_region.current.region
    role_arns      = { for role, set in local.iam_login_roles : role => try(sort(tolist(set.arns))[0], null) }
    principal_arns = sort(concat([local.iam_login_root_arn], [for pair in local.iam_login_extra_principals : pair.arn]))
  }
}

output "cluster_region" {
  description = "The AWS region to which the Talos cluster is deployed"
  value       = data.aws_region.current.region
}

output "node_security_group_id" {
  description = "Security group shared by all Talos nodes."
  value       = aws_security_group.nodes.id
}

output "control_plane_public_ips" {
  description = "Public IP of the control plane node (Talos and Kubernetes API endpoint)."
  value       = aws_eip_association.api[*].public_ip
}

output "control_plane_private_ips" {
  description = "Private IPs of the control plane nodes, in control_plane order."
  value       = aws_instance.control_plane[*].private_ip
}

output "controller_provider_ids" {
  description = "AWS provider ID of each controller, keyed by private IP."
  value = {
    for instance in aws_instance.control_plane :
    instance.private_ip => format("aws:///%s/%s", instance.availability_zone, instance.id)
  }
}

output "api_load_balancer_dns_name" {
  description = "DNS name of the internal Kubernetes API load balancer, or null when no load balancer is created."
  value       = one(aws_lb.api[*].dns_name)
}

output "talosconfig" {
  description = "talosctl client configuration."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Admin kubeconfig. The context is named admin@<cluster_name>."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "etcd_backup_bucket" {
  description = "S3 bucket holding SSE-KMS encrypted etcd snapshots."
  value       = aws_s3_bucket.etcd_backup.id
}

output "etcd_backup_kms_key_arn" {
  description = "KMS key that encrypts etcd snapshots. Restores need kms:Decrypt on it."
  value       = aws_kms_key.etcd_backup.arn
}

output "etcd_backup_cronjob_manifest" {
  description = "CronJob YAML for Kubernetes-stage reconciliation after bootstrap. Contains Secret references, not credential values."
  value       = yamlencode(one([for manifest in local.backup_manifests : manifest if manifest.kind == "CronJob"]))
}

output "node_bootstrap" {
  description = "Cluster metadata for generating a Talos worker configuration outside this module."
  value = {
    cluster_name       = var.cluster_name
    cluster_endpoint   = local.worker_cluster_endpoint
    talos_version      = var.talos_version
    kubernetes_version = var.kube_version
    installer_image    = local.upgrade_installer_image
    pod_subnets        = var.pod_subnets
    service_subnets    = var.service_subnets
  }
}

output "talos_ami_id" {
  description = "Talos AMI used by workers."
  value       = data.aws_ami.talos.id
}

output "bootstrap_public_host" {
  description = "Temporary public hostname for the Talos and Kubernetes operator APIs. Null when the public load balancer is disabled."
  value       = local.bootstrap_public_host
}

output "stable_api_hostname" {
  description = "Shared Talos and Kubernetes API DNS name across public bootstrap and private access, when configured."
  value       = local.stable_api_hostname
}

output "bootstrap_public_talos_endpoint" {
  description = "Temporary public Talos API address for talosctl, including the port."
  value       = local.bootstrap_public_host == null ? null : "${local.bootstrap_public_host}:50000"
}

output "bootstrap_public_kube_url" {
  description = "Temporary public Kubernetes API URL for kubectl and Helm."
  value       = local.bootstrap_public_host == null ? null : "https://${local.bootstrap_public_host}:6443"
}

output "bootstrap_public_node" {
  description = "Private IP of the controller targeted by the temporary public load balancer."
  value       = local.bootstrap_public_enabled ? local.bootstrap_node : null
}
