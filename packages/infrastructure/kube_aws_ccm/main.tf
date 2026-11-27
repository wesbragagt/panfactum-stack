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

data "aws_region" "current" {}

data "aws_instance" "controller" {
  instance_id = regex("[^/]+$", var.controller_provider_ids[sort(keys(var.controller_provider_ids))[0]])
}

data "aws_subnet" "controller" {
  id = data.aws_instance.controller.subnet_id
}

module "aws_permissions" {
  source                    = "../kube_sa_auth_aws"
  service_account           = local.name
  service_account_namespace = local.namespace
  annotate_service_account  = false
  oidc_provider_arn         = var.cluster.oidc_provider_arn
  oidc_issuer_url           = var.cluster.oidc_issuer_url
  custom_oidc_enabled       = true
  cluster_name              = var.cluster.name
  ip_restrictions_enabled   = false
  # NOTE: CCM discovers node metadata. Load balancer and route controllers are disabled.
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
  # NOTE: Explicit topology lets CCM run without instance metadata credentials.
  data = {
    "cloud.conf" = join("\n", [
      "[Global]",
      "Region=${data.aws_region.current.region}",
      "Zone=${data.aws_subnet.controller.availability_zone}",
      "VPC=${data.aws_subnet.controller.vpc_id}",
      "SubnetID=${data.aws_subnet.controller.id}",
      "KubernetesClusterID=${var.cluster.name}",
      "",
    ])
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
  values = [
    yamlencode({
      image              = { repository = "registry.k8s.io/provider-aws/cloud-controller-manager", tag = var.image_version }
      serviceAccountName = local.name
      hostNetworking     = true
      dnsPolicy          = "Default"
      # NOTE: Chart defaults grant write access to Services and PersistentVolumes.
      clusterRoleRules = [
        { apiGroups = [""], resources = ["events"], verbs = ["create", "patch", "update"] },
        { apiGroups = [""], resources = ["nodes"], verbs = ["get", "list", "watch", "patch", "update", "delete"] },
        { apiGroups = [""], resources = ["nodes/status"], verbs = ["patch", "update"] },
        { apiGroups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["create", "get", "list", "watch", "patch", "update"] },
        { apiGroups = ["authentication.k8s.io"], resources = ["tokenreviews"], verbs = ["create"] },
        { apiGroups = ["authorization.k8s.io"], resources = ["subjectaccessreviews"], verbs = ["create"] }
      ]
      args = [
        "--v=2", "--cloud-provider=aws", "--cloud-config=/etc/aws/cloud.conf",
        "--controllers=cloud-node,cloud-node-lifecycle", "--configure-cloud-routes=false",
        "--use-service-account-credentials=false", "--leader-elect=true",
      ]
      env = [
        { name = "AWS_REGION", value = data.aws_region.current.region },
        { name = "AWS_DEFAULT_REGION", value = data.aws_region.current.region },
        { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
        { name = "AWS_STS_REGIONAL_ENDPOINTS", value = "regional" },
        { name = "AWS_ROLE_ARN", value = module.aws_permissions.role_arn },
        { name = "AWS_WEB_IDENTITY_TOKEN_FILE", value = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token" },
        { name = "KUBERNETES_SERVICE_HOST", value = "127.0.0.1" },
        { name = "KUBERNETES_SERVICE_PORT", value = "7445" }
      ]
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
      extraVolumes = [
        { name = "cloud-config", configMap = { name = local.name } },
        { name = "aws-web-identity", projected = { sources = [{ serviceAccountToken = { audience = "sts.amazonaws.com", expirationSeconds = 86400, path = "token" } }] } }
      ]
      extraVolumeMounts = [
        { name = "cloud-config", mountPath = "/etc/aws", readOnly = true },
        { name = "aws-web-identity", mountPath = "/var/run/secrets/eks.amazonaws.com/serviceaccount", readOnly = true }
      ]
      tolerations = [
        { key = "node.cloudprovider.kubernetes.io/uninitialized", value = "true", effect = "NoSchedule" },
        { key = "node.kubernetes.io/not-ready", operator = "Exists", effect = "NoSchedule" },
        { key = "node-role.kubernetes.io/master", effect = "NoSchedule" },
        { key = "node-role.kubernetes.io/control-plane", effect = "NoSchedule" },
        { key = "controller", operator = "Equal", value = "true", effect = "NoSchedule" }
      ]
    }),
    yamlencode({ serviceAccount = { annotations = module.aws_permissions.service_account_annotations } })
  ]
  depends_on = [kubernetes_config_map_v1.cloud, module.aws_permissions, terraform_data.controller_provider_id]
}
