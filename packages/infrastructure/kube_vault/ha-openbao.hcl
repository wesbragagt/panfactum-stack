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
  x_forwarded_for_authorized_addrs = "10.0.0.0/16" #TODO: This should be an input
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
# ARM64 binaries before resolving the seal; never download plugins at server start.
plugin "kms" "awskms" {
  command = "openbao-plugin-kms-aws"
  version = "v0.1.1"
  sha256sum = "986487f17d30123b4730cf412ad2267f7ef4cfe637c75252ed6d13294673bae2"
  env = [
    "AWS_REGION=${aws_region}",
    "AWS_DEFAULT_REGION=${aws_region}",
    "AWS_ROLE_ARN=${aws_role_arn}",
    "AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token",
    "AWS_EC2_METADATA_DISABLED=true",
    "AWS_STS_REGIONAL_ENDPOINTS=regional"
  ]
}

plugin "secret" "aws" {
  command = "openbao-plugin-secrets-aws"
  version = "v0.3.3"
  sha256sum = "670aa9c3f1cff789826ab8c00845760034d8f82afd2cdd57ecf794863e8c7127"
  env = [
    "AWS_REGION=${aws_region}",
    "AWS_DEFAULT_REGION=${aws_region}",
    "AWS_ROLE_ARN=${aws_role_arn}",
    "AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token",
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

}

telemetry {
  disable_hostname = true
  enable_hostname_label = true
  prometheus_retention_time = "2m"
}


