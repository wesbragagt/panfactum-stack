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
        Sid       = "RequireKMS", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource  = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" } }
      },
      {
        Sid       = "RequireBackupKey", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource  = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.etcd_backup.arn } }
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
  backup_image     = "python:3.13.7-slim-bookworm"
  backup_init      = <<-PYTHON
    import hashlib, os, pathlib, platform, subprocess, urllib.request
    architecture = {"aarch64": "arm64", "x86_64": "amd64"}[platform.machine()]
    checksums = ${jsonencode(var.etcd_backup_talosctl_sha256)}
    url = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/talosctl-linux-" + architecture
    binary = urllib.request.urlopen(url, timeout=120).read()
    if hashlib.sha256(binary).hexdigest() != checksums[architecture]:
        raise RuntimeError("talosctl SHA256 mismatch")
    path = pathlib.Path("/runtime/bin/talosctl")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(binary)
    path.chmod(0o755)
    subprocess.run(["python3", "-m", "pip", "install", "--no-cache-dir", "--target", "/runtime/lib", "awscli==1.42.0"], check=True)
  PYTHON
  backup_manifests = [
    {
      apiVersion = "v1", kind = "Namespace"
      metadata   = { name = local.backup_namespace, labels = { "pod-security.kubernetes.io/enforce" = "restricted" } }
    },
    {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "etcd-backup", namespace = local.backup_namespace }
      data       = { "etcd-backup.py" = file("${path.module}/etcd-backup.py") }
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
        schedule                = "*/15 * * * *", timeZone = "Etc/UTC", concurrencyPolicy = "Forbid"
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
                initContainers = [{
                  name            = "install-tools", image = local.backup_image
                  command         = ["python3", "-c", local.backup_init]
                  env             = [{ name = "HOME", value = "/tmp" }]
                  volumeMounts    = [{ name = "runtime", mountPath = "/runtime" }, { name = "tmp", mountPath = "/tmp" }]
                  securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
                  resources       = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
                }]
                containers = [{
                  name    = "backup", image = local.backup_image
                  command = ["python3", "/scripts/etcd-backup.py"]
                  envFrom = [{ secretRef = { name = "etcd-backup-aws" } }]
                  env = [
                    { name = "TALOSCONFIG", value = "/var/run/secrets/talos.dev/config" },
                    { name = "TALOS_ENDPOINT", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } },
                    { name = "TALOS_NODE", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } },
                    { name = "BACKUP_BUCKET", value = aws_s3_bucket.etcd_backup.id },
                    { name = "BACKUP_PREFIX", value = local.backup_prefix },
                    { name = "BACKUP_KMS_KEY_ID", value = aws_kms_key.etcd_backup.arn },
                    { name = "AWS_REGION", value = data.aws_region.current.region },
                    { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
                    { name = "PYTHONPATH", value = "/runtime/lib" },
                    { name = "PATH", value = "/runtime/bin:/runtime/lib/bin:/usr/local/bin:/usr/bin:/bin" },
                    { name = "HOME", value = "/tmp" }
                  ]
                  volumeMounts = [
                    { name = "runtime", mountPath = "/runtime", readOnly = true },
                    { name = "script", mountPath = "/scripts", readOnly = true },
                    { name = "talos", mountPath = "/var/run/secrets/talos.dev", readOnly = true },
                    { name = "tmp", mountPath = "/tmp" }
                  ]
                  securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
                  resources       = { requests = { cpu = "100m", memory = "128Mi", "ephemeral-storage" = "1Gi" }, limits = { memory = "512Mi", "ephemeral-storage" = "4Gi" } }
                }]
                volumes = [
                  { name = "runtime", emptyDir = {} },
                  { name = "tmp", emptyDir = { sizeLimit = "3Gi" } },
                  { name = "script", configMap = { name = "etcd-backup" } },
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
