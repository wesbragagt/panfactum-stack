%{ if disable_mlock != null ~}
disable_mlock = ${disable_mlock}
%{ endif ~}
ui = true

listener "tcp" {

  # We use the service mesh for TLS so we do not need to do it natively
  tls_disable = 1

  # These are the vault defaults
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"

  # Vault tokens can be bound to particular IP addresses. However, the source
  # IP won't be available if communicating to vault through our ingress system
  # (the source IP will look like the ingress pod id).
  # Our ingress system allows adding a x-forwarded-for header that vault
  # can then read to derive the actual source IP.
  # If the header isn't present, that means it came from inside the cluster.
  x_forwarded_for_authorized_addrs = "${x_forwarded_for_authorized_addrs}" #TODO: This should be an input
  x_forwarded_for_reject_not_authorized = "true"
  x_forwarded_for_reject_not_present = "false"

  telemetry {
    # Necessary for Prometheus Operator
    unauthenticated_metrics_access = "true"
  }
}


# enables service-based routing to the active vault instance
service_registration "kubernetes" {}

# Use the headless Kubernetes service addresses to connect with the other instances
storage "raft" {
  path = "/vault/data"
%{ for index in range(vault_replicas) ~}
  retry_join {
    leader_api_addr = "http://vault-${index}.vault-internal:8200"
  }
%{ endfor ~}
}

plugin_directory = "/vault/plugins"
plugin_auto_download = false
plugin_auto_register = true

# OpenBao's AWS integrations are external plugins. Register the exact preinstalled
# ${upper(plugin_arch)} binaries before resolving the seal; never download plugins at server start.
plugin "kms" "awskms" {
  command = "openbao-plugin-kms-aws"
  version = "v0.1.1"
  sha256sum = "${kms_sha256}"
  env = [
    "AWS_REGION=${aws_region}",
    "AWS_DEFAULT_REGION=${aws_region}",
%{ if aws_endpoint == null ~}
    "AWS_ROLE_ARN=${aws_role_arn}",
    "AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token",
%{ else ~}
    "AWS_ENDPOINT_URL=${aws_endpoint}",
%{ endif ~}
    "AWS_EC2_METADATA_DISABLED=true",
    "AWS_STS_REGIONAL_ENDPOINTS=regional"
  ]
}

plugin "secret" "aws" {
  command = "openbao-plugin-secrets-aws"
  version = "v0.3.3"
  sha256sum = "${aws_sha256}"
  env = [
    "AWS_REGION=${aws_region}",
    "AWS_DEFAULT_REGION=${aws_region}",
%{ if aws_endpoint == null ~}
    "AWS_ROLE_ARN=${aws_role_arn}",
    "AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token",
%{ else ~}
    "AWS_ENDPOINT_URL=${aws_endpoint}",
%{ endif ~}
    "AWS_EC2_METADATA_DISABLED=true",
    "AWS_STS_REGIONAL_ENDPOINTS=regional"
  ]
}

# This instructs Vault to use the automatic unsealing (https://developer.hashicorp.com/vault/docs/concepts/seal#auto-unseal)
# Without this, we would need to manually enter the unseal keys every time the Vault pod restarts.
# We use AWS KMS for the unseal mechanism to prevent ever leaking the unseal encryption material
# Vault will use IRSA to authenticate with the AWS API
seal "awskms" {
  region = "${aws_region}"
  kms_key_id = "${kms_key_id}"
%{ if aws_endpoint != null ~}
  endpoint = "${aws_endpoint}"
%{ endif ~}

}

telemetry {
  disable_hostname = true
  enable_hostname_label = true
  prometheus_retention_time = "2m"
}


