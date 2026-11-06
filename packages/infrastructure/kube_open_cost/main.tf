terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  namespace    = module.namespace.namespace
  cluster_name = data.pf_metadata.metadata.kube_cluster_name
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "pf_kube_labels" "labels" {
  module = "kube_open_cost"
}
data "pf_metadata" "metadata" {}

module "util" {
  source = "../kube_workload_utility"

  workload_name                        = "open-cost"
  burstable_nodes_enabled              = var.burstable_nodes_enabled
  spot_nodes_enabled                   = var.spot_nodes_enabled
  controller_nodes_enabled             = var.controller_nodes_enabled
  panfactum_scheduler_enabled          = var.panfactum_scheduler_enabled
  pull_through_cache_enabled           = var.pull_through_cache_enabled
  instance_type_anti_affinity_required = false // single copy
  az_spread_preferred                  = false // single copy
  extra_labels                         = data.pf_kube_labels.labels.labels
}

module "util_network_cost" {
  source = "../kube_workload_utility"

  workload_name                        = "network-cost"
  burstable_nodes_enabled              = var.burstable_nodes_enabled
  spot_nodes_enabled                   = var.spot_nodes_enabled
  controller_nodes_enabled             = var.controller_nodes_enabled
  panfactum_scheduler_enabled          = false
  pull_through_cache_enabled           = var.pull_through_cache_enabled
  instance_type_anti_affinity_required = false // ds
  az_spread_preferred                  = false // ds
  extra_labels                         = data.pf_kube_labels.labels.labels

}


module "constants" {
  source = "../kube_constants"
}

module "namespace" {
  source = "../kube_namespace"

  namespace = "open-cost"
}

/***************************************
* Spot Data Feed
***************************************/


data "aws_iam_policy_document" "spot_data" {
  count = var.spot_data_feed_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition = alltrue([for value in [
        var.spot_data_feed_bucket_arn,
        var.spot_data_feed_bucket,
        var.spot_data_feed_bucket_region
      ] : value == null ? false : length(trimspace(value)) > 0])
      error_message = "Spot data feed requires bucket ARN, name and region; otherwise set spot_data_feed_enabled=false."
    }
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:HeadObject",
    ]
    resources = ["${var.spot_data_feed_bucket_arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:HeadBucket",
      "s3:ListAllMyBuckets"
    ]
    resources = [var.spot_data_feed_bucket_arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation"
    ]
    resources = ["arn:aws:s3:::*"]
  }
}

module "aws_permissions" {
  count  = var.spot_data_feed_enabled ? 1 : 0
  source = "../kube_sa_auth_aws"

  service_account           = kubernetes_service_account.open_cost.metadata[0].name
  service_account_namespace = local.namespace
  iam_policy_json           = data.aws_iam_policy_document.spot_data[0].json
  ip_allow_list             = var.aws_iam_ip_allow_list
  oidc_provider_arn         = var.oidc_provider_arn
  oidc_issuer_url           = var.oidc_issuer_url
  cluster_subnet_ids        = var.cluster_subnet_ids
  ip_restrictions_enabled   = var.ip_restrictions_enabled
}

/***************************************
* OpenCost
***************************************/

resource "kubernetes_service_account" "open_cost" {
  metadata {
    name      = "open-cost"
    namespace = local.namespace
    labels    = module.util.labels
  }
}

resource "helm_release" "open_cost" {
  namespace       = local.namespace
  name            = "open-cost"
  repository      = "https://opencost.github.io/opencost-helm-chart"
  chart           = "opencost"
  version         = var.open_cost_helm_version
  recreate_pods   = false
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  force_update    = true
  wait_for_jobs   = true
  max_history     = 5

  values = [
    yamlencode({
      fullnameOverride = "open-cost"
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.open_cost.metadata[0].name
      }
      podLabels = merge(
        module.util.labels,
        {
          customizationHash = md5(join("", [
            for filename in sort(fileset(path.module, "kustomize/*")) : filesha256(filename)
          ]))
        }
      )
      opencost = {
        customPricing = {
          enabled  = true
          provider = "aws"
          costModel = merge({
            zoneNetworkEgress     = "0.02"
            regionNetworkEgress   = "0.02"
            internetNetworkEgress = "0.09"
            spotLabel             = "karpenter.sh/capacity-type"
            spotLabelValue        = "spot"
            projectID             = data.aws_caller_identity.current.account_id
            }, var.spot_data_feed_enabled ? {
            awsSpotDataBucket = var.spot_data_feed_bucket
            awsSpotDataRegion = var.spot_data_feed_bucket_region
          } : {})
        }
        cloudCost = {
          enabled = false
        }

        exporter = {
          defaultClusterId = local.cluster_name
          extraEnv = {
            EMIT_KSM_V1_METRICS      = false
            EMIT_KSM_V1_METRICS_ONLY = true
          }
          resources = {
            requests = {
              cpu    = "100m"
              memory = "200Mi"
            }
            limits = {
              memory = "260Mi"
            }
          }
        }
        ui = {
          enabled = false // We use grafana
        }
        metrics = {
          serviceMonitor = {
            enabled        = var.monitoring_enabled
            scrapeInterval = "60s"
            namespace      = local.namespace
            honorLabels    = true
          }
        }
        prometheus = {
          external = {
            enabled = var.prometheus_endpoint != null
            url     = var.prometheus_endpoint
          }
          internal = {
            enabled       = var.prometheus_endpoint == null
            namespaceName = "monitoring"
            serviceName   = "thanos-query-frontend"
            port          = 9090
          }
        }

        priorityClassName = module.constants.cluster_important_priority_class_name
        affinity          = module.util.affinity
        tolerations       = module.util.tolerations

        service = {
          labels = module.util.labels
        }
      }
    }),
    yamlencode(var.extra_helm_values)
  ]
}

resource "kubectl_manifest" "vpa" {
  count = var.vpa_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "open-cost"
      namespace = local.namespace
      labels    = module.util.labels
    }
    spec = {
      resourcePolicy = {
        containerPolicies = [{
          containerName = "open-cost"
          minAllowed = {
            memory = "150Mi"
          }
        }]
      }
      updatePolicy = {
        updateMode = "Auto"
        evictionRequirements = [{
          resources         = ["cpu", "memory"]
          changeRequirement = "TargetHigherThanRequests"
        }]
      }
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = "open-cost"
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [helm_release.open_cost]
}

/***************************************
* Network Cost
***************************************/

resource "kubernetes_service_account" "network_cost" {
  count = var.network_cost_enabled ? 1 : 0
  metadata {
    name      = "network-cost"
    labels    = module.util_network_cost.labels
    namespace = local.namespace
  }
}

resource "kubernetes_cluster_role" "network_cost" {
  count = var.network_cost_enabled ? 1 : 0
  metadata {
    name   = "network-cost"
    labels = module.util_network_cost.labels
  }
  rule {
    api_groups = [""]
    resources = [
      "configmaps",
      "nodes",
      "pods",
      "events",
      "services",
      "resourcequotas",
      "replicationcontrollers",
      "limitranges",
      "persistentvolumeclaims",
      "persistentvolumes",
      "namespaces",
      "endpoints"
    ]
    verbs = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources = [
      "statefulsets",
      "deployments",
      "daemonsets",
      "replicasets"
    ]
    verbs = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["batch"]
    resources = [
      "jobs",
      "cronjobs"
    ]
    verbs = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["events.k8s.io"]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "network_cost" {
  count = var.network_cost_enabled ? 1 : 0
  metadata {
    name   = "network-cost"
    labels = module.util_network_cost.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.network_cost[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.network_cost[0].metadata[0].name
    namespace = local.namespace
  }
}

# We consider s3 IPs to be "in-zone" b/c we use the
# s3 endpoint
data "aws_ip_ranges" "s3" {
  count    = var.network_cost_enabled ? 1 : 0
  regions  = [data.aws_region.current.region]
  services = ["s3"]
}

resource "kubernetes_config_map" "network_cost" {
  count = var.network_cost_enabled ? 1 : 0
  metadata {
    name      = "network-cost-config"
    labels    = module.util_network_cost.labels
    namespace = local.namespace
  }
  data = {
    "config.yaml" = yamlencode({
      destinations = {
        in-zone = concat([
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ], data.aws_ip_ranges.s3[0].cidr_blocks)
        direct-classification = [
          {
            region = "us-east-2"
            zone   = "us-east-2a"
            ips = [
              "10.0.16.0/20",
              "10.0.64.0/18"
            ]
          },
          {
            region = "us-east-2"
            zone   = "us-east-2b",
            ips = [
              "10.0.58.0/20",
              "10.0.128.0/18"
            ]
          },
          {
            region = "us-east-2"
            zone   = "us-east-2c"
            ips = [
              "10.0.58.0/20",
              "10.0.192.0/18"
            ]
          }
        ]
      }
      services = {
        amazon-web-services   = true
        google-cloud-services = false
        azure-cloud-services  = false
      }
    })
  }
}

resource "kubectl_manifest" "network_cost" {
  count = var.network_cost_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "DaemonSet"
    metadata = {
      name      = "network-cost"
      namespace = local.namespace
      labels    = module.util_network_cost.labels
    }
    spec = {
      updateStrategy = {
        type = "RollingUpdate"
        rollingUpdate = {
          maxUnavailable = "34%"
          maxSurge       = 0
        }
      }
      selector = {
        matchLabels = module.util_network_cost.match_labels
      }
      template = {
        metadata = {
          labels = module.util_network_cost.labels
        }
        spec = {
          hostNetwork = true

          serviceAccountName = kubernetes_service_account.network_cost[0].metadata[0].name
          priorityClassName  = module.constants.cluster_important_priority_class_name
          tolerations        = module.util_network_cost.tolerations
          affinity           = module.util_network_cost.affinity
          containers = [{
            name  = "network-cost"
            image = "public.ecr.aws/kubecost/kubecost-network-costs:v0.17.3"
            securityContext = {
              privileged = true
            }
            env = [
              {
                name = "NODE_NAME"
                valueFrom = {
                  fieldRef = {
                    fieldPath = "spec.nodeName"
                  }
                }
              },
              {
                name  = "HOST_PORT"
                value = "3001"
              }
            ]
            ports = [
              {
                name          = "http-server"
                containerPort = 3001
                hostPort      = 3001
              }
            ]
            volumeMounts = [
              {
                name      = "nf-conntrack"
                mountPath = "/net"
              },
              {
                name      = "netfilter"
                mountPath = "/netfilter"
              },
              {
                name      = kubernetes_config_map.network_cost[0].metadata[0].name
                mountPath = "/network-costs/config"
              }
            ]
            resources = {
              requests = {
                cpu    = "50m"
                memory = "100Mi"
              }
              limits = {
                memory = "130Mi"
              }
            }
          }]
          volumes = [
            {
              name = kubernetes_config_map.network_cost[0].metadata[0].name
              configMap = {
                name = kubernetes_config_map.network_cost[0].metadata[0].name
              }
            },
            {
              name = "nf-conntrack"
              hostPath = {
                path = "/proc/net"
              }
            },
            {
              name = "netfilter"
              hostPath = {
                path = "/proc/sys/net/netfilter"
              }
            },
          ]
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

resource "kubectl_manifest" "network_cost_pod_monitor" {
  count = var.network_cost_enabled && var.monitoring_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "network-cost"
      namespace = local.namespace
      labels    = module.util_network_cost.labels
    }
    spec = {
      podMetricsEndpoints = [
        {
          port          = "http-server"
          honorLabels   = true
          interval      = "1m"
          scrapeTimeout = "10s"
          path          = "/metrics"
          scheme        = "http"
        }
      ]
      namespaceSelector = {
        matchNames = [local.namespace]
      }
      selector = {
        matchLabels = module.util_network_cost.match_labels
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.network_cost]
}

resource "kubectl_manifest" "vpa_network_cost" {
  count = var.network_cost_enabled && var.vpa_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "network-cost"
      namespace = local.namespace
      labels    = module.util_network_cost.labels
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "DaemonSet"
        name       = "network-cost"
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.network_cost]
}

// Preserve existing state addresses when introducing optional components.

moved {
  from = kubernetes_service_account.network_cost
  to   = kubernetes_service_account.network_cost[0]
}

moved {
  from = kubernetes_cluster_role.network_cost
  to   = kubernetes_cluster_role.network_cost[0]
}

moved {
  from = kubernetes_cluster_role_binding.network_cost
  to   = kubernetes_cluster_role_binding.network_cost[0]
}

moved {
  from = kubernetes_config_map.network_cost
  to   = kubernetes_config_map.network_cost[0]
}

moved {
  from = kubectl_manifest.network_cost
  to   = kubectl_manifest.network_cost[0]
}

moved {
  from = kubectl_manifest.network_cost_pod_monitor
  to   = kubectl_manifest.network_cost_pod_monitor[0]
}

moved {
  from = module.aws_permissions
  to   = module.aws_permissions[0]
}
