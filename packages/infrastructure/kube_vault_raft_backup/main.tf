terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "4.8.0"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  prefix     = trim(var.s3_prefix, "/")
  bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.s3_bucket}"
  labels = merge(var.labels, {
    "app.kubernetes.io/name"                   = var.name
    "app.kubernetes.io/part-of"                = "panfactum"
    "panfactum.com/module"                     = "kube_vault_raft_backup"
    "panfactum.com/pull-through-cache-enabled" = "false"
  })
  script = file("${path.module}/backup.sh")
  cron_job = {
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata   = { name = var.name, namespace = var.namespace, labels = local.labels }
    spec = {
      schedule                   = var.schedule
      timeZone                   = var.time_zone
      suspend                    = var.suspended
      concurrencyPolicy          = "Forbid"
      startingDeadlineSeconds    = 300
      successfulJobsHistoryLimit = 3
      failedJobsHistoryLimit     = 3
      jobTemplate = {
        spec = {
          backoffLimit            = 1
          activeDeadlineSeconds   = 300
          ttlSecondsAfterFinished = 86400
          template = {
            metadata = {
              labels = local.labels
              annotations = {
                "linkerd.io/inject" = "disabled"
                "checksum/script"   = sha256(local.script)
              }
            }
            spec = {
              serviceAccountName           = kubernetes_service_account_v1.backup.metadata[0].name
              automountServiceAccountToken = false
              restartPolicy                = "Never"
              nodeSelector                 = var.node_selector
              tolerations                  = [for item in var.tolerations : { for key, value in item : key => value if value != null }]
              securityContext = {
                runAsNonRoot   = true
                runAsUser      = 1000
                runAsGroup     = 1000
                fsGroup        = 1000
                seccompProfile = { type = "RuntimeDefault" }
              }
              containers = [{
                name            = "backup"
                image           = var.image
                imagePullPolicy = "IfNotPresent"
                command         = ["bash", "/scripts/backup.sh"]
                resources = {
                  requests = { cpu = "25m", memory = "256Mi" }
                  limits   = { cpu = "250m", memory = "512Mi" }
                }
                securityContext = {
                  allowPrivilegeEscalation = false
                  readOnlyRootFilesystem   = true
                  capabilities             = { drop = ["ALL"] }
                }
                env = concat([for key, value in {
                  VAULT_ADDR                  = var.vault_address
                  VAULT_ROLE                  = vault_kubernetes_auth_backend_role.backup.role_name
                  VAULT_AUTH_MOUNT            = var.vault_auth_mount
                  VAULT_JWT_FILE              = "/var/run/backup-identity/vault/token"
                  AWS_ROLE_ARN                = module.aws_auth.role_arn
                  AWS_WEB_IDENTITY_TOKEN_FILE = "/var/run/backup-identity/aws/token"
                  AWS_REGION                  = data.aws_region.current.name
                  AWS_DEFAULT_REGION          = data.aws_region.current.name
                  AWS_EC2_METADATA_DISABLED   = "true"
                  AWS_STS_REGIONAL_ENDPOINTS  = "regional"
                  AWS_CONFIG_FILE             = "/work/aws-config"
                  AWS_SHARED_CREDENTIALS_FILE = "/work/aws-credentials"
                  BACKUP_BUCKET               = var.s3_bucket
                  BACKUP_PREFIX               = local.prefix
                  BACKUP_KMS_KEY_ARN          = var.s3_kms_key_arn
                  MAX_SNAPSHOT_BYTES          = tostring(var.max_snapshot_mb * 1024 * 1024)
                  WORK_DIR                    = "/work"
                  TMPDIR                      = "/work"
                  } : { name                  = key, value = value }], [{
                  name                        = "POD_UID"
                  valueFrom                   = { fieldRef = { fieldPath = "metadata.uid" } }
                }])
                volumeMounts = [
                  { name = "script", mountPath = "/scripts", readOnly = true },
                  { name = "identity", mountPath = "/var/run/backup-identity", readOnly = true },
                  { name = "work", mountPath = "/work" },
                  { name = "work", mountPath = var.aws_cli_cache_directory }
                ]
              }]
              volumes = [
                { name = "script", configMap = { name = kubernetes_config_map_v1.script.metadata[0].name, defaultMode = 365 } },
                { name = "work", emptyDir = { sizeLimit = "${var.max_snapshot_mb * 2 + 32}Mi" } },
                { name = "identity", projected = {
                  defaultMode = 288
                  sources = [
                    { serviceAccountToken = { audience = "vault", expirationSeconds = 600, path = "vault/token" } },
                    { serviceAccountToken = { audience = "sts.amazonaws.com", expirationSeconds = 3600, path = "aws/token" } }
                  ]
                } }
              ]
            }
          }
        }
      }
    }
  }
}

data "aws_iam_policy_document" "backup" {
  statement {
    sid       = "SnapshotObjectsOnly"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${local.bucket_arn}/${local.prefix}/*"]
  }
  statement {
    sid       = "SnapshotEncryptionOnly"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.s3_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.name}.${data.aws_partition.current.dns_suffix}"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [local.bucket_arn, "${local.bucket_arn}/${local.prefix}/*"]
    }
  }
}

module "aws_auth" {
  source                    = "../kube_sa_auth_aws"
  service_account           = var.name
  service_account_namespace = var.namespace
  iam_policy_json           = data.aws_iam_policy_document.backup.json
  # Explicit projected web identity avoids reliance on a pod-identity webhook.
  annotate_service_account = false
  oidc_provider_arn        = var.oidc_provider_arn
  oidc_issuer_url          = var.oidc_issuer_url
  ip_restrictions_enabled  = var.ip_restrictions_enabled
  cluster_subnet_ids       = var.cluster_subnet_ids
}

resource "kubernetes_service_account_v1" "backup" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  automount_service_account_token = false
}

resource "vault_policy" "backup" {
  name   = "${var.namespace}-${var.name}"
  policy = <<-EOF
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "sys/capabilities-self" { capabilities = ["update"] }
EOF
}

resource "vault_kubernetes_auth_backend_role" "backup" {
  backend                          = var.vault_auth_mount
  role_name                        = "${var.namespace}-${var.name}"
  bound_service_account_names      = [var.name]
  bound_service_account_namespaces = [var.namespace]
  audience                         = "vault"
  token_policies                   = [vault_policy.backup.name]
  token_no_default_policy          = true
  token_ttl                        = 600
  token_max_ttl                    = 600
  token_explicit_max_ttl           = 600
}

resource "kubernetes_config_map_v1" "script" {
  metadata {
    name      = "${var.name}-script"
    namespace = var.namespace
    labels    = local.labels
  }
  data = { "backup.sh" = local.script }
}

resource "kubectl_manifest" "backup" {
  yaml_body         = yamlencode(local.cron_job)
  server_side_apply = true
  wait_for_rollout  = false
  depends_on        = [module.aws_auth]
}
