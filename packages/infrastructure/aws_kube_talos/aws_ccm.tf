variable "aws_ccm" {
  description = "Own the AWS cloud controller manager. Set host_networking to false while adopting an existing pod-network release."
  type = object({
    image_version           = string
    host_networking         = optional(bool, true)
    subnet_id               = optional(string)
    availability_zone       = optional(string)
    ip_restrictions_enabled = optional(bool, false)
    cluster_subnet_ids      = optional(set(string))
    iam_tags                = optional(map(string))
    helm_values             = optional(string, "{}")
    operator_kube_port      = optional(number, 16443)
  })
  default = null

  validation {
    condition = var.aws_ccm == null ? true : (
      can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.aws_ccm.image_version)) &&
      var.aws_ccm.operator_kube_port >= 1 && var.aws_ccm.operator_kube_port <= 65535 &&
      floor(var.aws_ccm.operator_kube_port) == var.aws_ccm.operator_kube_port
    )
    error_message = "Pin a CCM image in vMAJOR.MINOR.PATCH form and supply a valid local SSM Kubernetes port."
  }

  validation {
    condition = var.aws_ccm == null ? true : (
      var.aws_node_config_enabled &&
      try(slice(split(".", trimprefix(var.aws_ccm.image_version, "v")), 0, 2) == slice(split(".", trimprefix(var.kube_version, "v")), 0, 2), false)
    )
    error_message = "AWS CCM requires aws_node_config_enabled and an image matching the Kubernetes major and minor."
  }
}

locals {
  ccm_ssm = var.talos_access_transport == "ssm" || (
    var.talos_access_transport == "" &&
    (var.talos_api_endpoint == "" || try(startswith(var.talos_api_endpoint, "127.0.0.1:"), false))
  )
  ccm_api_server = (
    local.ccm_ssm ? "https://127.0.0.1:${try(var.aws_ccm.operator_kube_port, 16443)}" :
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
  ccm_host_networking = try(var.aws_ccm.host_networking, false)
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

module "aws_ccm" {
  source = "../kube_aws_ccm"
  count  = var.aws_ccm == null ? 0 : 1

  providers = {
    helm       = helm.ccm
    kubernetes = kubernetes.ccm
  }
  cluster_name            = var.cluster_name
  region                  = data.aws_region.current.region
  vpc_id                  = var.vpc_id
  subnet_id               = coalesce(var.aws_ccm.subnet_id, data.aws_subnet.control_plane[local.bootstrap_index].id)
  availability_zone       = coalesce(var.aws_ccm.availability_zone, data.aws_subnet.control_plane[local.bootstrap_index].availability_zone)
  image_version           = var.aws_ccm.image_version
  talos_bootstrap_enabled = true
  talos_host_networking   = local.ccm_host_networking
  custom_oidc_enabled     = true
  oidc_issuer_url         = local.service_account_oidc_issuer_url
  oidc_provider_arn       = aws_iam_openid_connect_provider.service_account_oidc[0].arn
  ip_restrictions_enabled = var.aws_ccm.ip_restrictions_enabled
  cluster_subnet_ids      = var.aws_ccm.cluster_subnet_ids
  iam_tags                = var.aws_ccm.iam_tags
  helm_values             = var.aws_ccm.helm_values
  api_ready               = local.ccm_host_networking ? terraform_data.aws_ccm_api[0].id != "" : true
}

resource "terraform_data" "aws_ccm_ready" {
  count = local.ccm_host_networking ? 1 : 0

  triggers_replace = [aws_instance.control_plane[local.bootstrap_index].id, var.aws_ccm.image_version]
  depends_on       = [module.aws_ccm, terraform_data.controller_provider_id]

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
  description = "Integrated CCM IAM role ARN. Null if the module does not own CCM."
  value       = one(module.aws_ccm[*].role_arn)
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
