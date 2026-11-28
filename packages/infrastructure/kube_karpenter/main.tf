// Live

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "3.0.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  name                   = "karpenter"
  namespace              = module.namespace.namespace
  cluster_name           = coalesce(try(var.cluster.name, null), var.cluster_name, data.pf_metadata.metadata.kube_cluster_name)
  cluster_endpoint       = var.cluster == null ? var.cluster_endpoint : var.cluster.endpoint
  region                 = coalesce(var.aws_region, data.aws_region.main.region)
  karpenter_helm_version = coalesce(var.karpenter_helm_version, var.cluster == null ? "1.10.0" : "1.15.1")
}

data "aws_region" "main" {}
data "aws_caller_identity" "main" {}

// Optional IAM launch-resource scope. NodeClass selectors must independently
// select the same VPC; Karpenter has no controller-wide VPC-ID setting.
data "aws_subnets" "cluster" {
  count = var.vpc_id == null ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}
data "aws_security_groups" "cluster" {
  count = var.vpc_id == null ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "pf_kube_labels" "labels" {
  module = "kube_karpenter"
}

data "pf_aws_tags" "tags" {
  module = "kube_karpenter"
}

data "pf_metadata" "metadata" {}

module "util" {
  source = "../kube_workload_utility"

  workload_name                        = "karpenter"
  az_spread_preferred                  = var.sla_target == 3 || var.worker_nodes_preferred
  instance_type_anti_affinity_required = false // Cannot be true b/c runs on controller nodes
  host_anti_affinity_required          = var.sla_target == 3 || var.worker_nodes_preferred
  controller_nodes_required            = !var.worker_nodes_preferred
  controller_nodes_enabled             = var.worker_nodes_preferred
  node_requirements                    = var.worker_nodes_preferred ? { "panfactum.com/class" = ["worker", "spot", "controller"] } : {}
  node_preferences = var.worker_nodes_preferred ? {
    "panfactum.com/class"        = { weight = 100, operator = "In", values = ["worker"] }
    "karpenter.sh/capacity-type" = { weight = 50, operator = "In", values = ["spot"] }
  } : {}
  burstable_nodes_enabled     = true
  extra_labels                = data.pf_kube_labels.labels.labels
  pull_through_cache_enabled  = var.pull_through_cache_enabled
  panfactum_scheduler_enabled = false
}

module "constants" {
  source = "../kube_constants"
}

module "namespace" {
  source = "../kube_namespace"

  namespace      = local.name
  linkerd_inject = var.namespace_linkerd_inject
}

/********************************************************************************************************************
* AWS Termination Queue Resources
*********************************************************************************************************************/

resource "aws_sqs_queue" "karpenter" {
  name_prefix               = "${local.cluster_name}-"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags = merge(data.pf_aws_tags.tags.tags, {
    description = "Used by Karpenter to detect node termination events in advance"
  })
}

data "aws_iam_policy_document" "karpenter_sqs" {
  statement {
    sid       = "EC2InterruptionPolicy"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter.arn]
    principals {
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy    = data.aws_iam_policy_document.karpenter_sqs.json
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name_prefix = "karpenter-scheduled-change-"
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
  tags = data.pf_aws_tags.tags.tags
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter.arn
  rule      = aws_cloudwatch_event_rule.scheduled_change.name
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name_prefix = "karpenter-spot-interruption-"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = data.pf_aws_tags.tags.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter.arn
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name_prefix = "karpenter-spot-interruption-"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = data.pf_aws_tags.tags.tags
}

resource "aws_cloudwatch_event_target" "rebalance" {
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter.arn
  rule      = aws_cloudwatch_event_rule.rebalance.name
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name_prefix = "karpenter-spot-interruption-"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
  tags = data.pf_aws_tags.tags.tags
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter.arn
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
}

/********************************************************************************************************************
* Karpenter Controller Deployment
*********************************************************************************************************************/

// This is taken from their cloudformation template, not their website docs
// as the website docs permissions were incorrectly scoped
// See https://github.com/aws/karpenter/blob/main/website/content/en/v0.31/getting-started/getting-started-with-karpenter/cloudformation.yaml
data "aws_iam_policy_document" "karpenter" {
  source_policy_documents = var.additional_controller_policy_json == null ? [] : [var.additional_controller_policy_json]

  dynamic "statement" {
    for_each = var.cluster != null && startswith(local.karpenter_helm_version, "1.15.") && !contains(
      try([for statement in flatten([jsondecode(var.additional_controller_policy_json).Statement]) : try(statement.Sid, "")], []),
      "AllowKarpenter115RegionalReads"
    ) ? [1] : []
    content {
      sid       = "AllowKarpenter115RegionalReads"
      effect    = "Allow"
      actions   = ["ec2:DescribeCapacityReservations", "ec2:DescribeInstanceStatus", "ec2:DescribePlacementGroups"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        values   = [local.region]
        variable = "aws:RequestedRegion"
      }
    }
  }
  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]
    resources = [
      "arn:aws:ec2:${local.region}::image/*",
      "arn:aws:ec2:${local.region}::snapshot/*"
    ]
  }
  // NOTE: Scoping by the ec2:Vpc condition key keeps the policy size independent of
  // the number of subnets and security groups, which otherwise exceeds the 6144 character IAM limit.
  statement {
    sid    = "AllowScopedEC2NetworkAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]
    resources = [
      "arn:aws:ec2:${local.region}:*:security-group/*",
      "arn:aws:ec2:${local.region}:*:subnet/*"
    ]
    dynamic "condition" {
      for_each = var.vpc_id == null ? [] : [1]
      content {
        test     = "ArnEquals"
        values   = ["arn:aws:ec2:${local.region}:${data.aws_caller_identity.main.account_id}:vpc/${var.vpc_id}"]
        variable = "ec2:Vpc"
      }
    }
  }
  statement {
    sid    = "AllowScopedEC2LaunchTemplateAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]
    resources = [
      "arn:aws:ec2:${local.region}:*:launch-template/*"
    ]
    condition {
      test     = "StringEquals"
      values   = ["owned"]
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}"
    }
    condition {
      test     = "StringLike"
      values   = ["*"]
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
    }
  }


  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate"
    ]
    resources = [
      "arn:aws:ec2:${local.region}:*:fleet/*",
      "arn:aws:ec2:${local.region}:*:instance/*",
      "arn:aws:ec2:${local.region}:*:volume/*",
      "arn:aws:ec2:${local.region}:*:network-interface/*",
      "arn:aws:ec2:${local.region}:*:launch-template/*",
      "arn:aws:ec2:${local.region}:*:spot-instances-request/*"
    ]
    condition {
      test     = "StringEquals"
      values   = ["owned"]
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}"
    }
    condition {
      test     = "StringEquals"
      values   = [local.cluster_name]
      variable = "aws:RequestTag/eks:eks-cluster-name"
    }
    condition {
      test     = "StringLike"
      values   = ["*"]
      variable = "aws:RequestTag/karpenter.sh/nodepool"
    }
  }


  statement {
    sid    = "AllowScopedResourceCreationTagging"
    effect = "Allow"
    actions = [
      "ec2:CreateTags"
    ]
    resources = [
      "arn:aws:ec2:${local.region}:*:fleet/*",
      "arn:aws:ec2:${local.region}:*:instance/*",
      "arn:aws:ec2:${local.region}:*:volume/*",
      "arn:aws:ec2:${local.region}:*:network-interface/*",
      "arn:aws:ec2:${local.region}:*:launch-template/*",
      "arn:aws:ec2:${local.region}:*:spot-instances-request/*"
    ]

    condition {
      test     = "StringEquals"
      values   = ["owned"]
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}"
    }
    condition {
      test     = "StringEquals"
      values   = [local.cluster_name]
      variable = "aws:RequestTag/eks:eks-cluster-name"
    }
    condition {
      test = "StringEquals"
      values = [
        "RunInstances",
        "CreateFleet",
        "CreateLaunchTemplate"
      ]
      variable = "ec2:CreateAction"
    }
    condition {
      test     = "StringLike"
      values   = ["*"]
      variable = "aws:RequestTag/karpenter.sh/nodepool"
    }
  }

  statement {
    sid    = "AllowScopedResourceTagging"
    effect = "Allow"
    actions = [
      "ec2:CreateTags"
    ]
    resources = [
      "arn:aws:ec2:${local.region}:*:instance/*",
      "arn:aws:ec2:${local.region}:*:spot-instances-request/*"
    ]
    condition {
      test     = "StringEquals"
      values   = ["owned"]
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}"
    }
    condition {
      test     = "StringEqualsIfExists"
      values   = [local.cluster_name]
      variable = "aws:RequestTag/eks:eks-cluster-name"
    }
    condition {
      test     = "StringLike"
      values   = ["*"]
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
    }
    condition {
      test = "ForAllValues:StringEquals"
      values = [
        "karpenter.sh/nodeclaim",
        "Name",
        "eks:eks-cluster-name"
      ]
      variable = "aws:TagKeys"
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate"
    ]
    resources = [
      "arn:aws:ec2:${local.region}:*:instance/*",
      "arn:aws:ec2:${local.region}:*:launch-template/*"
    ]
    condition {
      test     = "StringEquals"
      values   = ["owned"]
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}"
    }
    condition {
      test     = "StringLike"
      values   = ["*"]
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
    }
  }

  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      values   = [local.region]
      variable = "aws:RequestedRegion"
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${local.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage"
    ]
    resources = [aws_sqs_queue.karpenter.arn]
  }

  statement {
    sid    = "AllowPassingInstanceRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [local.talos_worker_identity_enabled ? aws_iam_role.talos_worker[0].arn : var.node_role_arn]
    condition {
      test     = "StringEquals"
      values   = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
      variable = "iam:PassedToService"
    }
  }

  dynamic "statement" {
    for_each = local.manage_instance_profiles_enabled ? [1] : []
    content {
      sid    = "AllowScopedInstanceProfileCreationActions"
      effect = "Allow"
      actions = [
        "iam:CreateInstanceProfile"
      ]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        values   = ["owned"]
        variable = "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}"
      }
      condition {
        test     = "StringEquals"
        values   = [local.cluster_name]
        variable = "aws:RequestTag/eks:eks-cluster-name"
      }
      condition {
        test     = "StringLike"
        values   = ["*"]
        variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      }
      condition {
        test     = "StringEquals"
        values   = [local.region]
        variable = "aws:RequestTag/topology.kubernetes.io/region"
      }

    }
  }

  dynamic "statement" {
    for_each = local.manage_instance_profiles_enabled ? [1] : []
    content {
      sid    = "AllowScopedInstanceProfileTagActions"
      effect = "Allow"
      actions = [
        "iam:TagInstanceProfile"
      ]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        values   = ["owned"]
        variable = "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}"
      }
      condition {
        test     = "StringEquals"
        values   = [local.cluster_name]
        variable = "aws:RequestTag/eks:eks-cluster-name"
      }
      condition {
        test     = "StringEquals"
        values   = [local.region]
        variable = "aws:RequestTag/topology.kubernetes.io/region"
      }
      condition {
        test     = "StringEquals"
        values   = ["owned"]
        variable = "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}"
      }
      condition {
        test     = "StringEquals"
        values   = [local.region]
        variable = "aws:ResourceTag/topology.kubernetes.io/region"
      }
      condition {
        test     = "StringLike"
        values   = ["*"]
        variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      }
      condition {
        test     = "StringLike"
        values   = ["*"]
        variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      }

    }
  }

  dynamic "statement" {
    for_each = local.manage_instance_profiles_enabled ? [1] : []
    content {
      sid    = "AllowScopedInstanceProfileActions"
      effect = "Allow"
      actions = [
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        values   = ["owned"]
        variable = "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}"
      }
      condition {
        test     = "StringEquals"
        values   = [local.region]
        variable = "aws:ResourceTag/topology.kubernetes.io/region"
      }
      condition {
        test     = "StringLike"
        values   = ["*"]
        variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      }

    }
  }

  statement {
    sid    = "AllowInstanceProfileReadActions"
    effect = "Allow"
    actions = [
      "iam:GetInstanceProfile",

    ]
    // NodeClass finalization reads the generated <cluster>_<hash> profile even when an
    // existing profile is used; AccessDenied instead of NoSuchEntity blocks the finalizer.
    resources = !local.talos_worker_identity_enabled && var.existing_instance_profile_arn == null ? ["*"] : [
      local.worker_instance_profile_arn,
      "arn:${local.talos_worker_identity_enabled ? data.aws_partition.talos_worker[0].partition : "aws"}:iam::${data.aws_caller_identity.main.account_id}:instance-profile/${local.cluster_name}_*"
    ]
  }

  // ListInstanceProfiles has no resource-level scope and is also used by
  // upstream profile inventory/cleanup code, including mixed profile modes.
  statement {
    sid       = "AllowInstanceProfileListActions"
    effect    = "Allow"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.cluster_endpoint == null ? [1] : []
    content {
      sid    = "AllowAPIServerEndpointDiscovery"
      effect = "Allow"
      actions = [
        "eks:DescribeCluster",
      ]
      resources = ["arn:aws:eks:${local.region}:${data.aws_caller_identity.main.account_id}:cluster/${local.cluster_name}"]

    }
  }
}

resource "kubernetes_service_account" "karpenter" {
  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = module.util.labels
  }
}

module "aws_permissions" {
  source = "../kube_sa_auth_aws"

  service_account           = kubernetes_service_account.karpenter.metadata[0].name
  service_account_namespace = local.namespace
  iam_policy_json           = data.aws_iam_policy_document.karpenter.json
  ip_allow_list             = var.aws_iam_ip_allow_list
  oidc_provider_arn         = var.cluster == null ? var.oidc_provider_arn : var.cluster.oidc_provider_arn
  oidc_issuer_url           = var.cluster == null ? var.oidc_issuer_url : var.cluster.oidc_issuer_url
  cluster_subnet_ids        = var.cluster_subnet_ids
  ip_restrictions_enabled   = var.ip_restrictions_enabled
}

resource "helm_release" "karpenter_crds" {
  namespace       = local.namespace
  name            = "karpenter-crd"
  repository      = "oci://public.ecr.aws/karpenter"
  chart           = "karpenter-crd"
  version         = local.karpenter_helm_version
  recreate_pods   = false
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  wait_for_jobs   = true
  force_update    = true # required b/c the CRDs might already be installed
  max_history     = 5

  // NOTE: CRDs must exist before the controller starts, otherwise it crash-loops on missing NodeClaim kinds.
}

resource "helm_release" "karpenter" {
  # Projected credentials must be present when the Pod is admitted.
  depends_on      = [module.aws_permissions, helm_release.karpenter_crds]
  namespace       = local.namespace
  name            = "karpenter"
  repository      = "oci://public.ecr.aws/karpenter"
  chart           = "karpenter"
  version         = local.karpenter_helm_version
  recreate_pods   = false
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  wait_for_jobs   = true
  force_update    = true
  skip_crds       = true # managed above
  max_history     = 5

  lifecycle {
    precondition {
      condition     = local.manage_instance_profiles_enabled || local.worker_instance_profile_arn != null
      error_message = "Provide existing_instance_profile_arn when disabling instance profile management, and use the matching EC2NodeClass instanceProfile."
    }
    precondition {
      condition     = var.vpc_id == null ? true : (length(data.aws_subnets.cluster[0].ids) > 0 && length(data.aws_security_groups.cluster[0].ids) > 0)
      error_message = "The selected VPC must contain at least one subnet and security group in the configured AWS provider region."
    }
  }

  values = [
    yamlencode({
      nameOverride     = local.name
      fullnameOverride = local.name
      podLabels        = module.util.labels
      podAnnotations = {
        "linkerd.io/inject" = "disabled" // We shouldn't have this in the service mesh as it is required for launching the mesh
      }
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.karpenter.metadata[0].name
      }

      controller = {
        env = var.aws_region == null ? [] : [
          { name = "AWS_REGION", value = var.aws_region },
          { name = "AWS_DEFAULT_REGION", value = var.aws_region },
          { name = "AWS_EC2_METADATA_DISABLED", value = "true" }
        ]
        resources = {
          requests = {
            memory = "400Mi"
          }
          limits = {
            memory = "520Mi"
          }
        }
      }

      webhook = {
        enabled = true
      }

      serviceMonitor = {
        enabled          = var.monitoring_enabled
        additionalLabels = module.util.labels
        endpointConfig = {
          scrapeInterval = "60s"
        }
      }

      // This must be node-critical as we need to ensure that this is running in order for
      // new nodes to be created
      priorityClassName = "system-node-critical"

      replicas                  = var.replicas == null ? (var.sla_target == 3 ? 2 : 1) : var.replicas
      topologySpreadConstraints = module.util.topology_spread_constraints
      tolerations               = module.util.tolerations
      affinity                  = module.util.affinity
      nodeSelector = merge(
        { "kubernetes.io/os" = "linux" },
        var.worker_nodes_preferred ? {} : { "panfactum.com/class" = "controller" }
      )
      settings = merge({
        clusterName       = local.cluster_name
        interruptionQueue = aws_sqs_queue.karpenter.name
        featureGates = {
          spotToSpotConsolidation = true
        }

        // Due to the way the VPA sets resource requests and limits (mutating webhook)
        // Karpenter does not know in advance how many resources the daemonsets
        // will need. As a result, it may schedule nodes that can only run
        // the daemonsets (and not other pending pods). This will create an infinite
        // scale-up loop.
        // To mitigate this, we provide a generous amount of spare overhead capacity
        // during its sizing calculations by bumping vmMemoryOverheadPercent significantly.
        // This ensures that new nodes can run the dynamically sized daemonsets
        // as well as the other pods.
        vmMemoryOverheadPercent = "0.2"
      }, local.cluster_endpoint == null ? {} : { clusterEndpoint = local.cluster_endpoint, eksControlPlane = false })

      strategy = {
        rollingUpdate = {
          maxSurge       = var.sla_target == 3 ? 0 : 1
          maxUnavailable = var.sla_target == 3 ? 1 : 0
        }
      }

      logConfig = {
        enabled     = true
        logEncoding = "json",
        logLevel = {
          controller = var.log_level
          webhook    = var.log_level
          global     = var.log_level
        }
      }
    }),
    yamlencode(var.extra_helm_values)
  ]
}

resource "kubernetes_config_map" "dashboard" {
  count = var.monitoring_enabled ? 1 : 0
  metadata {
    name   = "karpenter-dashboard"
    labels = merge(module.util.labels, { "grafana_dashboard" = "1" })
  }
  data = {
    "karpenter.json" = file("${path.module}/dashboard.json")
  }
}

resource "kubectl_manifest" "vpa" {
  count = var.vpa_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = local.name
      namespace = local.namespace
      labels    = module.util.labels
    }
    spec = {
      updatePolicy = {
        updateMode = "Auto"
        evictionRequirements = [{
          resources         = ["cpu", "memory"]
          changeRequirement = "TargetHigherThanRequests"
        }]
      }
      resourcePolicy = {
        containerPolicies = [{
          containerName = "controller"
          maxAllowed = {
            cpu = "500m"
          }
        }]
      }
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = local.name
      }
    }
  })
  force_conflicts   = true
  server_side_apply = true
  depends_on        = [helm_release.karpenter]
}
