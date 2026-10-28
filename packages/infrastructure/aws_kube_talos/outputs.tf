output "cluster_name" {
  description = "The name of the Talos cluster."
  value       = var.cluster_name
}

output "cluster_url" {
  description = "The URL of the Kubernetes API server (use as kube_api_server in region.yaml)."
  value       = local.cluster_endpoint
}

output "cluster_ca_data" {
  description = "Base64-encoded Kubernetes cluster CA certificate."
  # The CA certificate is public; only machine_secrets as a whole is sensitive
  value = nonsensitive(var.machine_secrets.certs.k8s.cert)
}

output "node_security_group_id" {
  description = "Security group shared by all Talos nodes."
  value       = aws_security_group.nodes.id
}

output "control_plane_public_ips" {
  description = "Public IP of the control plane node (Talos and Kubernetes API endpoint)."
  value       = [aws_eip_association.api.public_ip]
}

output "worker_public_ips" {
  description = "Public IPs of the worker nodes."
  value       = aws_instance.worker[*].public_ip
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
