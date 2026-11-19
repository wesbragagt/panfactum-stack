# Talos on AWS

This module runs a Talos Linux Kubernetes cluster on EC2. Controllers and workers sit in private subnets with no public addresses. etcd is backed up to S3, and OIDC discovery for service-account tokens is published in a public S3 bucket. Operators reach the Kubernetes and Talos APIs through an AWS SSM port forward, so no API is exposed to the internet by default.

## Requirements

- A VPC with subnets tagged `Name = PRIVATE_A`, `PRIVATE_B` and `PRIVATE_C` that route `0.0.0.0/0` through NAT. Nodes pull images and join the cluster through that route.
- An EC2 host in the same VPC that is registered with SSM and shows `Online`, such as a NAT instance or bastion. Your AWS identity needs `ssm:StartSession` on it.
- S3 Block Public Access on the account must allow a public bucket policy, and the applying identity must be able to create an IAM OIDC provider.
- `python3`, `aws` CLI v2, `session-manager-plugin`, `terragrunt`, `kubectl`, `kubectx`, `talosctl` and `sops` on `PATH`. The Panfactum devshell provides all of them except `talosctl`.

In the commands below, `<module>` is the path to this module folder in your repository and `<caller>` is the Terragrunt directory that deploys it. Run them from the repository root.

## Bootstrap a new cluster

1. Create the secrets bundle. Add a SOPS creation rule for the file, then run:

   ```sh
   python3 <module>/scripts/gen_talos_secrets.py <caller>/talos-secrets.yaml
   ```

   Keep an encrypted copy outside the cluster. Never reuse another cluster's bundle.

2. Write `<caller>/terragrunt.hcl`:

   ```hcl
   terraform {
     source = "${get_repo_root()}/<module>"
   }

   dependency "vpc" {
     config_path = "../aws_vpc"
   }

   inputs = {
     cluster_name                      = "my-cluster"
     vpc_id                            = dependency.vpc.outputs.vpc_id
     secrets_bundle                    = yamldecode(sops_decrypt_file("${get_terragrunt_dir()}/talos-secrets.yaml"))
     private_api_dns_name              = "api.my-cluster.internal"
     operator_tunnel_security_group_id = "sg-0123456789abcdef0" # security group of the SSM host
   }
   ```

   `private_api_dns_name` creates a private hosted zone for its parent domain. Clusters in the same VPC need different parent domains, such as `api.a.internal` and `api.b.internal`.

3. Check your setup:

   ```sh
   python3 <module>/scripts/pf-bootstrap-talos preflight --cluster my-cluster --profile <aws-profile> --region <region>
   ```

   Fix every `FAIL` line before you continue. The SSM host is found by `Name = nat-*`. Pass `--tunnel-name-pattern` if yours is named differently.

4. In a second terminal, open the Talos forward and leave it running:

   ```sh
   python3 <module>/scripts/pf-bootstrap-talos forward --cluster my-cluster --profile <aws-profile> --region <region>
   ```

   It waits up to 15 minutes for `my-cluster-control-plane-0` to launch, then forwards `127.0.0.1:50000` to it.

5. In the first terminal, run `terragrunt apply` in `<caller>`. The module launches the controllers, bootstraps etcd and starts the workers. The Talos provider keeps retrying until the forward connects. Stop the forward with Ctrl-C once the apply finishes.

6. Register kubectl access:

   ```sh
   python3 <module>/scripts/pf-bootstrap-talos register --cluster my-cluster --module <caller> --region <region> --profile <aws-profile>
   ```

   This writes two files and merges the cluster into `.kube/config`:
   - `.kube/config.talos.yaml` holds the region, ports, module path and CA. It has no secrets. Commit it.
   - `.kube/config.talos.user.yaml` holds each operator's AWS profile per cluster. Keep it out of git.

7. Wire the repository once:
   - Add `!config.talos.yaml` to `.kube/.gitignore`.
   - Add these lines to `.envrc` after `use flake`, so every shell load merges the Talos contexts into `.kube/config`:

     ```sh
     watch_file .kube/config.talos.yaml .kube/config.talos.user.yaml
     python3 <module>/scripts/pf-bootstrap-talos merge || true
     ```

8. Check access:

   ```sh
   kubectx my-cluster
   kubectl get nodes
   ```

   The first call opens the tunnel, which takes about 30 seconds. Later calls reuse it.

9. Install Cilium and CoreDNS. This module disables Flannel, kube-proxy and the Talos CoreDNS but does not install replacements, so nodes stay `NotReady` until Cilium runs. Then deploy the remaining Panfactum modules in guide order.

10. Check etcd backups:

    ```sh
    kubectl -n etcd-backup create job --from=cronjob/etcd-backup test-1
    ```

    Confirm that a new `<cluster>-<timestamp>.snap` object appears under `etcd/<cluster>/` in the bucket from the `etcd_backup_bucket` output.

## Everyday access

- `kubectl`, `kubectx` and `k9s` work after the shell loads. The context's credential command opens or reuses a background tunnel per cluster, with its state in `~/.local/state/talos-cluster-access/<cluster>`.
- `terragrunt plan` and `apply` need the tunnel. Add a `before_hook` to the caller that opens it, and an `after_hook` that keeps the context current:

  ```hcl
  terraform {
    before_hook "talos_tunnel" {
      commands = ["plan", "apply"]
      execute  = ["python3", "${get_repo_root()}/<module>/scripts/cluster_access.py", "--ensure",
                  "--cluster", "my-cluster", "--profile", "<aws-profile>", "--region", "<region>",
                  "--module", get_terragrunt_dir()]
    }
    after_hook "talos_register" {
      commands     = ["apply"]
      execute      = ["python3", "${get_repo_root()}/<module>/scripts/pf-bootstrap-talos", "register",
                      "--cluster", "my-cluster", "--module", get_terragrunt_dir(),
                      "--region", "<region>", "--profile", "<aws-profile>"]
      run_on_error = false
    }
  }
  ```

  Add the `before_hook` only after the first apply, because it reads the cluster's outputs.
- For `talosctl`, run `python3 <module>/scripts/cluster_access.py --cluster my-cluster --profile <aws-profile> --region <region> --module <caller>`. It holds the tunnel in the foreground and prints an `export TALOSCONFIG=...` line.
- A new operator clones the repository, adds their profile to `.kube/config.talos.user.yaml`, and reloads the shell.
- Every AWS profile that can open the tunnel and read the Terraform state gets cluster-admin, because the credential is the admin client certificate. Restrict both with IAM.

## More than one cluster

Each cluster needs its own local ports. Pass `--kube-port` and `--talos-port` to `register`, pass the same `--talos-port` to `forward` and `cluster_access.py`, and set `talos_api_endpoint = "127.0.0.1:<talos-port>"` in the caller.

## Recovery

Never run a full apply to recover a cluster without checking `talos_machine_bootstrap.this` first. If it is missing from state and the replacement controller has no etcd data, the apply creates an empty etcd. Exclude that resource, restore the snapshot with `talosctl bootstrap --recover-from`, then reconcile.

If the first apply cannot reach Talos, target what the first call needs, then run a full plan and apply: `aws_instance.control_plane`, `aws_security_group.nodes`, `aws_vpc_security_group_ingress_rule.operator_tunnel`, `aws_vpc_security_group_ingress_rule.self`, `aws_vpc_security_group_egress_rule.nodes_all` and `aws_route53_record.private_api`.

## Configuration notes

- Networking: `cilium_enabled = true` (default) disables Flannel and kube-proxy. Set `cilium_enabled = false` and `core_dns_enabled = true` only to use the Talos-managed networking and DNS.
- AWS integration: `aws_node_config_enabled = true` sets kubelet `cloud-provider=external` and applies `pod_subnets` and `service_subnets`. It requires the AWS cloud controller manager and a worker identity through `worker_instance_profile_arn`. Use it for Cilium ENI IPAM.
- Images: pass `ami_id` and the matching `installer_image` for a custom Talos factory image.
- OIDC: the module creates the `<cluster_name>-oidc-<account_id>` bucket and configures the API server issuer. Planning needs Python 3 and OpenSSL. Rotating the service-account signing key needs a separate procedure that keeps old keys until their tokens expire.
- Public controllers: set `control_plane_public_ip_enabled = true`, choose PUBLIC subnets, and set `talos_api_allowed_cidrs` and `kube_api_allowed_cidrs`. Set `talos_api_endpoint = null` to reach Talos through the Elastic IP.
- Secrets: older callers can keep passing `machine_secrets` and `client_configuration`. New callers pass `secrets_bundle`. Secrets still end up in Terraform state and EC2 user data, so restrict access to both.
