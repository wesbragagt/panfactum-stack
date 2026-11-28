# Talos IAM login

Operators sign in to the Kubernetes API with an IAM Identity Center role. `aws_kube_talos` maps the roles to Panfactum groups the way `aws_eks` does, and `kube_policies` gives each group its permissions.

| Part | Owner | What it provides |
|---|---|---|
| API server authentication | `aws_kube_talos` | Role discovery, the issuer lookup and the `KubeAuthenticationConfig` patch. It adds no inputs and is always on. |
| RBAC | `kube_policies` | The `pf:admins`, `pf:readers` and `pf:restricted-readers` ClusterRoles and bindings, and a `pf:superusers` binding to `cluster-admin`. |
| Operator metadata | `iam_login` output of `aws_kube_talos` | The public issuer, audience, region and role ARNs that `scripts/iam_login.py` reads. |

## What Terraform renders

`aws_kube_talos` finds the roles named `AWSReservedSSO_Superuser`, `AWSReservedSSO_Admin`, `AWSReservedSSO_Reader` and `AWSReservedSSO_RestrictedReader` under `/aws-reserved/sso.amazonaws.com/`, using the same regexes as `aws_eks`. It reads the account issuer from outbound identity federation and sets the audience to the cluster name. It renders one `KubeAuthenticationConfig` document into `control_plane_patches`, so both the EC2 user data and the runtime machine configuration carry it.

Kubernetes verifies the token signature and expiration against AWS discovery and JWKS. The patch then requires the token `sub` claim to equal the STS `principal_id` claim and to be one of the discovered role ARNs or the account root ARN. The Kubernetes username is `aws:` followed by the role ARN, so it identifies the role and not the individual Identity Center user. The groups expression maps every discovered ARN to its group. A role that is not discovered, such as BillingAdmin, has no mapping and Kubernetes rejects its token. Anonymous access stays limited to `/livez`, `/readyz` and `/healthz`.

A role ARN that matches two of the four regexes fails the plan with a duplicate key instead of receiving one of the groups.

## Roles

| Role | Kubernetes group | Permissions |
|---|---|---|
| Superuser | `pf:superusers` | Full cluster admin through the built-in `cluster-admin` ClusterRole, the same access EKS gives through AmazonEKSClusterAdminPolicy. |
| Account root user with static keys | `pf:superusers` | Full cluster admin through `cluster-admin`, as on EKS. The root ARN is not in the `iam_login` output. |
| Admin | `pf:admins` | Read and write the Panfactum resource inventory, including Secrets, `pods/exec` and `pods/attach`. Read-only access to RBAC, admission, API service, flow control, CRD and Kyverno cluster policy resources. |
| Reader | `pf:readers` | Get, list and watch the Panfactum resource inventory, including Secrets, plus pod logs and metrics. |
| RestrictedReader | `pf:restricted-readers` | The same reads as Reader, except Secrets allow list only. Kubernetes returns full Secret values on list requests, so this role can still read Secret contents. |
| BillingAdmin | No mapping | Kubernetes rejects the token. |

## Enable on a cluster

1. Enable outbound identity federation in the AWS account, and assign the four permission sets in it. The module reads roles at plan time, so a role created or recreated later needs another apply. The planning identity needs `iam:GetOutboundWebIdentityFederationInfo`.
2. Plan `aws_kube_talos` in a new tmux window, then apply it. For four roles the patch adds about 1.5 KB to the user data, and each further role ARN adds about 230 bytes. The rendered EC2 user data must stay within 16,384 bytes. Talos updates the machine configuration in place, so wait for `/readyz` after the API server reload.
3. Apply `kube_policies` with the Talos admin kubeconfig. Until it applies, tokens authenticate but no group has permissions.
4. Export the operator metadata from the module directory. It holds only public values.

   ```sh
   tofu output -json iam_login > operator.json
   ```

   A role with no matching IAM role is `null` in the file, and `iam_login.py` rejects it. If several IAM roles match one role set, the output holds the first ARN in sort order.
5. Export `cluster_ca_data` and distribute it with `operator.json`. Keep the state and the admin kubeconfig restricted to recovery operators. Protect access to the controller's EC2 user data because it contains the machine PKI.

After an Identity Center role is recreated with a new ARN, apply `aws_kube_talos` again and export `operator.json` again.

A cluster that used the earlier manual flow must remove its hand-written `KubeAuthenticationConfig` from `control_plane_config_patches` before this apply. It should also delete the ClusterRoles and bindings that the removed `rbac` command created.

## Operator login

Use the cluster's fixed SSM configuration and the Reader profile. Generate
the standard operator kubeconfig first, then pass it as the credential
source. The shared helper opens only the Kubernetes document.

```sh
scripts="$PWD/forks/panfactum/packages/infrastructure/aws_kube_talos/scripts"
operator_profile=homelab-reader
export PF_TALOS_FIXED_SSM="$fixed_config"
python3 "$scripts/iam_login.py" kubeconfig --config "$operator_metadata" \
  --profile "$operator_profile" --aws-cli "$aws_cli" --server https://127.0.0.1:26443 \
  --ca-data "$cluster_ca_data" > "$operator_kubeconfig"
kubeconfig=$(python3 "$scripts/cluster_access.py" --ensure \
  --cluster "$cluster_name" --profile "$operator_profile" --region us-east-2 \
  --source-kubeconfig "$operator_kubeconfig" --kube-port 26443)
kubectl --kubeconfig "$kubeconfig" auth whoami
```

Use an AWS CLI that supports STS `get-web-identity-token`. The kubeconfig
helper checks the issuer, audience and caller before returning the
five-minute credential. The caller must be an approved Identity Center role
or the account root user.

## Bootstrap and recovery

IAM login cannot bootstrap itself. Until `kube_policies` is applied, and whenever IAM login is unavailable, use the Talos admin certificate. This covers the first `kube_policies` apply, an AWS outage, and a role recreated before the module applies its new ARN.

Use the same fixed configuration with a Superuser profile and the
protected Talos credential source. To recover through the NAT, pass
`--nat-host "$nat_id"` and list that instance in the JSON file's
`nat_host_ids`. The helper selects only the requested controller document.
Recovery access still requires AWS permissions for both the destination
document and the chosen host.

```sh
talosconfig=$(python3 "$scripts/cluster_access.py" --talos-config \
  --cluster "$cluster_name" --profile "$superuser_profile" --region us-east-2 \
  --source-talosconfig "$admin_talosconfig" --node "$controller_ip" --nat-host "$nat_id" --talos-port 55000)
talosctl --talosconfig "$talosconfig" kubeconfig --merge=false "$admin_kubeconfig"
```
