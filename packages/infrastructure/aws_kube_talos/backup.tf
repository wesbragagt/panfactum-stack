data "aws_caller_identity" "backup" {}

data "aws_partition" "backup" {}

resource "aws_s3_bucket" "etcd_backup" {
  bucket_prefix = "${var.cluster_name}-etcd-"
  force_destroy = !var.lifecycle_lock
  tags          = data.pf_aws_tags.tags.tags
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
      # talos-backup sends no SSE headers; deny only wrong headers so the bucket-default key applies
      {
        Sid       = "RequireKMS", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource  = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }, Null = { "s3:x-amz-server-side-encryption" = "false" } }
      },
      {
        Sid       = "RequireBackupKey", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource  = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.etcd_backup.arn }, Null = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "false" } }
      },
      {
        # aws:kms without a key ID would fall back to the AWS-managed aws/s3 key
        Sid       = "DenyDefaultManagedKey", Effect = "Deny", Principal = "*", Action = "s3:PutObject"
        Resource  = "${aws_s3_bucket.etcd_backup.arn}/*"
        Condition = { StringEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }, Null = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "true" } }
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
  # Sidero maintains this image, so the module owns no backup code
  backup_image = "ghcr.io/siderolabs/talos-backup:v0.1.0@sha256:3635df0be0862d71bba7a34dca3e7f7c790887f5c5d0129002191c4c2d92dd15"
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
                restartPolicy = "Never", automountServiceAccountToken = false
                affinity = {
                  nodeAffinity = {
                    preferredDuringSchedulingIgnoredDuringExecution = [{
                      weight = 100
                      preference = {
                        matchExpressions = [{ key = "node-role.kubernetes.io/control-plane", operator = "DoesNotExist" }]
                      }
                    }]
                  }
                }
                tolerations     = [{ key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" }]
                securityContext = { runAsNonRoot = true, runAsUser = 1000, runAsGroup = 1000, fsGroup = 1000, seccompProfile = { type = "RuntimeDefault" } }
                containers = [{
                  name    = "backup", image = local.backup_image, workingDir = "/tmp"
                  command = ["/talos-backup"]
                  envFrom = [{ secretRef = { name = "etcd-backup-aws" } }]
                  env = [
                    # The injected config targets the talos.default Service, which spans every controller
                    { name = "TALOSCONFIG", value = "/var/run/secrets/talos.dev/config" },
                    { name = "CLUSTER_NAME", value = var.cluster_name },
                    { name = "BUCKET", value = aws_s3_bucket.etcd_backup.id },
                    { name = "S3_PREFIX", value = local.backup_prefix },
                    { name = "AWS_REGION", value = data.aws_region.current.region },
                    { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
                    # S3 encrypts with the backup KMS key by bucket default instead of age
                    { name = "DISABLE_ENCRYPTION", value = "true" },
                    { name = "HOME", value = "/tmp" }
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

# Existing controllers are found by Name tag, so the step is skipped on first bootstrap
# (none exist) and on re-applies (every desired node already has an instance).
data "aws_instances" "existing_control_plane" {
  filter {
    name   = "tag:Name"
    values = [for k in range(local.control_plane_node_count) : "${var.cluster_name}-control-plane-${k}"]
  }
  instance_state_names = ["pending", "running", "stopping", "stopped"]
}

locals {
  pre_membership_snapshot_needed = (
    var.etcd_pre_membership_snapshot_enabled
    && length(data.aws_instances.existing_control_plane.ids) > 0
    && length(data.aws_instances.existing_control_plane.ids) < local.control_plane_node_count
  )
}

# An etcd join passes through a 2-member state with no fault tolerance, so snapshot first.
# The job uploads a KMS-encrypted snapshot to S3; nothing is written to the operator's disk.
# aws_instance.control_plane depends on this, so a failed job stops the apply before any new instance.
resource "terraform_data" "pre_membership_snapshot" {
  count = local.pre_membership_snapshot_needed ? 1 : 0

  triggers_replace = [for k in range(local.control_plane_node_count) : tostring(k)]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KUBECONFIG = var.etcd_pre_membership_snapshot_kubeconfig
      NAMESPACE  = local.backup_namespace
      CONTEXT    = var.cluster_name
      TIMEOUT    = "${var.etcd_pre_membership_snapshot_timeout_seconds}s"
    }
    command = <<-EOT
      set -euo pipefail
      # The kubeconfig context is named after the cluster; never fall back to another current-context.
      job="etcd-pre-join-$(date +%s)"
      kubectl --context "$CONTEXT" -n "$NAMESPACE" create job --from=cronjob/etcd-backup "$job"
      if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" wait --for=condition=complete --timeout="$TIMEOUT" "job/$job"; then
        echo "etcd snapshot job $NAMESPACE/$job failed or timed out; no controllers were added" >&2
        exit 1
      fi
    EOT
  }

  lifecycle {
    precondition {
      condition     = var.etcd_pre_membership_snapshot_kubeconfig != null && try(trimspace(var.etcd_pre_membership_snapshot_kubeconfig) != "", false)
      error_message = "Adding controllers to an existing cluster needs etcd_pre_membership_snapshot_kubeconfig set in the caller to a kubeconfig that reaches the private Kubernetes API and has a context named cluster_name (kubectl on PATH), or set etcd_pre_membership_snapshot_enabled = false."
    }
  }
}
