terraform {
  required_providers {
    kubectl = { source = "alekc/kubectl", version = "3.0.1" }
    pf      = { source = "panfactum/pf", version = "0.0.7" }

    aws        = { source = "hashicorp/aws", version = "6.73.0" }
    helm       = { source = "hashicorp/helm", version = "3.3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.5.0" }
  }
}

locals {
  name      = "aws-cloud-controller-manager"
  namespace = "kube-system"
}

module "aws_permissions" {
  source                    = "../kube_sa_auth_aws"
  service_account           = local.name
  service_account_namespace = local.namespace
  annotate_service_account  = false
  oidc_provider_arn         = var.oidc_provider_arn
  oidc_issuer_url           = var.oidc_issuer_url
  custom_oidc_enabled       = var.custom_oidc_enabled
  cluster_name              = var.custom_oidc_enabled ? var.cluster_name : null
  iam_tags                  = var.iam_tags
  ip_restrictions_enabled   = var.ip_restrictions_enabled
  cluster_subnet_ids        = var.cluster_subnet_ids
  # Node metadata only; no load balancer, route or EC2 mutation permissions.
  iam_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones", "ec2:DescribeInstanceTopology"]
      Resource = "*"
    }]
  })
}

resource "kubernetes_config_map_v1" "cloud" {
  metadata {
    name      = local.name
    namespace = local.namespace
  }
  # Explicit topology avoids the need for access to instance metadata credentials.
  data = {
    "cloud.conf" = "[Global]\nRegion=${var.region}\nZone=${var.availability_zone}\nVPC=${var.vpc_id}\nSubnetID=${var.subnet_id}\nKubernetesClusterID=${var.cluster_name}\n"
  }
  lifecycle {
    precondition {
      condition     = var.api_ready
      error_message = "The Kubernetes API must be ready before creating the CCM configuration."
    }
  }
}

resource "helm_release" "ccm" {
  name       = local.name
  namespace  = local.namespace
  repository = "https://kubernetes.github.io/cloud-provider-aws"
  chart      = "aws-cloud-controller-manager"
  version    = "0.0.12"
  wait       = true
  atomic     = true
  timeout    = 300
  values = [yamlencode(merge({
    image              = { repository = "registry.k8s.io/provider-aws/cloud-controller-manager", tag = var.image_version }
    serviceAccountName = local.name
    # Restrict Kubernetes access to node metadata, leader election and secure serving.
    # Chart defaults include node deletion and writes to Services/PVs.
    clusterRoleRules = [
      { apiGroups = [""], resources = ["events"], verbs = ["create", "patch", "update"] },
      { apiGroups = [""], resources = ["nodes"], verbs = concat(["get", "list", "watch", "patch", "update"], var.talos_bootstrap_enabled ? ["delete"] : []) },
      { apiGroups = [""], resources = ["nodes/status"], verbs = ["patch", "update"] },
      { apiGroups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["create", "get", "list", "watch", "patch", "update"] },
      { apiGroups = ["authentication.k8s.io"], resources = ["tokenreviews"], verbs = ["create"] },
      { apiGroups = ["authorization.k8s.io"], resources = ["subjectaccessreviews"], verbs = ["create"] }
    ]
    args = [
      "--v=2", "--cloud-provider=aws", "--cloud-config=/etc/aws/cloud.conf",
      var.talos_bootstrap_enabled ? "--controllers=cloud-node,cloud-node-lifecycle" : "--controllers=cloud-node", "--configure-cloud-routes=false",
      "--use-service-account-credentials=false", "--leader-elect=true",
    ]
    env = concat([
      { name = "AWS_REGION", value = var.region },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
      { name = "AWS_STS_REGIONAL_ENDPOINTS", value = "regional" }
      ], var.talos_bootstrap_enabled ? [
      { name = "AWS_ROLE_ARN", value = module.aws_permissions.role_arn },
      { name = "AWS_WEB_IDENTITY_TOKEN_FILE", value = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token" }
      ] : [], var.talos_host_networking ? [
      { name = "KUBERNETES_SERVICE_HOST", value = "127.0.0.1" },
      { name = "KUBERNETES_SERVICE_PORT", value = "7445" }
    ] : [])
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
    extraVolumes = concat([{ name = "cloud-config", configMap = { name = local.name } }], var.talos_bootstrap_enabled ? [
      { name = "aws-web-identity", projected = { sources = [{ serviceAccountToken = { audience = "sts.amazonaws.com", expirationSeconds = 86400, path = "token" } }] } }
    ] : [])
    extraVolumeMounts = concat([{ name = "cloud-config", mountPath = "/etc/aws", readOnly = true }], var.talos_bootstrap_enabled ? [
      { name = "aws-web-identity", mountPath = "/var/run/secrets/eks.amazonaws.com/serviceaccount", readOnly = true }
    ] : [])
    }, var.talos_bootstrap_enabled ? {
    tolerations = concat([
      { key = "node.cloudprovider.kubernetes.io/uninitialized", value = "true", effect = "NoSchedule" },
      ], var.talos_host_networking ? [
      { key = "node.kubernetes.io/not-ready", operator = "Exists", effect = "NoSchedule" },
      ] : [], [
      { key = "node-role.kubernetes.io/master", effect = "NoSchedule" },
      { key = "node-role.kubernetes.io/control-plane", effect = "NoSchedule" },
      { key = "controller", operator = "Equal", value = "true", effect = "NoSchedule" }
    ])
    } : {},
    var.talos_host_networking ? { hostNetworking = true } : {},
    var.talos_host_networking ? { dnsPolicy = "Default" } : {},
  yamldecode(var.helm_values))), yamlencode({ serviceAccount = { annotations = module.aws_permissions.service_account_annotations } })]
  depends_on = [kubernetes_config_map_v1.cloud, module.aws_permissions]
}
