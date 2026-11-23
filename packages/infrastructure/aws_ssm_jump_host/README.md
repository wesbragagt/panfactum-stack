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
