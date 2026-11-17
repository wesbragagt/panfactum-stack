locals {
  machine_secrets = var.secrets_bundle == null ? var.machine_secrets : {
    certs = {
      etcd               = { cert = var.secrets_bundle.certs.etcd.crt, key = var.secrets_bundle.certs.etcd.key }
      k8s                = { cert = var.secrets_bundle.certs.k8s.crt, key = var.secrets_bundle.certs.k8s.key }
      k8s_aggregator     = { cert = var.secrets_bundle.certs.k8saggregator.crt, key = var.secrets_bundle.certs.k8saggregator.key }
      k8s_serviceaccount = { key = var.secrets_bundle.certs.k8sserviceaccount.key }
      os                 = { cert = var.secrets_bundle.certs.os.crt, key = var.secrets_bundle.certs.os.key }
    }
    cluster = var.secrets_bundle.cluster
    secrets = {
      bootstrap_token             = var.secrets_bundle.secrets.bootstraptoken
      secretbox_encryption_secret = var.secrets_bundle.secrets.secretboxencryptionsecret
    }
    trustdinfo = var.secrets_bundle.trustdinfo
  }
  client_configuration = var.secrets_bundle == null ? var.client_configuration : {
    ca_certificate     = var.secrets_bundle.clientconfig.ca
    client_certificate = var.secrets_bundle.clientconfig.crt
    client_key         = var.secrets_bundle.clientconfig.key
  }
}
