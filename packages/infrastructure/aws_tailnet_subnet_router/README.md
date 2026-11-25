<!-- cspell:words Headscale tailnet -->

# AWS tailnet subnet router

Advertise private VPC routes to either hosted Tailscale or a module-managed Headscale server. Pass backend, vpc_id and advertised_routes explicitly. Set ha_enabled and supply subnets in two distinct availability zones to provision two routers.

## Provision Headscale

Set `backend = "headscale"` and the caller's `headscale` input to provision the server outside Talos. Set `backend = "tailscale"` for hosted Tailscale.

```hcl
headscale = {
  hostname  = "headscale.example.com"
  zone_id   = "Z0123456789"
}
```

Use the existing public hosted zone and a public first subnet with an Internet Gateway route. The module allocates the server's Elastic IP, creates its Route 53 A record, and obtains a Let's Encrypt certificate over TCP 443. It stores the database, server identity and ACME cache on a separate encrypted EBS volume. Retain the volume when replacing the server within its AZ. Snapshot it before destroying the deployment or moving it to another AZ. [Headscale TLS documentation](https://headscale.net/0.28.0/ref/tls/)

The Headscale server uses a dedicated t4g.micro instance. Set `ha_enabled = true` and provide subnets in two distinct AZs to run two subnet routers. Headscale 0.28.0 may take up to 16 minutes to detect an offline router. The single Headscale server and its EBS volume remain in one AZ. Restoring service after an AZ outage requires recovery in another AZ from an EBS snapshot. [Headscale route failover](https://headscale.net/0.28.0/ref/routes/)

The server configures split DNS and automatically approves the advertised routes for `tag:subnet-router`. An enrolled user can reach the advertised CIDRs. Use private API authentication as usual. The Headscale service publishes a short-lived tagged key to `/<name>/headscale-router-enrollment` in SSM and renews it daily. The module keeps the key out of OpenTofu state and instance user data. After destroying a managed deployment, the operator can delete this runtime-created parameter once its routers are gone.

Open an SSM session to `managed_headscale.instance_id` for administration. Run `sudo /usr/local/bin/headscale --config /etc/headscale/config.json nodes list-routes` to check advertised and approved routes. Create a Headscale user and a separate single-use key for an operator's workstation. Connect with the `managed_headscale.login_server` URL and verify the private DNS and APIs. [Headscale client registration](https://headscale.net/0.28.0/usage/getting-started/)

## Use hosted Tailscale

Set `backend = "tailscale"` and pass `tailscale_oauth_client_secret`. Configure the Tailscale provider with OAuth credentials that can manage DNS. The credentials used by the router need permission to issue auth keys for the configured `tailscale_tag`. Approve the router's advertised routes in the control plane. Supply `split_dns_domains` to route the matching names to the VPC resolver.

OpenTofu 1.8 configures the Tailscale provider even when Headscale mode has zero Tailscale resources. For a fresh Headscale-only state, set `TAILSCALE_API_KEY=headscale-mode-unused` and `TAILSCALE_BASE_URL=http://127.0.0.1:1` for the unused provider. When planning against existing hosted Tailscale state, keep valid provider credentials until the hosted resources have been retired.
