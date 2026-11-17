data "aws_caller_identity" "backup" {}

data "aws_partition" "backup" {}

resource "aws_s3_bucket" "etcd_backup" {
  bucket_prefix = "${var.cluster_name}-etcd-"
  force_destroy = false
  tags          = data.pf_aws_tags.tags.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "etcd_backup" {
  bucket                  = aws_s3_bucket.etcd_backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "etcd_backup" {
  description             = "Talos etcd backups for ${var.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = data.pf_aws_tags.tags.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "etcd_backup" {
  name          = "alias/${var.cluster_name}-etcd-backup"
  target_key_id = aws_kms_key.etcd_backup.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.etcd_backup.arn
    }
    # Object ARN encryption contexts restrict the uploader to the backup prefix.
    bucket_key_enabled = false
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "etcd_backup" {
  depends_on = [aws_s3_bucket_versioning.etcd_backup]
  bucket     = aws_s3_bucket.etcd_backup.id
  rule {
    id     = "backup-retention"
    status = "Enabled"
    filter {
      prefix = "${local.backup_prefix}/"
    }
    expiration {
      days = var.etcd_backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.etcd_backup_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
  rule {
    id     = "expired-delete-markers"
    status = "Enabled"
    filter {
      prefix = "${local.backup_prefix}/"
    }
    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_policy" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*"
        Resource  = [aws_s3_bucket.etcd_backup.arn, "${aws_s3_bucket.etcd_backup.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid      = "RejectNonKMS", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = {
          Null            = { "s3:x-amz-server-side-encryption" = "false" }
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
        }
      },
      {
        Sid      = "RejectOtherKeys", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = {
          Null            = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "false" }
          StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.etcd_backup.arn }
        }
      },
      {
        # Explicit SSE-KMS without a key selects the AWS-managed key instead.
        Sid      = "RejectUnspecifiedKMSKey", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = {
          StringEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
          Null         = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "true" }
        }
      }
    ]
  })
}

resource "aws_iam_user" "etcd_backup" {
  name = "${var.cluster_name}-etcd-backup"
  tags = data.pf_aws_tags.tags.tags
}

resource "aws_iam_user_policy" "etcd_backup" {
  name = "upload-etcd-backups"
  user = aws_iam_user.etcd_backup.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow", Action = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.etcd_backup.arn}/${local.backup_prefix}/*"
      },
      {
        # Decrypt is needed by S3 for multipart uploads; no direct KMS decrypt.
        Effect   = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.etcd_backup.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${data.aws_region.current.region}.${data.aws_partition.backup.dns_suffix}" }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "${aws_s3_bucket.etcd_backup.arn}/${local.backup_prefix}/*" }
        }
      }
    ]
  })
}

resource "aws_iam_access_key" "etcd_backup" {
  user = aws_iam_user.etcd_backup.name
}

locals {
  backup_namespace = "etcd-backup"
  backup_prefix    = "etcd/${var.cluster_name}"
  backup_image     = "ghcr.io/siderolabs/talos-backup:v0.1.0@sha256:3635df0be0862d71bba7a34dca3e7f7c790887f5c5d0129002191c4c2d92dd15"
  backup_manifests = [
    {
      apiVersion = "v1", kind = "Namespace"
      metadata   = { name = local.backup_namespace, labels = { "pod-security.kubernetes.io/enforce" = "restricted" } }
    },
    {
      apiVersion = "v1", kind = "Secret", type = "Opaque"
      metadata   = { name = "etcd-backup-aws", namespace = local.backup_namespace }
      stringData = {
        AWS_ACCESS_KEY_ID     = aws_iam_access_key.etcd_backup.id
        AWS_SECRET_ACCESS_KEY = aws_iam_access_key.etcd_backup.secret
      }
    },
    {
      apiVersion = "talos.dev/v1alpha1", kind = "ServiceAccount"
      metadata   = { name = "etcd-backup-talos", namespace = local.backup_namespace }
      spec       = { roles = ["os:etcd:backup"] }
    },
    {
      apiVersion = "batch/v1", kind = "CronJob"
      metadata   = { name = "etcd-backup", namespace = local.backup_namespace }
      spec = {
        schedule                = var.etcd_backup_schedule, timeZone = "Etc/UTC", concurrencyPolicy = "Forbid"
        startingDeadlineSeconds = 600, successfulJobsHistoryLimit = 1, failedJobsHistoryLimit = 3
        jobTemplate = {
          spec = {
            backoffLimit = 2, activeDeadlineSeconds = 840, ttlSecondsAfterFinished = 86400
            template = {
              metadata = { labels = { app = "etcd-backup" } }
              spec = {
                restartPolicy   = "Never", automountServiceAccountToken = false
                nodeSelector    = { "node-role.kubernetes.io/control-plane" = "" }
                tolerations     = [{ key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" }]
                securityContext = { runAsNonRoot = true, runAsUser = 1000, runAsGroup = 1000, fsGroup = 1000, seccompProfile = { type = "RuntimeDefault" } }
                containers = [{
                  name       = "backup", image = local.backup_image
                  command    = ["/talos-backup"]
                  workingDir = "/tmp"
                  envFrom    = [{ secretRef = { name = "etcd-backup-aws" } }]
                  env = [
                    { name = "TALOSCONFIG", value = "/var/run/secrets/talos.dev/config" },
                    { name = "BUCKET", value = aws_s3_bucket.etcd_backup.id },
                    { name = "CLUSTER_NAME", value = var.cluster_name },
                    { name = "S3_PREFIX", value = local.backup_prefix },
                    # S3 provides SSE-KMS; keep snapshots directly recoverable by Talos.
                    { name = "DISABLE_ENCRYPTION", value = "true" },
                    { name = "ENABLE_COMPRESSION", value = "false" },
                    { name = "AWS_REGION", value = data.aws_region.current.region },
                    { name = "AWS_EC2_METADATA_DISABLED", value = "true" }
                  ]
                  volumeMounts = [
                    { name = "talos", mountPath = "/var/run/secrets/talos.dev", readOnly = true },
                    { name = "tmp", mountPath = "/tmp" }
                  ]
                  securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
                  resources       = { requests = { cpu = "100m", memory = "128Mi", "ephemeral-storage" = "1Gi" }, limits = { memory = "512Mi", "ephemeral-storage" = "4Gi" } }
                }]
                volumes = [
                  { name = "tmp", emptyDir = { sizeLimit = "3Gi" } },
                  { name = "talos", secret = { secretName = "etcd-backup-talos" } }
                ]
              }
            }
          }
        }
      }
    }
  ]
  backup_config_patches = [
    yamlencode({
      cluster = {
        inlineManifests = [for index, manifest in local.backup_manifests : {
          name     = "etcd-backup-${index}"
          contents = yamlencode(manifest)
        }]
      }
    }),
    yamlencode({
      apiVersion                  = "v1alpha1", kind = "KubeTalosAPIAccessConfig"
      allowedRoles                = ["os:etcd:backup"]
      allowedKubernetesNamespaces = [local.backup_namespace]
    })
  ]
}
