## Talos worker identity

Creates an EC2-trusted IAM role and instance profile for an existing self-managed
Talos Kubernetes cluster. It does not create nodes, configure machine bootstrap,
register EKS access entries or read cluster credentials. AWS provider default tags
are inherited from the caller.

The inline policy permits ECR authorization and image reads from repositories in
the caller's current AWS account and region. Cross-account or other-region private
registries require an explicit future policy change. Public registries require no
additional IAM permissions. Talos must have an appropriate credential provider
configured to use this role for private ECR pulls; attaching the role alone does
not configure registry authentication.

For the opt-in controller profile, `controller_additional_ecr_repositories`
adds the three image-read actions for exact repository names in this account
and region. Its empty default preserves existing access. This does not add
first-import, repository creation, image-push or cross-account permissions.
Use it for separately managed immutable images rather than putting custom
images under a pull-through cache prefix.

Pass `node_role_arn` to the Karpenter controller module and
`node_instance_profile` to the Custom EC2NodeClass. Pod AWS access should use the
cluster's scoped OIDC service account roles. The EC2 role deliberately contains no
EKS, SSM, CNI or broad node managed policies.
