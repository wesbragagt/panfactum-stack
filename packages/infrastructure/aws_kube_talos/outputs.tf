output "cluster_name" {
  description = "The name of the Talos cluster."
  value       = var.cluster_name
}

output "cluster_url" {
  description = "The URL of the Kubernetes API server (use as kube_api_server in region.yaml)."
  value       = local.cluster_endpoint
}

output "kubernetes_version" {
  description = "Configured Kubernetes version for the Talos cluster."
  value       = var.kube_version
}

output "dns_service_ip" {
  description = "CoreDNS service address in the primary service CIDR when AWS node configuration owns the network."
  # NOTE: Talos computes the kube-dns service address by advancing ten addresses from the CIDR base.
  value = var.aws_node_config_enabled ? try(cidrhost(var.service_subnets[0], 10), null) : null
}

output "cluster_ca_data" {
  description = "Base64-encoded Kubernetes cluster CA certificate."
  # The CA certificate is public; only machine_secrets as a whole is sensitive
  value = nonsensitive(local.machine_secrets.certs.k8s.cert)
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
  description = "Private IPs of the control plane nodes, in control_plane_subnets order."
  value       = aws_instance.control_plane[*].private_ip
}

output "worker_autoscaling_group_name" {
  description = "Auto Scaling group maintaining the desired Spot worker count, or null when worker_count is 0."
  value       = one(aws_autoscaling_group.worker[*].name)
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

output "worker_machine_configuration" {
  description = "Worker Talos machine config (with caller patches) for Karpenter EC2NodeClass userData. Contains join credentials."
  value       = data.talos_machine_configuration.worker.machine_configuration
  sensitive   = true
}

output "talos_ami_id" {
  description = "Talos AMI used by workers."
  value       = data.aws_ami.talos.id
}

output "ssm_jump_host_instance_id" {
  description = "Instance ID of the SSM jump host, or null when ssm_jump_host_enabled is false."
  value       = one(aws_instance.ssm_jump_host[*].id)
}

output "ssm_jump_host_security_group_id" {
  description = "Security group of the SSM jump host, or null when ssm_jump_host_enabled is false."
  value       = one(aws_security_group.ssm_jump_host[*].id)
}

output "node_role_arn" {
  description = "EC2 worker IAM role ARN for Karpenter's scoped PassRole policy"
  value       = aws_iam_role.worker.arn
}

output "node_instance_profile" {
  description = "Existing instance profile name to pass to the Custom EC2NodeClass"
  value       = aws_iam_instance_profile.worker.name
}

output "node_instance_profile_arn" {
  description = "EC2 worker instance profile ARN"
  value       = aws_iam_instance_profile.worker.arn
}

output "bootstrap_public_host" {
  description = "Temporary public hostname for the Talos and Kubernetes operator APIs. Null when the public load balancer is disabled."
  value       = local.bootstrap_public_host
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
