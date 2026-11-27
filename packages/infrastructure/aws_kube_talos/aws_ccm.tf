variable "aws_ccm" {
  description = "AWS cloud controller manager settings. Set host_networking to false to run CCM on the pod network."
  type = object({
    image_version           = optional(string)
    host_networking         = optional(bool, true)
    subnet_id               = optional(string)
    availability_zone       = optional(string)
    ip_restrictions_enabled = optional(bool, false)
    cluster_subnet_ids      = optional(set(string))
    iam_tags                = optional(map(string))
    helm_values             = optional(string, "{}")
    operator_kube_port      = optional(number, 16443)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      (var.aws_ccm.image_version == null ? true : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.aws_ccm.image_version))) &&
      var.aws_ccm.operator_kube_port >= 1 && var.aws_ccm.operator_kube_port <= 65535 &&
      floor(var.aws_ccm.operator_kube_port) == var.aws_ccm.operator_kube_port
    )
    error_message = "Pin a CCM image in vMAJOR.MINOR.PATCH form and supply a valid local SSM Kubernetes port."
  }

  validation {
    condition = (
      var.aws_ccm.image_version == null ? (
        contains(keys(local.ccm_default_images), local.ccm_kube_minor)
        ) : (
        try(
          split(".", trimprefix(var.aws_ccm.image_version, "v"))[0] == split(".", trimprefix(var.kube_version, "v"))[0] &&
          contains([0, 1], tonumber(split(".", trimprefix(var.kube_version, "v"))[1]) - tonumber(split(".", trimprefix(var.aws_ccm.image_version, "v"))[1])),
          false
        )
      )
    )
    error_message = "AWS CCM requires an image matching the Kubernetes major and at most one minor behind. Set image_version explicitly when no default exists for that minor."
  }

  validation {
    condition = try(contains(keys(merge(yamldecode(var.aws_ccm.helm_values))), "image") ? try(
      yamldecode(var.aws_ccm.helm_values).image.tag == (
        var.aws_ccm.image_version != null ? var.aws_ccm.image_version : lookup(local.ccm_default_images, local.ccm_kube_minor, null)
      ),
      can(keys(yamldecode(var.aws_ccm.helm_values).image))
    ) : true, false)
    error_message = "AWS CCM helm_values must be a mapping. If it sets image.tag, the tag must match the selected CCM image_version."
  }
}

locals {
  ccm_name           = "aws-cloud-controller-manager"
  ccm_namespace      = "kube-system"
  ccm_default_images = { "1.36" = "v1.36.1" }
  ccm_kube_minor     = try(join(".", slice(split(".", trimprefix(var.kube_version, "v")), 0, 2)), "")
  ccm_image_version  = var.aws_ccm.image_version != null ? var.aws_ccm.image_version : lookup(local.ccm_default_images, local.ccm_kube_minor, null)
  ccm_ssm = var.talos_access_transport == "ssm" || (
    var.talos_access_transport == "" &&
    (var.talos_api_endpoint == "" || try(startswith(var.talos_api_endpoint, "127.0.0.1:"), false))
  )
  ccm_api_server = (
    local.ccm_ssm ? "https://127.0.0.1:${var.aws_ccm.operator_kube_port}" :
    var.talos_access_transport == "bootstrap_public" ? "https://${local.bootstrap_public_host}:6443" :
    var.talos_api_endpoint == null ? "https://${local.public_ip}:6443" :
    local.cluster_endpoint
  )
  ccm_tls_server_name = local.ccm_ssm ? coalesce(var.private_api_dns_name, local.api_host) : ""
  ccm_auth            = talos_cluster_kubeconfig.this.kubernetes_client_configuration
  # NOTE: Kubernetes 3.5 must load a server during planning, before AWS assigns a public endpoint.
  ccm_plan_kubeconfig = "${path.module}/scripts/ccm-plan-kubeconfig.yaml"
  ccm_kubectl_environment = {
    KUBECONFIG_RAW       = talos_cluster_kubeconfig.this.kubeconfig_raw
    KUBE_API_SERVER      = local.ccm_api_server
    KUBE_TLS_SERVER_NAME = local.ccm_tls_server_name
  }
  ccm_host_networking = var.aws_ccm.host_networking
}

provider "helm" {
  alias = "ccm"
  kubernetes = {
    host                   = local.ccm_api_server
    tls_server_name        = local.ccm_tls_server_name
    cluster_ca_certificate = base64decode(local.ccm_auth.ca_certificate)
    client_certificate     = base64decode(local.ccm_auth.client_certificate)
    client_key             = base64decode(local.ccm_auth.client_key)
    config_path            = local.ccm_plan_kubeconfig
    config_context         = "unavailable"
    insecure               = false
  }
}

provider "kubernetes" {
  alias                  = "ccm"
  host                   = local.ccm_api_server
  tls_server_name        = local.ccm_tls_server_name
  cluster_ca_certificate = base64decode(local.ccm_auth.ca_certificate)
  client_certificate     = base64decode(local.ccm_auth.client_certificate)
  client_key             = base64decode(local.ccm_auth.client_key)
  config_path            = local.ccm_plan_kubeconfig
  config_context         = "unavailable"
  insecure               = false
}

resource "terraform_data" "aws_ccm_api" {
  count = local.ccm_host_networking ? 1 : 0

  triggers_replace = [aws_instance.control_plane[local.bootstrap_index].id, local.ccm_api_server]

  provisioner "local-exec" {
    command     = "python3 '${path.module}/scripts/ccm_ready.py' api"
    environment = local.ccm_kubectl_environment
  }
}

module "aws_ccm_permissions" {
  source = "../kube_sa_auth_aws"

  providers = {
    kubernetes = kubernetes.ccm
  }

  service_account           = local.ccm_name
  service_account_namespace = local.ccm_namespace
  annotate_service_account  = false
  oidc_provider_arn         = aws_iam_openid_connect_provider.service_account_oidc[0].arn
  oidc_issuer_url           = local.service_account_oidc_issuer_url
  custom_oidc_enabled       = true
  cluster_name              = var.cluster_name
  iam_tags                  = var.aws_ccm.iam_tags
  ip_restrictions_enabled   = var.aws_ccm.ip_restrictions_enabled
  cluster_subnet_ids        = var.aws_ccm.cluster_subnet_ids
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
  provider = kubernetes.ccm

  metadata {
    name      = local.ccm_name
    namespace = local.ccm_namespace
  }
  # NOTE: Explicit topology lets CCM run without instance metadata credentials.
  data = {
    "cloud.conf" = join("\n", [
      "[Global]",
      "Region=${data.aws_region.current.region}",
      "Zone=${coalesce(var.aws_ccm.availability_zone, data.aws_subnet.control_plane[local.bootstrap_index].availability_zone)}",
      "VPC=${var.vpc_id}",
      "SubnetID=${coalesce(var.aws_ccm.subnet_id, data.aws_subnet.control_plane[local.bootstrap_index].id)}",
      "KubernetesClusterID=${var.cluster_name}",
      "",
    ])
  }
  lifecycle {
    precondition {
      condition     = local.ccm_host_networking ? terraform_data.aws_ccm_api[0].id != "" : true
      error_message = "The Kubernetes API must be ready before creating the CCM configuration."
    }
  }
}

resource "helm_release" "ccm" {
  provider = helm.ccm

  name       = local.ccm_name
  namespace  = local.ccm_namespace
  repository = "https://kubernetes.github.io/cloud-provider-aws"
  chart      = "aws-cloud-controller-manager"
  version    = "0.0.12"
  wait       = true
  atomic     = true
  timeout    = 300
  values = [
    yamlencode(merge({
      image              = { repository = "registry.k8s.io/provider-aws/cloud-controller-manager", tag = local.ccm_image_version }
      serviceAccountName = local.ccm_name
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
      env = concat([
        { name = "AWS_REGION", value = data.aws_region.current.region },
        { name = "AWS_DEFAULT_REGION", value = data.aws_region.current.region },
        { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
        { name = "AWS_STS_REGIONAL_ENDPOINTS", value = "regional" },
        { name = "AWS_ROLE_ARN", value = module.aws_ccm_permissions.role_arn },
        { name = "AWS_WEB_IDENTITY_TOKEN_FILE", value = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token" }
        ], local.ccm_host_networking ? [
        { name = "KUBERNETES_SERVICE_HOST", value = "127.0.0.1" },
        { name = "KUBERNETES_SERVICE_PORT", value = "7445" }
      ] : [])
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
      extraVolumes = [
        { name = "cloud-config", configMap = { name = local.ccm_name } },
        { name = "aws-web-identity", projected = { sources = [{ serviceAccountToken = { audience = "sts.amazonaws.com", expirationSeconds = 86400, path = "token" } }] } }
      ]
      extraVolumeMounts = [
        { name = "cloud-config", mountPath = "/etc/aws", readOnly = true },
        { name = "aws-web-identity", mountPath = "/var/run/secrets/eks.amazonaws.com/serviceaccount", readOnly = true }
      ]
      tolerations = concat([
        { key = "node.cloudprovider.kubernetes.io/uninitialized", value = "true", effect = "NoSchedule" },
        ], local.ccm_host_networking ? [
        { key = "node.kubernetes.io/not-ready", operator = "Exists", effect = "NoSchedule" },
        ] : [], [
        { key = "node-role.kubernetes.io/master", effect = "NoSchedule" },
        { key = "node-role.kubernetes.io/control-plane", effect = "NoSchedule" },
        { key = "controller", operator = "Equal", value = "true", effect = "NoSchedule" }
      ])
      },
      local.ccm_host_networking ? { hostNetworking = true, dnsPolicy = "Default" } : {},
      try(merge(yamldecode(var.aws_ccm.helm_values), {
        image = merge(yamldecode(var.aws_ccm.helm_values).image, { tag = local.ccm_image_version })
      }), yamldecode(var.aws_ccm.helm_values))
    )),
    yamlencode({ serviceAccount = { annotations = module.aws_ccm_permissions.service_account_annotations } }),
  ]
  depends_on = [kubernetes_config_map_v1.cloud, module.aws_ccm_permissions]
}

moved {
  from = module.aws_ccm[0].kubernetes_config_map_v1.cloud
  to   = kubernetes_config_map_v1.cloud
}

moved {
  from = module.aws_ccm[0].helm_release.ccm
  to   = helm_release.ccm
}

moved {
  from = module.aws_ccm[0].module.aws_permissions
  to   = module.aws_ccm_permissions
}

resource "terraform_data" "aws_ccm_ready" {
  count = local.ccm_host_networking ? 1 : 0

  triggers_replace = [aws_instance.control_plane[local.bootstrap_index].id, local.ccm_image_version]
  depends_on       = [helm_release.ccm, terraform_data.controller_provider_id]

  provisioner "local-exec" {
    command = "python3 '${path.module}/scripts/ccm_ready.py' node"
    environment = merge(local.ccm_kubectl_environment, {
      CONTROLLER_IP = local.bootstrap_node
      PROVIDER_ID = format("aws:///%s/%s",
        aws_instance.control_plane[local.bootstrap_index].availability_zone,
        aws_instance.control_plane[local.bootstrap_index].id
      )
    })
  }
}

output "aws_ccm_role_arn" {
  description = "IAM role ARN for the integrated AWS cloud controller manager."
  value       = module.aws_ccm_permissions.role_arn
}

output "aws_ccm_bootstrap_controller" {
  description = "Identity to check before deploying Cilium. Null when the host-network bootstrap check is disabled."
  value = local.ccm_host_networking ? {
    private_ip = local.bootstrap_node
    provider_id = format("aws:///%s/%s",
      aws_instance.control_plane[local.bootstrap_index].availability_zone,
      aws_instance.control_plane[local.bootstrap_index].id
    )
  } : null
}
