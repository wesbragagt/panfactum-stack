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

## Fixed-destination sessions

Set `port_forwarding_documents` to a map with the AWS document name, remote
host, remote TCP port and optional description for each forward. Session
Manager callers can choose only `localPortNumber`. Use the `document_names`
output to look up AWS document names by the keys you passed.

For Talos, set the host from the same caller configuration used for the
bootstrap controller's private IP. Apply this module before planning the
cluster so its caller hook can use the documents as soon as the controller
starts. Keep existing AWS names and descriptions when moving the documents
between states.

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
