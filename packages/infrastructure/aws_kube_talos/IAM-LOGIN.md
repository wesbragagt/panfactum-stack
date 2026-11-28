# Talos IAM login

Operators sign in to the Kubernetes API with an IAM Identity Center role. `aws_kube_talos` maps the roles to Panfactum groups the way `aws_eks` does, and `kube_policies` gives each group its permissions.

| Part | Owner | What it provides |
|---|---|---|
| API server authentication | `aws_kube_talos` | Role discovery, the issuer lookup and the `KubeAuthenticationConfig` patch. Its one optional input is `extra_principal_arns`. It is always on. |
| RBAC | `kube_policies` | The `pf:admins`, `pf:readers` and `pf:restricted-readers` ClusterRoles and bindings, and a `pf:superusers` binding to `cluster-admin`. |
| Operator metadata | `iam_login` output of `aws_kube_talos` | The public issuer, audience, region, role ARNs and principal ARNs that `scripts/iam_login.py` reads. |

## What Terraform renders

`aws_kube_talos` finds the roles named `AWSReservedSSO_Superuser`, `AWSReservedSSO_Admin`, `AWSReservedSSO_Reader` and `AWSReservedSSO_RestrictedReader` under `/aws-reserved/sso.amazonaws.com/`, using the same regexes as `aws_eks`. It reads the account issuer from outbound identity federation and sets the audience to the cluster name. It renders one `KubeAuthenticationConfig` document into `control_plane_patches`, so both the EC2 user data and the runtime machine configuration carry it.

Kubernetes verifies the token signature and expiration against AWS discovery and JWKS. The patch then requires the token `sub` claim to equal the STS `principal_id` claim and to be one of the discovered role ARNs, the account root ARN or an `extra_principal_arns` ARN. The Kubernetes username is `aws:` followed by that ARN, so for a role it identifies the role and not the individual Identity Center user. The groups expression maps every one of these ARNs to its group. A role that is not discovered, such as BillingAdmin, has no mapping and Kubernetes rejects its token. Anonymous access stays limited to `/livez`, `/readyz` and `/healthz`.

A role ARN that matches two of the four regexes fails the plan with a duplicate key instead of receiving one of the groups. The same happens when the root ARN or a discovered role ARN is also listed in `extra_principal_arns`. An extra ARN listed in two groups fails validation.

## Roles

| Role | Kubernetes group | Permissions |
|---|---|---|
| Superuser | `pf:superusers` | Full cluster admin through the built-in `cluster-admin` ClusterRole, the same access EKS gives through AmazonEKSClusterAdminPolicy. |
| Account root user with static keys | `pf:superusers` | Full cluster admin through `cluster-admin`, as on EKS. The root ARN is listed in `principal_arns` in the `iam_login` output. |
| Admin | `pf:admins` | Read and write the Panfactum resource inventory, including Secrets, `pods/exec` and `pods/attach`. Read-only access to RBAC, admission, API service, flow control, CRD and Kyverno cluster policy resources. |
| Reader | `pf:readers` | Get, list and watch the Panfactum resource inventory, including Secrets, plus pod logs and metrics. |
| RestrictedReader | `pf:restricted-readers` | The same reads as Reader, except Secrets allow list only. Kubernetes returns full Secret values on list requests, so this role can still read Secret contents. |
| BillingAdmin | No mapping | Kubernetes rejects the token. |

## Extra IAM principals

`extra_principal_arns` grants a group to IAM users or roles outside Identity Center. It takes the same four groups as `aws_eks`, each a list of ARNs: `superusers`, `admins`, `readers` and `restricted_readers`.

```hcl
extra_principal_arns = {
  readers = ["arn:aws:iam::<account_id>:user/operator-reader"]
}
```

Each IAM user needs an identity policy that allows `sts:GetWebIdentityToken` for the cluster audience. Without it, `iam_login.py` cannot request a token for the user. AWS sets the token `sub` claim to the requesting user ARN by default, which is the value the patch requires. This policy limits the token to the cluster audience, the 300-second lifetime and the RS256 algorithm that `iam_login.py` requests.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:GetWebIdentityToken",
      "Resource": "*",
      "Condition": {
        "ForAllValues:StringEquals": { "sts:IdentityTokenAudience": ["<cluster_name>"] },
        "Null": { "sts:IdentityTokenAudience": "false" },
        "NumericLessThanEquals": { "sts:DurationSeconds": 300 },
        "StringEquals": { "sts:SigningAlgorithm": "RS256" }
      }
    }
  ]
}
```

The `Null` condition is required because `ForAllValues:StringEquals` is also true when the key is absent. The AWS reference is [Controlling access with IAM policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_policies.html).

## Enable on a cluster

1. Enable outbound identity federation in the AWS account, and assign the four permission sets in it. The module reads roles at plan time, so a role created or recreated later needs another apply. The planning identity needs `iam:GetOutboundWebIdentityFederationInfo`.
2. Plan `aws_kube_talos` in a new tmux window, then apply it. For four roles the patch adds about 1.5 KB to the user data, and each further role ARN adds about 230 bytes. The rendered EC2 user data must stay within 16,384 bytes. Talos updates the machine configuration in place, so wait for `/readyz` after the API server reload.
3. Apply `kube_policies` with the Talos admin kubeconfig. Until it applies, tokens authenticate but no group has permissions.
4. Export the operator metadata from the module directory. It holds only public values.

   ```sh
   tofu output -json iam_login > operator.json
   ```

   A role with no matching IAM role is `null` in the file, and `iam_login.py` rejects it. If several IAM roles match one role set, the output holds the first ARN in sort order. `principal_arns` holds the account root ARN and every `extra_principal_arns` ARN, sorted.
5. Export `cluster_ca_data` and distribute it with `operator.json`. Keep the state and the admin kubeconfig restricted to recovery operators. Protect access to the controller's EC2 user data because it contains the machine PKI.

After an Identity Center role is recreated with a new ARN, apply `aws_kube_talos` again and export `operator.json` again.

A cluster that used the earlier manual flow must remove its hand-written `KubeAuthenticationConfig` from `control_plane_config_patches` before this apply. It should also delete the ClusterRoles and bindings that the removed `rbac` command created.

## Operator login

Use an AWS CLI that supports STS `get-web-identity-token` (2.33 or later). The kubeconfig helper checks the issuer, audience and caller before returning the five-minute credential. The caller must be an approved Identity Center role or an ARN listed in `principal_arns`. An extra IAM role caller matches the role name in the same account.

### Through the VPN

The API server is reachable directly, so the kubeconfig uses the cluster URL. `--server` takes any HTTPS URL with a hostname, and the port may be omitted. It rejects credentials, paths other than `/`, queries and fragments. The CA data still pins the server.

```sh
scripts="$PWD/forks/panfactum/packages/infrastructure/aws_kube_talos/scripts"
python3 "$scripts/iam_login.py" kubeconfig --config "$operator_metadata" \
  --profile "$operator_profile" --aws-cli "$aws_cli" --server "$cluster_url" \
  --ca-data "$cluster_ca_data" > "$operator_kubeconfig"
kubectl --kubeconfig "$operator_kubeconfig" auth whoami
```

### Generated context

`pf-update-kube-talos` can add this login to the project kubeconfig as a `<cluster>-iam` context. Set `iam_profile` on the cluster's entry in the gitignored `.kube/config.talos.user.yaml`. The value is the AWS profile of the Identity Center role, IAM user or root user to sign in as. It is separate from `aws_profile`, which the Talos admin certificate context keeps using.

```yaml
clusters:
  - name: homelab-talos-2
    aws_profile: homelab-superuser
    iam_profile: homelab-k8s-test-superuser
```

```sh
pf-update-kube-talos --build
kubectl --context homelab-talos-2-iam auth whoami
```

`build` copies the module's `iam_login` output into the cluster's entry in `.kube/cluster_info.talos`. `merge` writes that metadata to `.kube/<cluster>.iam.json`, only when its contents change, and adds a context whose cluster is the module's `kube_api_server` and `ca_data`. The context user runs `iam_login.py credential` with `--profile <iam_profile>` and `--aws-cli aws`, so it needs no Talos certificate. The `<cluster>` context is not changed.

Only the `vpn` transport is supported. For `bootstrap_public`, `merge` prints a message and skips the `-iam` context. It also skips the context, with a message, when `cluster_info.talos` has no `iam_login` entry for the cluster. Run `pf-update-kube-talos --build` after the module applies with the output.

For a `vpn` cluster, `iam_profile` also switches the Terragrunt Kubernetes, kubectl and Helm providers to the `<cluster>-iam` context. `cluster-access.py --direct-provider-config` checks that context and returns it, and it fails with a message to run `pf-bootstrap-talos merge` when the context is missing or stale. Remove the `iam_profile` line to switch the providers back to the `<cluster>` context, which uses the Talos admin certificate.

## Bootstrap and recovery

IAM login cannot bootstrap itself. Until `kube_policies` is applied, and whenever IAM login is unavailable, use the Talos admin certificate. This covers the first `kube_policies` apply, an AWS outage, and a role recreated before the module applies its new ARN.

Use a Superuser profile and the protected Talos credential source over the
VPN. Pass the controller's private IP as the Talos endpoint.

```sh
talosconfig=$(python3 "$scripts/cluster_access.py" --talos-config \
  --cluster "$cluster_name" --profile "$superuser_profile" --region us-east-2 \
  --source-talosconfig "$admin_talosconfig" --talos-endpoint "$controller_ip")
talosctl --talosconfig "$talosconfig" kubeconfig --merge=false "$admin_kubeconfig"
```
