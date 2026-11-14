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
    aws = {
      source                = "hashicorp/aws"
      version               = "6.40.0"
      configuration_aliases = [aws.secondary, aws.global]
    }
    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  name         = "vault"
  namespace    = module.namespace.namespace
  cluster_name = data.pf_metadata.metadata.kube_cluster_name
}

data "pf_kube_labels" "labels" {
  module = "kube_vault"
}
data "pf_metadata" "metadata" {}

module "util_server" {
  source = "../kube_workload_utility"

  workload_name                        = "vault"
  burstable_nodes_enabled              = var.burstable_nodes_enabled
  spot_nodes_enabled                   = var.spot_nodes_enabled
  controller_nodes_enabled             = var.controller_nodes_enabled
  panfactum_scheduler_enabled          = var.panfactum_scheduler_enabled
  pull_through_cache_enabled           = var.pull_through_cache_enabled
  instance_type_anti_affinity_required = var.bootstrap_mode_enabled ? false : var.sla_target == 3
  az_spread_required                   = var.az_spread_required // stateful; opt out only for an explicit single-node topology
  extra_labels                         = data.pf_kube_labels.labels.labels

  # Vault must be scheduled on arm64 nodes as we have installed custom
  # vault plugins and Vault verifies the sha256sum of these binaries before
  # executing them. Unfortunately, only one sha256sum can be assigned to a plugin
  # meaning we can only use a single CPU architecture
  # (as the checksums change depending on whether the binary was compiled for amd64 or arm64).
  # We have chosen to run on arm64 nodes as that is the cheaper architecture on AWS.
  node_requirements = {
    "kubernetes.io/arch" = ["arm64"]
  }
}

module "constants" {
  source = "../kube_constants"
}

data "aws_region" "region" {}
data "aws_caller_identity" "id" {}

/***************************************
* Kubernetes Namespace
***************************************/

module "namespace" {
  source = "../kube_namespace"

  namespace = local.name
}

/***************************************
* AWS KMS Automatic Unseal
***************************************/

module "unseal_key" {
  source = "../aws_kms_encrypt_key"
  providers = {
    aws.secondary = aws.secondary
  }

  name        = "kube-${local.cluster_name}-vault-unseal"
  description = "Vault unseal key for ${local.cluster_name}"

  superuser_iam_arns         = var.superuser_iam_arns
  admin_iam_arns             = var.admin_iam_arns
  reader_iam_arns            = concat([module.aws_permissions.role_arn], var.reader_iam_arns)
  restricted_reader_iam_arns = var.restricted_reader_iam_arns
}

/***************************************
* AWS Permissions
***************************************/

data "aws_iam_policy_document" "sa" {
  statement {
    sid    = "VaultKMSUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [module.unseal_key.arn, module.unseal_key.arn2]
  }
}

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = module.util_server.labels
  }
}

module "aws_permissions" {
  source = "../kube_sa_auth_aws"

  service_account           = kubernetes_service_account.vault.metadata[0].name
  service_account_namespace = local.namespace
  iam_policy_json           = data.aws_iam_policy_document.sa.json
  ip_allow_list             = var.aws_iam_ip_allow_list
  oidc_provider_arn         = var.oidc_provider_arn
  oidc_issuer_url           = var.oidc_issuer_url
  cluster_subnet_ids        = var.cluster_subnet_ids
  ip_restrictions_enabled   = var.ip_restrictions_enabled
}

/***************************************
* Vault Deployment
***************************************/

resource "helm_release" "vault" {
  namespace       = local.namespace
  name            = "vault"
  repository      = var.secrets_engine == "openbao" ? "https://openbao.github.io/openbao-helm" : "https://helm.releases.hashicorp.com"
  chart           = var.secrets_engine == "openbao" ? "openbao" : "vault"
  version         = var.secrets_engine == "openbao" ? "0.30.7" : var.vault_helm_version
  recreate_pods   = false
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  wait_for_jobs   = true
  max_history     = 5

  values = concat([
    yamlencode({

      global = {
        tlsDisable = true // we use a service mesh for this
      }

      // The injector will not work b/c it creates init
      // sidecar containers which means that the linkerd proxy won't
      // be running yet and thus the sidecar cannot communicate with vault.
      // Instead, we utilize secrets-store-csi-driver-provider-vault
      injector = {
        enabled = false
      }

      csi = {
        enabled = false
      }

      ui = {
        enabled = true
      }

      serverTelemetry = {
        serviceMonitor = {
          enabled  = var.monitoring_enabled
          interval = "60s"
        }
        prometheusRules = {
          enabled = var.monitoring_enabled
        }
      }

      server = {

        logLevel  = var.log_level
        logFormat = "json"

        image = {
          repository = "${module.constants.images.vault.registry}/${module.constants.images.vault.repository}"
          tag        = module.constants.images.vault.tag
        }
        resources = {
          requests = {
            memory = "200Mi"
          }
          limits = {
            memory = "260Mi"
          }
        }
        statefulSet = {
          annotations = {
            "reloader.stakater.com/auto" = "true"
            "panfactum.com/vault-addr"   = "https://${var.vault_domain}"
          }
        }
        updateStrategyType = "RollingUpdate"
        extraLabels = merge(
          module.util_server.labels,
          {
            customizationHash = md5(join("", [
              for filename in sort(fileset(path.module, "kustomize/*")) : filesha256(filename)
            ]))
            "panfactum.com/inject-env-enabled" = "false"
          }
        )
        annotations = {
          // This is required to make the external nats plugin work
          // See https://github.com/linkerd/linkerd2/issues/13364
          // "config.linkerd.io/skip-outbound-ports" = "4222"
        }
        serviceAccount = {
          create = false,
          name   = kubernetes_service_account.vault.metadata[0].name
        }
        service = {
          active = {
            // TODO: This needs to ignore intra-cluster traffic as it causes
            // delays during failovers
            annotations = {
              "retry.linkerd.io/http"    = "5xx"
              "retry.linkerd.io/limit"   = "1"
              "retry.linkerd.io/timeout" = "5s"
            }
          }
        }
        dataStorage = {
          enabled      = true
          size         = "${var.vault_storage_size_gb}Gi"
          mountPath    = "/vault/data"
          storageClass = "ebs-standard-retained"
          labels = {
            "panfactum.com/pvc-group" = "${local.namespace}.vault"
          }
          annotations = {
            "resize.topolvm.io/initial-resize-group-by" = "panfactum.com/pvc-group"
          }
        }
        affinity                  = module.util_server.affinity
        tolerations               = module.util_server.tolerations
        topologySpreadConstraints = module.util_server.topology_spread_constraints
        priorityClassName         = module.constants.cluster_important_priority_class_name # Vault can go down temporarily without disrupting the cluster

        extraEnvironmentVars = {
          AWS_REGION   = data.aws_region.region.region
          AWS_ROLE_ARN = module.aws_permissions.role_arn

          // We noticed very slow startup times once the Vault db exceeds 100Mb.
          // This is due to this issue https://github.com/hashicorp/vault/issues/14635
          // which recommends VAULT_RAFT_FREELIST_SYNC as a solution
          VAULT_RAFT_FREELIST_SYNC = "true"
        }

        ha = {
          enabled  = true
          replicas = var.vault_replicas
          disruptionBudget = {
            enabled = false
          }
          raft = {
            enabled   = true
            setNodeId = true
            config = templatefile("${path.module}/${var.secrets_engine == "openbao" ? "ha-openbao.hcl" : "ha.hcl"}", {
              vault_replicas = var.vault_replicas
              disable_mlock  = var.disable_mlock
              aws_region     = data.aws_region.region.region
              kms_key_id     = module.unseal_key.id
              aws_role_arn   = module.aws_permissions.role_arn
            })
          }
        }
      }
    })
    ], var.secrets_engine == "openbao" ? [yamlencode({
      # Preserve the StatefulSet, pods, services and app labels used by existing callers.
      fullnameOverride = "vault"
      nameOverride     = "vault"
      server = {
        image = {
          registry   = "ghcr.io"
          repository = "openbao/openbao"
          tag        = "2.7.2@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f"
        }
        extraEnvironmentVars = {
          PATH = "/compat:/bin:/usr/bin:/usr/local/bin"
        }
        volumes = [
          { name = "openbao-plugins", emptyDir = {} },
          { name = "vault-cli-compat", emptyDir = {} }
        ]
        volumeMounts = [
          { name = "openbao-plugins", mountPath = "/vault/plugins", readOnly = true },
          { name = "vault-cli-compat", mountPath = "/compat", readOnly = true }
        ]
        extraInitContainers = [{
          name    = "install-openbao-plugins"
          image   = "busybox:1.37.0"
          command = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            install_plugin() {
              release="$1"; name="$2"; archive_sha="$3"; binary_sha="$4"
              archive="$name"_linux_arm64_v8.tar.gz
              member="$name"_linux_arm64_v8
              wget -T 60 -O "$work/$archive" "https://github.com/openbao/openbao-plugins/releases/download/$release/$archive"
              echo "$archive_sha  $work/$archive" | sha256sum -c -
              tar -xzf "$work/$archive" -C "$work" "$member"
              echo "$binary_sha  $work/$member" | sha256sum -c -
              cp -f "$work/$member" "/vault/plugins/$name"
              chmod 0555 "/vault/plugins/$name"
            }
            install_plugin kms-aws-v0.1.1 openbao-plugin-kms-aws 8f173d8590d3df52c3501dd3af79b5f90fbc8ae4386b04abb706ca8b82a55b23 986487f17d30123b4730cf412ad2267f7ef4cfe637c75252ed6d13294673bae2
            install_plugin secrets-aws-v0.3.3 openbao-plugin-secrets-aws 549d72a9570920cb07be425a4487a4e7abc78d311b3e6ca85b3e4ee9bfbf4931 670aa9c3f1cff789826ab8c00845760034d8f82afd2cdd57ecf794863e8c7127
            ln -sf /bin/bao /compat/vault
          SCRIPT
          ]
          securityContext = {
            runAsNonRoot             = true
            runAsUser                = 1000
            allowPrivilegeEscalation = false
            capabilities             = { drop = ["ALL"] }
          }
          resources = {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
          volumeMounts = [
            { name = "openbao-plugins", mountPath = "/vault/plugins" },
            { name = "vault-cli-compat", mountPath = "/compat" }
          ]
        }]
      }
    })] : [], [
    yamlencode(var.extra_helm_values)
  ])

  timeout    = 60 * 10
  depends_on = [module.aws_permissions, module.unseal_key]
}

resource "kubernetes_config_map" "dashboard" {
  count = var.monitoring_enabled ? 1 : 0
  metadata {
    name   = "vault-dashboard"
    labels = merge(module.util_server.labels, { "grafana_dashboard" = "1" })
  }
  data = {
    "vault.json" = file("${path.module}/dashboard.json")
  }
}

/***************************************
* PVC Annotator
***************************************/

module "pvc_annotator" {
  source = "../kube_pvc_annotator"

  namespace = local.namespace
  config = {
    "${local.namespace}.vault" = {
      annotations = {
        "resize.topolvm.io/storage_limit" = "${var.vault_storage_limit_gb != null ? var.vault_storage_limit_gb : 10 * var.vault_storage_size_gb}Gi"
        "resize.topolvm.io/increase"      = "${var.vault_storage_increase_gb}Gi"
        "resize.topolvm.io/threshold"     = "${var.vault_storage_increase_threshold_percent}%"
      }
      labels = module.util_server.labels
    }
  }

  depends_on = [helm_release.vault]
}

/***************************************
* Vault Autoscaling
***************************************/

resource "kubectl_manifest" "pdb_server" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "vault"
      namespace = local.namespace
      labels    = module.util_server.labels
    }
    spec = {
      unhealthyPodEvictionPolicy = "AlwaysAllow"
      selector = {
        matchLabels = module.util_server.match_labels
      }
      maxUnavailable = 1
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [helm_release.vault]
}

resource "kubectl_manifest" "vpa_server" {
  count = var.vpa_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "vault"
      namespace = local.namespace
      labels    = module.util_server.labels
    }
    spec = {
      resourcePolicy = {
        containerPolicies = [{
          containerName = var.secrets_engine == "openbao" ? "openbao" : "vault"
          minAllowed = {
            memory = "275Mi"
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
        kind       = "StatefulSet"
        name       = "vault"
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [helm_release.vault]
}

/***************************************
* Vault Ingress
***************************************/

module "ingress" {
  count  = var.ingress_enabled ? 1 : 0
  source = "../kube_ingress"

  namespace = local.namespace
  name      = "vault"
  domains   = [var.vault_domain]
  ingress_configs = [
    {
      service      = "vault-active"
      service_port = 8200
    }
  ]
  cdn_mode_enabled               = var.cdn_mode_enabled
  rate_limiting_enabled          = true
  cross_origin_isolation_enabled = false
  cross_origin_opener_policy     = "same-origin-allow-popups" // Required for SSO logins
  permissions_policy_enabled     = true
  csp_enabled                    = false
  cors_enabled                   = var.cors_enabled
  cors_extra_allowed_origins     = var.cors_extra_allowed_origins

  depends_on = [helm_release.vault]
}

module "cdn" {
  count  = var.ingress_enabled && var.cdn_mode_enabled ? 1 : 0
  source = "../kube_aws_cdn"
  providers = {
    aws.global = aws.global
  }

  name           = "vault"
  origin_configs = module.ingress[0].cdn_origin_configs
}

