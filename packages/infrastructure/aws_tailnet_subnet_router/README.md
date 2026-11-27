# Tailscale or Headscale subnet router on AWS

The homelab caller runs one `t4g.nano` in PUBLIC_A in us-east-2a. It advertises PRIVATE_A, PRIVATE_B and PRIVATE_C and the VPC resolver. The Talos-2 Kubernetes API uses an internal NLB in us-east-2b. The live Talos controller is also in us-east-2b. The router can forward to other VPC AZs, but its instance and AZ are single points of failure for VPN access. The separate SSM jump host provides recovery.

The router uses hosted Tailscale, default source NAT, an encrypted 8 GiB root volume, IMDSv2 and SSM. The current caller selects `tag:subnet-router`. The module also supports two routers when `ha_enabled` is set, but this caller uses `ha_enabled = false`.

## Provision Headscale

Set `backend = "headscale"` and the caller's `headscale` input to provision the server outside Talos. Set `backend = "tailscale"` for hosted Tailscale.

```hcl
headscale = {
  hostname  = "headscale.homelab.wesbragagt.com"
  zone_id   = "Z0123456789"
}
```

Use the existing public hosted zone and a public first subnet with an Internet Gateway route. The module allocates the server's Elastic IP, creates its Route 53 A record, and obtains a Let's Encrypt certificate over TCP 443. It stores the database, server identity and ACME cache on a separate encrypted EBS volume. Retain the volume when replacing the server within its AZ. Snapshot it before destroying the deployment or moving it to another AZ. [Headscale TLS documentation](https://headscale.net/0.28.0/ref/tls/)

The Headscale server uses a dedicated t4g.micro instance. Set `ha_enabled = true` and provide subnets in two distinct AZs to run two subnet routers. Headscale 0.28.0 may take up to 16 minutes to detect an offline router. The single Headscale server and its EBS volume remain in one AZ. Restoring service after an AZ outage requires recovery in another AZ from an EBS snapshot. [Headscale route failover](https://headscale.net/0.28.0/ref/routes/)

The server configures split DNS and automatically approves the advertised routes for `tag:subnet-router`. An enrolled user can reach the advertised CIDRs. Use private API authentication as usual. The Headscale service publishes a short-lived tagged key to `/<name>/headscale-router-enrollment` in SSM and renews it daily. The module keeps the key out of OpenTofu state and instance user data. After destroying a managed deployment, the operator can delete this runtime-created parameter once its routers are gone.

Open an SSM session to `managed_headscale.instance_id` for administration. Run `sudo /usr/local/bin/headscale --config /etc/headscale/config.json nodes list-routes` to check advertised and approved routes. Create a Headscale user and a separate single-use key for an operator's workstation. Connect with the `managed_headscale.login_server` URL and verify the private DNS and APIs. [Headscale client registration](https://headscale.net/0.28.0/usage/getting-started/)

For the homelab Headscale server, the project's Linux client uses a separate
network namespace and preserves the host's existing Tailscale profile. See
[Use the Tailnet include after registration](../../../../../docs/talos-new-cluster-bootstrap.md#use-the-tailnet-include-after-registration)
for enrollment, the Terragrunt include, and the first-apply boundary.

## Hosted Tailscale prerequisites

- Use an already enrolled Tailscale client on the intended tailnet. Confirm the hosted plan permits the required subnet routing and policy features. Subscription cost was not verified.
- The SOPS-encrypted caller secret has an OAuth client with `auth_keys` and `dns` write scopes and the router tag selected. The router exchanges it for an ephemeral, preauthorized key on first boot. The applying Tailscale provider also uses this credential for split DNS.
- Use the `homelab-superuser` AWS profile with access to the Terraform backend, VPC, router, Talos caller and SSM. Verify the credential independently before an outage. The profile used during qualification authenticated with an IAM access key.
- The caller uses the shared VPC and PUBLIC_A. It advertises `10.0.64.0/18`, `10.0.128.0/18`, `10.0.192.0/18` and resolver `10.0.0.2/32`. Check these against live VPC outputs when rebuilding. Pod and service CIDRs are not advertised.
- Tailscale controls network access. Kubernetes and Talos still require their existing CA and client certificates. Cold credential retrieval needs AWS identity and protected state access. State and saved plans contain the OAuth secret and must be protected.

The vendored router module pins the Tailscale provider to `0.30.0`, AWS provider to `6.73.0` and PF provider to `0.0.7`. The AL2023 arm64 boot package is `tailscale-1.104.7-1`. Talos-2 uses Talos provider `0.12.0`. See [Panfactum version policy](../../../../../docs/panfactum-version-policy.md).

Reuse the existing encrypted credential. If it needs to be created, use [Tailscale Trust credentials](https://login.tailscale.com/admin/settings/trust-credentials) to create an OAuth client with Auth Keys write for `tag:subnet-router` and DNS write. Store the client ID and secret in the `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` fields using `direnv exec . sops environments/homelab/us-east-2/aws_tailnet_subnet_router/secrets.yaml`.

## Policy and DNS

Inspect the existing [Access controls](https://login.tailscale.com/admin/acls) policy before changing it. Confirm `tagOwners` allows the OAuth client to assign `tag:subnet-router`, and `autoApprovers.routes` approves each of the four advertised routes for that tag. Route approval distributes a route. Access grants separately determine who can use it. For Talos-2, the intended operator needs TCP 6443 to the private Kubernetes NLB, TCP 50000 to the controller, and TCP and UDP 53 to the resolver. Review existing grants as well as additions. Save the exact additions so they can be removed individually.

Inspect [Tailscale DNS](https://login.tailscale.com/admin/dns) before applying. The caller owns only the `homelab-talos-2.internal` split DNS suffix and points it at `10.0.0.2`. Resolve a pre-existing owner or conflicting resolver before applying. The router OAuth client can read split DNS, but its `auth_keys` and `dns` scopes do not permit policy or device reads. The operator reviewed the active policy during the 2026-11-24 deployment. A separate test principal with confirmed lack of permission is still needed to verify network denial. An isolated `tag:subnet-router` device reached both API ports. Unauthenticated requests were rejected by Kubernetes and Talos.

## Prepare the existing client

Run these commands from the repository root in the dev environment. Record the tailnet, device identity, selected exit node and the route and DNS preferences before changing them. Compare the route table with the four advertised ranges and resolve overlaps first. Keep the enrolled account and other client settings.

```sh
direnv exec . tailscale status --json | jq '{BackendState, CurrentTailnet, Self: {ID: .Self.ID, Online: .Self.Online}}'
direnv exec . tailscale debug prefs | jq '{RouteAll, CorpDNS, ExitNodeID, ExitNodeIP, ExitNodeAllowLANAccess, AdvertiseRoutes}'
ip -4 route show table all
direnv exec . aws sts get-caller-identity --profile homelab-superuser
```

On Linux, enable route acceptance if the captured preference was false. This changes only that preference. DNS acceptance must remain enabled for split DNS.

```sh
sudo tailscale set --accept-routes=true
ip route get 10.0.128.10
getent ahostsv4 api.homelab-talos-2.internal
```

The route should use `tailscale0`. The private name should resolve to the internal NLB. Compare its addresses with AWS rather than relying on an old address. Tailscale's [subnet-router documentation](https://tailscale.com/docs/features/subnet-routers) covers approval and client route acceptance.

## Generate access contexts

For either backend, an enrolled client with accepted subnet routes and DNS connects directly to the private Kubernetes and Talos endpoints. The client needs cluster credentials. The SSM jump host is for explicit recovery. Headscale server administration and router bootstrap use SSM separately from the client network path.

The committed `.kube/config.talos.yaml` contains shared cluster metadata, including the private URL and controller endpoints. The gitignored `.kube/config.talos.user.yaml` holds the operator profile and transport. Set the existing `homelab-talos-2` entry to `transport: vpn`, using `.kube/config.talos.user.example.yaml` as the shape. Omitted transport or `ssm` selects SSM and requires `PF_TALOS_FIXED_SSM`.

Register after the Talos caller has outputs, then merge. The commands use the repository's primary checkout for the shared generated config.

```sh
direnv exec . python3 forks/panfactum/packages/infrastructure/aws_kube_talos/scripts/pf-bootstrap-talos register --cluster homelab-talos-2 --module environments/homelab/us-east-2/aws_kube_talos --region us-east-2 --profile homelab-superuser --vpn-endpoints
direnv exec . python3 forks/panfactum/packages/infrastructure/aws_kube_talos/scripts/pf-bootstrap-talos merge
direnv exec . scripts/cluster-access.py --cluster homelab-talos-2 --show-transport
```

In VPN mode `homelab-talos-2` uses `https://api.homelab-talos-2.internal:6443`. `homelab-talos-2-ssm` is an explicit recovery context for the same source cluster and uses `https://127.0.0.1:16443`. Both use the same cluster CA and protected certificate source. The generator preserves the selected current context. `.envrc` exports the primary checkout's `.kube/config` as both `KUBECONFIG` and `KUBE_CONFIG_PATH`. Merge overwrites generated entries, so change the metadata or local preferences instead of editing generated entries.

For the project Headscale client, prefix the routed commands below with
`direnv exec . tailnet exec` instead of `direnv exec .`. The Tailnet include
selects this namespace for OpenTofu in opted-in callers. No existing caller
selects it until the include is added. For SSM recovery, use the host commands
below with the fixed configuration.

```sh
direnv exec . kubectl --context homelab-talos-2 get --raw=/readyz
direnv exec . kubectl --context homelab-talos-2 auth whoami
direnv exec . talosctl --context homelab-talos-2 version
direnv exec . talosctl --context homelab-talos-2 service etcd
```

Use the following commands for SSM recovery.

```sh
export PF_TALOS_FIXED_SSM="$talos_2_fixed_config"
direnv exec . kubectl --context homelab-talos-2-ssm get --raw=/readyz
direnv exec . talosctl --context homelab-talos-2-ssm service etcd
```

For a direct Talos command, obtain the protected config path and pass it to talosctl. The generated file has mode `0600`. Its default node is the first private controller. Use `--node PRIVATE_IP` with the helper to select another private node.

```sh
export TALOSCONFIG="$(direnv exec . scripts/cluster-access.py --cluster homelab-talos-2 --talos-config)"
direnv exec . talosctl --talosconfig "$TALOSCONFIG" version
```

The API providers follow the local transport selection. Set `PF_TALOS_TRANSPORT=ssm` and `PF_TALOS_FIXED_SSM` on a Terragrunt invocation for recovery even when VPN is selected. Kubectl's current context alone does not change Terraform's provider selection. Talos provider `0.12.0` refreshes a machine using its prior-state endpoint when switching transports. Inspect a full transition plan before applying it. A targeted `-refresh=false` transition plan can evaluate endpoint changes if the old endpoint is unavailable. Do not point Talos at the Kubernetes-only NLB.

## Plan and apply

Run each plan and apply in a new tmux window. The following commands use a private temporary directory for saved plans. Inspect the plan before applying it. Stop for explicit confirmation if it contains a deletion, replacement, disruption or other destructive action. Replan if state or inputs change. The router must exist before planning the Talos ingress with its real security group.

```sh
umask 077
mkdir -p tmp/tailscale-operator
tmux new-window -n router-plan -c "$PWD/environments/homelab/us-east-2/aws_tailnet_subnet_router" 'umask 077; direnv exec . terragrunt plan -out="$PWD/../../../../tmp/tailscale-operator/router.tfplan"; exec bash'
```

In that window, review the plan output. From the repository root, apply the reviewed saved plan in another window.

```sh
tmux new-window -n router-apply -c "$PWD/environments/homelab/us-east-2/aws_tailnet_subnet_router" 'umask 077; direnv exec . terragrunt apply "$PWD/../../../../tmp/tailscale-operator/router.tfplan"; exec bash'
```

The Talos caller uses the router `security_group_id` for its Kubernetes and Talos API source maps. Plan the scoped ingress using SSM. Inspect that plan before applying it in a separate window.

```sh
tmux new-window -n talos-ingress-plan -c "$PWD/environments/homelab/us-east-2/aws_kube_talos" 'umask 077; direnv exec . env PF_TALOS_TRANSPORT=ssm terragrunt plan -target=aws_vpc_security_group_ingress_rule.kube_api_source -target=aws_vpc_security_group_ingress_rule.api_lb_source -target=aws_vpc_security_group_ingress_rule.talos_api_source -out="$PWD/../../../../tmp/tailscale-operator/ingress.tfplan"; exec bash'
```

Review the plan, then apply the saved plan in a separate window.

```sh
tmux new-window -n talos-ingress-apply -c "$PWD/environments/homelab/us-east-2/aws_kube_talos" 'umask 077; direnv exec . env PF_TALOS_TRANSPORT=ssm terragrunt apply "$PWD/../../../../tmp/tailscale-operator/ingress.tfplan"; exec bash'
```

The 2026-11-24 deployment added 11 router resources and three ingress rules. Follow-up saved plans had no changes. Future plans can differ and need review.

## Verify and recover

Discover the running router and verify that the lookup returns exactly one `i-...` ID. During replacement, wait for the ASG to settle before using this lookup.

```sh
direnv exec . aws ec2 describe-instances --profile homelab-superuser --region us-east-2 \
  --filters Name=tag:Name,Values=tailscale-subnet-router-public-a Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

In the next commands, replace `i-...` with that ID. The EC2 system and instance checks should be `ok`. SSM should report `Online`.

```sh
router_id=i-...
direnv exec . aws ec2 describe-instance-status --profile homelab-superuser --region us-east-2 --instance-ids "$router_id"
direnv exec . aws ssm describe-instance-information --profile homelab-superuser --region us-east-2 --filters "Key=InstanceIds,Values=$router_id" --query 'InstanceInformationList[].PingStatus'
direnv exec . aws ssm start-session --profile homelab-superuser --region us-east-2 --target "$router_id"
```

In the SSM session, check `cloud-init status --wait`, `systemctl is-enabled tailscaled`, `systemctl is-active tailscaled`, `tailscale version` and `sysctl net.ipv4.ip_forward`. Check the Tailscale Machines page for the hostname, tag and the four approved routes. Do not repair first boot with a manual `tailscale up` when qualifying enrollment.

On 2026-11-24 the final launch template enrolled automatically. VPN DNS, authenticated Kubernetes and Talos, Helm, the Cilium read plan and two existing peers passed. Both APIs rejected credential-free requests. With local route acceptance disabled, the VPN path failed and explicit SSM Kubernetes and Talos recovery passed. Cluster health had 88 PASS, 5 WARN, 0 FAIL and 7 SKIP both before and after. The protected per-check evidence is in `/tmp/homelab-tailscale-resume.0ByhRj`, and the qualification record is `.specs/aws-tailscale-subnet-router/existing-client-qualification.md`. Temporary and ignored paths may not persist on another workstation.

The approved 2026-11-24 reboot preserved the router's Tailscale identity. The ASG then replaced the instance at desired capacity one. The new instance joined automatically with a fresh Tailscale identity and all four routes approved. During both outages, VPN Kubernetes readiness failed while explicit SSM readiness returned `ok`. VPN readiness returned after each drill. Both existing peers answered after replacement. The router and scoped Talos follow-up plans reported no changes, and cluster health again reported zero failures.

Network denial and revocation remain pending. The tested router-tagged identity could reach both API ports. Confirm a test identity's effective grants before using it for either check.

For a router outage, use `homelab-talos-2-ssm` and the AWS profile. Check the context and credentials if recovery fails. If VPN fails, inspect route acceptance, the route to the resolver, the split DNS suffix, route approval and the router's SSM/cloud-init status. If a new router fails enrollment, verify the OAuth credential and tag scope in the Tailscale console. Revoked or invalid credentials must be replaced in the SOPS caller secret and applied through a reviewed plan.

To roll back this workstation to its captured setting when route acceptance was originally false:

```sh
sudo tailscale set --accept-routes=false
direnv exec . kubectl --context homelab-talos-2-ssm get --raw=/readyz
```

Restore any captured DNS preference only if it was changed, using `tailscale set --accept-dns=<true|false>`. Verify the previously reachable mesh peers. To revoke a user or device, remove only its relevant policy membership or grant, then test denial and unrelated mesh access. This is independent of router OAuth rotation. Remove only DNS or policy entries that were added for this access, after reviewing their current ownership.

For secret rotation, update the encrypted caller secret, review and apply its SSM parameter plan, then validate a fresh isolated boot or confirmed replacement before revoking the old OAuth credential. The launch template ignores new AMIs and changes reach replacement instances. Production termination and cleanup of stale ephemeral nodes require confirmation.

Before a planned drill, verify both access contexts and get explicit confirmation for the disruption and any termination. With the discovered `router_id`, this reboots the same instance:

```sh
direnv exec . aws ec2 reboot-instances --profile homelab-superuser --region us-east-2 --instance-ids "$router_id"
```

Compare `cat /proc/sys/kernel/random/boot_id` and `tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["ID"])'` in SSM before and after the reboot. The boot ID should change, the Tailscale identity should stay the same, and VPN should recover. To replace a router after confirmation, keep the ASG's desired capacity:

```sh
direnv exec . aws autoscaling terminate-instance-in-auto-scaling-group --profile homelab-superuser --region us-east-2 --instance-id "$router_id" --no-should-decrement-desired-capacity
```

Discover the new instance and repeat the boot checks. Verify a new Tailscale node identity, the expected tag, all four approved routes and both API contexts. Exercise explicit SSM while VPN is unavailable if checking recovery during a router outage.

At 730 hours per month the router's fixed AWS estimate was $7.36 on 2026-11-24: $3.07 compute, $3.65 public IPv4 and $0.64 gp3 storage. The observed cluster snapshot changed from $206.17 to $353.18, including $139.65 from concurrent Karpenter worker turnover. Cross-AZ transfer, internet egress and Tailscale subscription charges are usage-dependent or unverified and excluded. The `t4g.nano` needed the boot script's swap during package installation.
