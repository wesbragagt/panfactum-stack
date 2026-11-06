# Self-managed controller preparation

The reusable default chart pin remains **1.10.0**. It must not be deployed on
Kubernetes1.37: the official [compatibility matrix](https://karpenter.sh/docs/upgrading/compatibility/)
requires **1.15.x**. Caller-selected **1.15.1** was rendered from the published
OCI chart, whose image is 1.15.1 pinned by digest. This is an explicit caller
version change, not a blanket fork/devshell upgrade. Read the matching fork guide
before rollout: baseline9c3b2547's autoscaling chapter uses an EKS node-role
output and requires wait=false initially because controller installation precedes
its separately managed CRDs; the final source pin must be immutable/published.

Suggested explicit inputs (substitute discovered public IDs; never secret data):

```hcl
karpenter_helm_version = "1.15.1"
cluster_name = "the-actual-cluster-name"
cluster_endpoint = "https://the-reachable-api-endpoint:6443"
aws_region = "us-east-2"
vpc_id = "vpc-..."
node_role_arn = "arn:aws:iam::ACCOUNT:role/the-existing-worker-role"
existing_instance_profile_arn = "arn:aws:iam::ACCOUNT:instance-profile/existing-profile"
manage_instance_profiles_enabled = false
sla_target = 1
replicas = 1
namespace_linkerd_inject = false
vpa_enabled = false
monitoring_enabled = false
pull_through_cache_enabled = false
# Also provide shared oidc_provider_arn / oidc_issuer_url, subnet/IP restriction inputs.
```

There is no controller-wide VPC-ID setting in the pinned upstream chart. The
optional VPC input restricts the IAM launch-resource subnet/security-group ARNs
to resources discovered in that VPC in the configured AWS provider region.
NodeClass selectors must independently select that VPC. Region must match the
AWS provider. Explicit region sets AWS_REGION/AWS_DEFAULT_REGION and disables
SDK IMDS; explicit endpoint disables EKS endpoint-discovery IAM permission.
The cluster name is used consistently for settings, queues and ownership tags.
The role ARN stays required for narrowly scoped PassRole. An existing profile
ARN scopes GetInstanceProfile; ListInstanceProfiles retains its required wildcard
resource because upstream profile inventory/cleanup uses that list API. The matching
profile **name** must be supplied to the separate EC2NodeClass. Disabling profile
management removes Create/Tag/Add/Remove/Delete profile permissions.

`additional_controller_policy_json` supports reviewed version-specific IAM
supplements without silently broadening default permissions. Compare the actual
version's [CloudFormation policy](https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.15.1/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml).
The legacy module lacks 1.15.1 read actions DescribeCapacityReservations,
DescribeInstanceStatus and DescribePlacementGroups. A supplemental region-scoped
EC2 read statement is needed before deploying 1.15.1; assess optional node-repair
(RebootInstances), capacity-reservation/placement-group resource permissions and
Zonal Shift only if those features are enabled. Supplemental statement SIDs must
not collide with module-owned SIDs. Preserve Spot-only/on-demand-controller
constraints in NodePool integration; controller support alone does not bootstrap
Talos workers, grant cluster join access, constrain worker cost, or prove node
identity/networking/storage. Review total generated IAM policy size as well.

The controller explicitly disables Linkerd injection in all existing/default
profiles; namespace injection is now separately configurable (default true).
`extra_helm_values` is appended using Helm's native merge rules. Existing SLA
replica/strategy/scheduling defaults are retained when replicas is null. SQS
queue policy now uses the actual queue URL, fixing the previous name-as-URL bug.

Run the exact chart contract checks with Python, PyYAML and Helm available:

```sh
python packages/infrastructure/kube_karpenter/tests/check_chart_contract.py
```

Both1.10.0 and1.15.1 fixture renders verify explicit endpoint/name/region, no IMDS,
one unmeshed controller, no init container and400Mi request. These fixtures do
not evaluate the complete Terraform IAM policy or prove runtime permissions.
Backend-disabled init and OpenTofu validation passed with an isolated cache.
Direct inspection of public.ecr.aws/karpenter/controller:1.15.1's manifest index
confirmed linux/arm64 digest
`sha256:24b6f3dc14eba695f837b8bdd687df158ea0507949ab1429190f1ee6fad3607c`.
No AWS/Kubernetes calls, plans, applies, commits or pushes were run for this task.
