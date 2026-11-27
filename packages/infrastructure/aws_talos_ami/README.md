## Talos AMI

Builds AWS AMIs from Talos Image Factory images. For each entry in `images` it
creates a schematic, stages the raw disk in a private S3 bucket, imports it as an
EBS snapshot with VM Import and registers an AMI.

VM Import cannot read the Image Factory URL, so a short-lived t4g.nano helper
streams the `.raw.xz` image into S3 and shuts itself down. A `terraform_data`
resource launches it with the AWS CLI, skips the launch when the object already
exists and waits up to 90 minutes. The machine running apply needs the AWS CLI.
The helper has no public IP and runs in `subnet_id`, which needs NAT egress.
Staged objects expire after 7 days. The AMI name includes the Talos version, architecture and the
first 12 characters of the schematic ID, so a new version or extension list
produces a new AMI.

The `images` output returns the AMI ID and the matching installer image for
`aws_kube_talos`.
