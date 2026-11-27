# Private SSM jump host

Apply this module before creating a cluster that needs a dedicated SSM path.
Pass the cluster name and the IDs of an existing VPC and private subnet with
outbound connectivity to Systems Manager. The default instance type is
`t4g.nano`. The apply role needs `ssm:GetParameter` for
`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`.

Use `instance_id` to target the host and check that it reports `Online` in SSM.
Pass `security_group_id` as a source of ingress on each cluster API the host
should reach. The host has no inbound security group rules or public IP. The
caller manages user permissions for starting sessions.

## Second jump host

Set `secondary_subnet_id` to add a private host in another AZ of the same
VPC. Supply independent paths from the two subnets to Systems Manager and
allow the shared `security_group_id` to reach the intended cluster API ports.
The two hosts have the same `Name` tag, `<cluster>-ssm-tunnel`, and the same
`panfactum.com/cluster` and `panfactum.com/module` tags. The module tag is
`aws_ssm_jump_host`. Use `instance_ids` for the approved instance IDs in
primary-first order. `instance_id` still identifies the primary.

Set `resource_name` for a new standalone deployment alongside a legacy
embedded jump host with the same cluster name. It changes the role,
instance profile and security group names. Both hosts retain their
cluster-based discovery tags. Choose the override before the first apply.

## Talos access

For a new cluster, set `talos_bootstrap.kubernetes_host` to the planned
private API DNS name and `talos_bootstrap.controller_ips` to the fixed
controller addresses. Apply the jump host before Talos. Pass its
`security_group_id` to the Talos deployment so Talos owns API ingress.
Use `instance_ids` and `document_destinations` to configure fixed sessions.
The first controller uses the `talos` document key and later controllers
use indexed keys.

Existing deployments that manage API ingress in this module continue using
`talos_access.kubernetes` and `talos_access.talos`. They supply the same
destinations together with their target security groups. `talos_access`
takes precedence when both inputs are set.

## Fixed-destination sessions

Set `port_forwarding_documents` to a map with the AWS document name, remote
host, remote TCP port and optional description for each forward. Session
Manager callers can choose only `localPortNumber`. Use the `document_names`
output to look up AWS document names by the keys you passed.

For a new Talos deployment, `talos_bootstrap` supplies the standard ports and
document names. Use `port_forwarding_documents` for custom destinations or
when preserving existing document names during a state transfer.

The following example configures documents for two controllers.

```hcl
port_forwarding_documents = {
  kube = {
    name = "canary-kube-forward"
    host = "api.canary.internal"
    port = 6443
  }
  talos-a = {
    name = "canary-talos-a-forward"
    host = "10.0.128.20"
    port = 50000
  }
  talos-b = {
    name = "canary-talos-b-forward"
    host = "10.0.192.20"
    port = 50000
  }
}
```

Apply this module before planning the cluster so the hook can use the initial
controller's document as soon as the controller starts. If bootstrap needs
direct Kubernetes access before the load balancer is ready, configure a
separate TCP 6443 document for the initial controller and pass its name as a
privileged recovery document. Use `document_destinations` to pass each
document's `name`, `host` and `port` to the client. Documents are shared by
both jump hosts.

For an Identity Center caller, set `talos_operator_access.jump_host_id` from
`instance_id`, and set `additional_jump_host_ids` from the remaining
`instance_ids`. Set `kube_document_name` from the ordinary Kubernetes
document's name and list every Talos and bootstrap-only document name in
`recovery_document_names`. Ordinary operators get session access to the
specified Kubernetes document on the approved jump hosts. The existing
Superuser path covers Talos recovery, including explicit NAT selection.
The Admin, Reader and RestrictedReader base policies already grant
`ssm:GetDocument` for client-side document verification. Custom roles can
grant that action on the specific approved document ARN.

Keep existing AWS names and descriptions when moving the documents between
states.

## Transfer existing documents from cluster state

Skip this section for a fresh deployment. In an existing deployment, pause
applies and back up both states. Set `port_forwarding_documents` to match the
existing AWS documents, including their names, hosts, ports and descriptions.

1. In the jump-host caller, add import blocks for `aws_ssm_document.api["kube"]`
   and `aws_ssm_document.api["talos"]`. Use the existing AWS document names
   as the import IDs. Plan and apply the imports after confirming both
   documents require zero creates, updates or destroys.
2. In the cluster caller, remove the obsolete
   `ssm_session_documents_enabled` input. With OpenTofu 1.8 or newer, add
   this temporary block to the root configuration:

   ```hcl
   removed {
     from = aws_ssm_document.api

     lifecycle {
       destroy = false
     }
   }
   ```

   Plan and apply after confirming both old entries will be forgotten and
   neither AWS document will be destroyed.
3. Verify the jump-host state tracks both documents and the cluster state
   tracks neither. Remove the temporary blocks and review both plans again.

[OpenTofu state transfer](https://opentofu.org/docs/cli/state/move/)
