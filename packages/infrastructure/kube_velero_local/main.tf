// Local-only Velero: file-system volume backup (node-agent, Kopia) to an S3-compatible endpoint with static
// credentials. It exists beside kube_velero because that module's IRSA, bucket and VolumeSnapshotClass resources
// cannot be made optional without moved blocks that change the AWS caller's plan.
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
  }
}

locals {
  namespace = kubernetes_namespace.velero.metadata[0].name
}

// The node-agent mounts the kubelet pod directory from the host, which pod security rejects below privileged.
resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubernetes_secret" "cloud" {
  metadata {
    name      = "cloud"
    namespace = local.namespace
  }
  data = {
    cloud = "[default]\naws_access_key_id=${var.access_key}\naws_secret_access_key=${var.secret_key}\n"
  }
}

resource "helm_release" "velero" {
  namespace       = local.namespace
  name            = "velero"
  repository      = "https://vmware-tanzu.github.io/helm-charts"
  chart           = "velero"
  version         = var.velero_helm_version
  recreate_pods   = false
  atomic          = false
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true
  timeout         = 600
  max_history     = 5

  values = [
    yamlencode({
      fullnameOverride = "velero"

      image = {
        repository = var.velero_image_repository
        tag        = var.velero_image_tag
      }

      initContainers = [
        {
          name            = "velero-plugin-for-aws"
          image           = var.aws_plugin_image
          imagePullPolicy = "IfNotPresent"
          volumeMounts = [
            {
              mountPath = "/target"
              name      = "plugins"
            }
          ]
        }
      ]

      // The CRD hook jobs need a kubectl image; helm installs the chart's crds/ directory on first install.
      upgradeCRDs = false
      cleanUpCRDs = false

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "1000m", memory = "512Mi" }
      }

      credentials = {
        useSecret      = true
        existingSecret = kubernetes_secret.cloud.metadata[0].name
      }

      metrics = {
        enabled        = false
        serviceMonitor = { enabled = false }
        prometheusRule = { enabled = false }
      }

      snapshotsEnabled = false
      deployNodeAgent  = true
      nodeAgent = {
        podVolumePath = "/var/lib/kubelet/pods"
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "1000m", memory = "1Gi" }
        }
        containerSecurityContext = {
          privileged = true
        }
      }

      configuration = {
        backupStorageLocation = [{
          name       = "default"
          provider   = "aws"
          accessMode = "ReadWrite"
          bucket     = var.bucket
          prefix     = var.prefix
          default    = true
          config = {
            region           = var.region
            s3ForcePathStyle = "true"
            s3Url            = var.s3_url
          }
        }]
        volumeSnapshotLocation     = []
        defaultVolumesToFsBackup   = true
        garbageCollectionFrequency = "5m"
        logFormat                  = "json"
        logLevel                   = var.log_level
        namespace                  = local.namespace
      }
    }),
    yamlencode(var.extra_helm_values)
  ]

  depends_on = [kubernetes_secret.cloud]
}
