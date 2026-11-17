# Talos on AWS

Terragrunt consumers supply cluster choices and decrypt their SOPS bundle. The module owns Talos configuration documents, EC2 launch templates, Spot and on-demand worker configuration, and OIDC discovery.

```hcl
terraform {
  source = "${get_repo_root()}/forks/panfactum/packages/infrastructure//aws_kube_talos"
}

inputs = {
  cluster_name = "my-cluster"
  vpc_id       = dependency.vpc.outputs.vpc_id
  secrets_bundle = yamldecode(sops_decrypt_file("${get_terragrunt_dir()}/talos-secrets.yaml"))
  control_plane_private_ips = ["10.0.128.20"]
  operator_tunnel_security_group_id = "sg-0123456789abcdef0" # fck-nat SSM tunnel hosts
}
```

Talos-managed Flannel, kube-proxy and CoreDNS are disabled by default so Panfactum modules can manage networking and DNS. `cilium_enabled = true` disables Flannel and kube-proxy; it does not install Cilium. Set `cilium_enabled = false` and `core_dns_enabled = true` only when using Talos-managed networking and DNS.

For custom factory images, pass `ami_id` and the matching `installer_image`. Enable `aws_node_config_enabled` for primary-interface DHCP, ECR credential-provider configuration, external CCM settings and worker lifecycle labels. Supply `pod_subnets` and `service_subnets` when the defaults overlap another cluster. `worker_instance_profile_arn` grants workers their AWS identity.

The module creates `<cluster_name>-oidc-<aws_account_id>`, publishes discovery and public JWKS derived from the existing service-account signing key, and configures the API server issuer and JWKS URL. Consumers supply no OIDC inputs. Planning requires Python 3 and OpenSSL. Signing-key rotation requires a separate overlap procedure retaining old verification keys until their tokens expire.

The Talos API and Kubernetes API certificates include the SAN `127.0.0.1`, so clients can verify TLS through an SSM port forward. `operator_tunnel_security_group_id` opens 6443 and 50000 to the tunnel hosts. The default `talos_api_endpoint = "127.0.0.1"` runs Talos provider operations through a tunnel forwarding 127.0.0.1:50000 to the controller; plans and applies fail unless the tunnel is up. `talos_api_allowed_cidrs` and `kube_api_allowed_cidrs` default to `[]`; set them only for direct access from fixed IPs. Controllers default to PRIVATE_A/B/C subnets without public addresses or an Elastic IP. Supply `private_api_dns_name` or `control_plane_private_ips` for the cluster endpoint. Existing public-controller callers must set `control_plane_public_ip_enabled = true` and select PUBLIC subnets; set `talos_api_endpoint = null` only for direct Talos access through the Elastic IP.

To bootstrap a new cluster with both CIDR lists empty, give the controllers fixed addresses with `control_plane_private_ips` and set `operator_tunnel_security_group_id` to an SSM-registered host in the VPC. Start port forwards through that host to `<ip>:50000` and `<ip>:6443` before `terragrunt apply`, and set `talos_api_endpoint = "127.0.0.1"`. The control plane user data carries the `127.0.0.1` SANs, so the first Talos call validates without `--insecure`.

Existing callers can continue supplying provider-shaped `machine_secrets` and `client_configuration`. New callers should pass `secrets_bundle`. Keep the bundle outside the cluster for recovery. Sensitive credentials still enter Terraform state and EC2 user data.

