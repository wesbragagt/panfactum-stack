# Tailscale subnet router on AWS

This module runs Tailscale subnet routers on EC2 so tailnet devices reach private VPC addresses. Each router is an Amazon Linux 2023 arm64 instance in its own Auto Scaling group of size 1. With `ha_enabled`, a second router in the second subnet advertises the same routes, and Tailscale fails over between them.

Routers SNAT tailnet traffic to their own VPC address. VPC route tables need no `100.64.0.0/10` entry, and source/destination checks stay on.

## Requirements

1. A Tailscale OAuth client with the `auth_keys` and `dns` write scopes, allowed to assign `tailscale_tag`. Routers read its secret from an SSM SecureString at boot and mint their own ephemeral, preauthorized key, so a replacement router never depends on an expiring auth key. See [Create the trust credential](#create-the-trust-credential).
2. Tailnet policy entries for the tag. Add them before the first apply. Routes advertised before `autoApprovers` exists stay pending until a router re-advertises them.

   ```json
   "tagOwners": { "tag:aws-subnet-router": ["autogroup:admin"] },
   "autoApprovers": {
     "routes": {
       "10.0.64.0/18": ["tag:aws-subnet-router"],
       "10.0.0.2/32":  ["tag:aws-subnet-router"]
     }
   }
   ```

3. The Tailscale provider reads `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET` from the environment. Set them in the caller, for example with a Terragrunt `extra_arguments` block.
4. Subnets in different AZs. With `public_ip_enabled` (the default) they must be public subnets, so peers connect directly over UDP 41641 instead of relaying through DERP.

## Create the trust credential

You need the Owner, Admin, Network admin or IT admin role. Steps follow [OAuth clients](https://tailscale.com/kb/1215/oauth-clients).

1. Add the tag to `tagOwners` in the tailnet policy file, together with the `autoApprovers` entries above, and save. A client can only be given tags that already exist.
2. Open the [Trust credentials](https://login.tailscale.com/admin/settings/trust-credentials) page of the admin console and select **Credential**.
3. Select **OAuth**.
4. Set **Auth Keys** to **Write**, then select `tag:aws-subnet-router` (or your `tailscale_tag`). Routers can only advertise the tags selected here.
5. Set **DNS** to **Write**. The Terraform provider needs it to manage split DNS.
6. Select **Generate credential**, then copy the client ID and the `tskey-client-...` secret. The secret is shown only once.
7. Select **Done**.
8. Store both values SOPS-encrypted next to the caller's `terragrunt.hcl`:

   ```sh
   sops <environment>/<region>/aws_tailscale_subnet_router/secrets.yaml
   ```

   ```yaml
   tailscale_oauth_client_id: <client ID>
   tailscale_oauth_client_secret: tskey-client-...
   ```

The secret does not expire until you revoke it. Revoking it does not remove routers that have already joined. A rotated secret reaches routers only through replacement instances, after you apply the module so the SSM parameter updates.

## Split DNS

`split_dns_domains` points each domain at the VPC resolver (VPC base address plus 2) and adds that `/32` to the advertised routes. Use it for Route53 private zones.

## Reaching restricted targets

Targets whose security groups allow only specific sources, such as the Talos Kubernetes and Talos APIs, need an ingress rule for the `security_group_id` output.

## Updates

The launch template ignores new AMIs, and changes reach only replacement instances. To roll a change out with HA, terminate one router, wait for its replacement to show as connected in Tailscale, then terminate the other.
