# aws_kube_talos improvement checklist

Reconciled 2026-11-10 against the `talos` branch at
`378c7e8a` (three Spot control planes with a private API name).
This is the canonical module tracker, superseding the 2026-10-27 review.
The 2026-11-10 homelab deployment `homelab-talos-ha` is the first multi-control-plane
runtime evidence (section 7). HA remains **experimental, not runtime accepted**:
it spans two AZs, has no workers and no failure-injection tests. Work in dependency
order; completing a source change does not complete its runtime acceptance gate.

## Evidence and status rules

- **Implemented** means present in source; **statically checked** requires a named
  check/result. Neither means deployed. **Single-node tested** describes only the
  cited historical deployment/test. **HA runtime tested** requires section 7 evidence.
- Checked boxes in sections 1–6 record source inventory only; a checked section 7
  gate records cited runtime evidence. All work still required is unchecked. Do
  not check an item solely from memory, a single-node restore, a test script's
  existence, or another caller's success.
- Module evidence: [main.tf](main.tf), [vars.tf](vars.tf),
  [outputs.tf](outputs.tf), [ssm.tf](ssm.tf), [backup.tf](backup.tf),
  [backup script](etcd-backup.py), [test scope](tests/README.md) and
  [restore test](tests/test.py).
- Cross-repository evidence is historical, not a dependency or live health claim:
  homelab repository `docs/talos-prototype.md` (Terraform proof cluster and
  controller-loss recovery drill, 2026-10-31; retirement, 2026-11-01),
  `docs/talos-prototype-ccm.md`, `docs/talos-prototype-karpenter.md`, and
  `docs/talos-prototype-storage.md` (retained prototype integration results).
  Its `environments/homelab/us-east-2/aws_kube_talos/terragrunt.hcl` has
  `skip = true`; it must not be enabled to test this checklist. The retained
  prototype is not managed by this module's controller resources.
- Pinned source contract: AWS provider `6.40.0`, Talos provider `0.12.0`;
  defaults Talos `v1.14.5`, Kubernetes `1.37.0`. Prototype results with other
  caller patches/versions do not prove this exact module. Before implementation,
  verify version-specific configuration, reset, upgrade and recovery semantics
  against the exact selected official Talos/provider documentation; attach those
  references and rendered-config checks to the resulting change.

## 1. Preserve implemented foundations; identify their limits

- [x] **Count guard relaxed to 1 or 3 (378c7e8a).** `vars.tf` permits
  `control_plane_count` 1 (default) or 3; a precondition requires
  `private_api_dns_name` for 3 and one `control_plane_subnets` entry per node.
  Cross-variable checks are preconditions because OpenTofu 1.8 rejects them in
  variable validation. Two members are rejected because they add no failure budget.
- [x] **Spot control planes implemented (378c7e8a).** `control_plane_spot_enabled`
  creates persistent Spot instances with `instance_interruption_behavior = "stop"`,
  so a node keeps its disk, private IP and etcd membership and can be stopped to
  suspend the cluster. `control_plane_instance_types` sets a type per node because
  `aws_instance` takes one type and Spot capacity differs per AZ.
- [x] **Private API name implemented (378c7e8a).** `private_api_dns_name` creates a
  private Route53 zone and one A record with every controller private IP (TTL 30).
  It becomes the cluster endpoint for control planes and workers and an API cert
  SAN. No health checks: a stopped controller's IP stays in the record.
- [x] **Supplied PKI contract implemented.** Sensitive `machine_secrets` and
  `client_configuration` inputs replace generated-in-module secrets. The old
  caller supplies SOPS-decrypted values. These values still enter Terraform state
  and EC2 user data; “outside Terraform state” is not achieved by SOPS inputs.
- [x] **Worker replacement capacity implemented in source.** `main.tf` has a
  fixed-size Spot ASG and launch template, not individual worker instances.
  It is EC2-health based, has no guaranteed Spot capacity or Kubernetes readiness
  repair, and joins through controller zero's private IP unless
  `private_api_dns_name` is set. The homelab proof docs
  explicitly describe the ASG proposal as unapplied in that proof deployment.
- [x] **Cilium preparation and small-cluster scheduling inputs implemented.**
  `cilium_enabled` removes Flannel/kube-proxy in control-plane config;
  `control_plane_workloads_enabled` changes control-plane taints. Worker config
  currently omits `local.cilium_config_patches`; parity and rendered typed-taint
  behavior need checking (the historical caller carries a taint override).
- [x] **Private operator ingress implemented.** `ssm.tf` accepts an existing
  tunnel-host SG for ports 6443/50000. Nodes, EIP, optional public DNS and default
  Talos client endpoints remain public; this is not a private-only architecture.
- [x] **Backup/restore test code exists.** Docker/Floci test covers marker-based
  single-controller recovery using the production backup script. Its README
  excludes real AWS policy enforcement and the CronJob wrapper. Historical AWS
  single-controller recovery is documented in homelab; no HA claim follows.

## 2. Decide and validate the HA topology (blocks 3–7)

- [ ] **Define the supported topology contract before relaxing the count guard.**
  Document single-node mode separately from HA, allowed integer replica counts,
  replica-to-AZ/subnet mapping and minimum distinct failure domains. Explain etcd
  majority quorum (`floor(N/2)+1`) and tolerated member loss
  (`N - quorum`): three members tolerate one member loss. Two members do not add
  a failure budget. Specify whether single-AZ HA is supported (host failures only)
  and whether multi-AZ HA is supported (only AZ losses leaving a quorum).
  Acceptance: validation rejects unsupported counts, duplicate/missing subnet
  matches, insufficient AZs and placements exceeding the declared loss budget.
- [ ] **Make placement stable and intentional.** Done in 378c7e8a: node N uses
  subnet name `control_plane_subnets[N]`, so adding an unrelated subnet no longer
  remaps nodes. Still open: indexes are positional (reordering the list replaces
  nodes), and repeated subnets are allowed so a caller can place two nodes in one
  AZ when Spot capacity is missing; that is documented in the variable, not
  rejected. Acceptance remaining: duplicate AZ placements cannot be mistaken for
  AZ resilience; worker spread is defined.
- [ ] **Separate control-plane availability from workload availability.** Decide
  on-demand controller capacity, workload scheduling on controllers versus
  baseline workers, Spot interruption exposure and spare capacity after a loss.
  Record capacity/cost tradeoffs for extra instances, root disks, endpoint
  services, cross-AZ traffic, NAT/egress and backups without current price claims.
  No additional compute, volumes or endpoints are authorized by this checklist.

## 3. Stable private access and bootstrap (depends on 2)

- [ ] **Choose the Kubernetes endpoint design from existing constraints.**
  Partly done in 378c7e8a: with `private_api_dns_name`, nodes use a private
  multi-A name for all controllers; KubePrism balances after join. Without it,
  `local.cluster_endpoint`, EIP association and optional Route53 A record all
  target controller zero, and worker config embeds that controller's private IP.
  The private record has no health checks. Operator kubeconfig still points at the
  private name, which is unreachable from outside the VPC without a tunnel.
  Evaluate a private endpoint with health routing/failover versus a suitable
  internal load-balancing design; document client behavior, TTL/retry budgets
  and dependencies. Do not assume a new public endpoint/NLB is required. All
  nodes and clients must use a supported stable path that survives the declared
  controller/AZ failure.
- [ ] **Design Talos management discovery separately.** Apply, bootstrap,
  kubeconfig retrieval and generated talosconfig currently use one public EIP;
  bootstrap/kubeconfig also select node zero. Observed 2026-11-10: while node zero
  was stopped, the operator had to use another node's ephemeral public IP as the
  talosctl endpoint. Provide private reachable management
  endpoints/node discovery, health checks and recovery access when that node or
  the operator tunnel host/AZ is lost. Assess the existing SSM ingress/access path
  and any singleton NAT/tunnel dependency; Kubernetes endpoint failover alone
  does not prove Talos management availability.
- [ ] **Preserve endpoint identity and trust.** `api_san_patch` includes the API
  host/EIP and is delivered after initial user data. Define initial and later
  Kubernetes/Talos SANs for private names/IPs, certificate issuance/rotation and
  trust continuity. Acceptance: verified TLS on fresh boot, failover and node
  replacement without insecure flags or unexpected CA changes.
- [ ] **Bootstrap once; join subsequently.** Retain a single bootstrap action,
  define idempotence/state-loss recovery and selection of a healthy node without
  re-bootstrapping existing etcd. Acceptance: repeated reconciliation, first-node
  loss and adding members neither create a second cluster nor repeat bootstrap.

## 4. Node lifecycle, upgrades and migration (depends on 2–3)

- [ ] **Define per-node identity/config and discovery.** Current control planes
  share one configuration data source. Verify unique machine identity, hostname,
  advertised addresses, join/discovery and etcd membership under the selected
  Talos version; introduce per-node patches only where needed. Check worker CNI
  parity and join behavior through the stable private endpoint.
- [ ] **Make Spot resume reliable.** Observed 2026-11-10 on `homelab-talos-ha`:
  `StartInstances` returns `IncorrectSpotRequestState` until every Spot request is
  `disabled`/`instance-stopped-by-user`; one `InsufficientInstanceCapacity` fails a
  batch start entirely. Starting nodes one at a time and retrying restored quorum
  with two nodes; the third needed 8 attempts. Provide a resume procedure or
  script, document capacity-dependent resume time, and decide whether a node that
  cannot resume is replaced with another type (a new etcd member).
- [ ] **Implement quorum-safe replacement and scaling procedures.** Current apply
  resources lack graceful-reset destroy settings and count changes lack a live
  membership safeguard. Assess provider reset semantics before adding them;
  blind graceful reset or `prevent_destroy` is not a complete replacement policy.
  Require healthy quorum checks, controlled stale-member removal, replacement
  join/catch-up, scale-up/down safeguards and rejection of concurrent member loss
  beyond the budget. Document recovery when the failed node cannot leave cleanly.
- [ ] **Bound disruptions and upgrades.** Define one-member-at-a-time OS/config
  maintenance, health/catch-up gates and stop/rollback conditions; Kubernetes
  upgrade order and version-skew checks need their own procedure. `ignore_changes
  = [ami, user_data]` prevents those fields from upgrading existing instances;
  changing defaults is not an upgrade. Ensure later applies cannot roll live
  versions back. Record availability expectations for each supported topology.
- [ ] **Preserve state addresses and output compatibility.** Inventory
  `aws_instance.control_plane[count]`, apply resources, EIP/DNS, bootstrap and
  kubeconfig addresses before introducing stable keys. Supply explicit state
  moves/imports and targeted migration steps. Preserve current single-node
  defaults and `cluster_url`, CA, SG, sensitive configs, public-IP list and ASG
  output contracts, or document a versioned transition for private-only mode.
  Acceptance: reviewed migration plans show each replacement/deletion explicitly,
  no accidental PKI/backup loss and no unrelated replacements. Destructive plan
  actions require explicit confirmation; no implementation/apply is implied here.

## 5. Network, dependencies, workload and storage availability (depends on 3–4)

- [ ] **Complete private-only bootstrap and routing.** Remove public node access
  only through an explicit migration; verify inter-AZ API/Talos/etcd traffic,
  routing, SGs and DNS resolution, private operator paths, required service
  endpoints or approved egress and least-privilege IAM. Existing self-SG permits
  intra-cluster traffic; current public API node rule permits only the EIP /32.
  Remove signing PKI from user data; verify EC2 user-data inspection contains no
  private signing keys. Protect sensitive state and join credentials as well.
- [ ] **Reconcile existing integrations rather than recreate missing work.**
  [Karpenter Talos support](../kube_karpenter_node_pools/talos.tf) already supplies
  Custom AMI worker config, private nodes, Spot requirements and disruption
  budgets. [EBS CSI inputs](../kube_aws_ebs_csi/vars.tf) already accept custom OIDC;
  [render check](../kube_aws_ebs_csi/tests/check_talos_render.py) exists. Homelab
  documents CCM/providerID/zone labels, OIDC/IRSA, Spot joins and EBS provisioning
  on its prototype. Port/reuse only the necessary contracts; this module has no
  worker-config output and does not itself install those integrations.
- [ ] **Exercise dependency failover.** Inventory Cilium/operator, CoreDNS, CCM,
  Karpenter controller, OIDC issuer/discovery/JWKS, admission webhooks, ingress and
  service endpoints. Define replica spread, anti-affinity/topology constraints,
  scheduling tolerations, resource headroom and PDBs. Eliminate or explicitly
  exclude singleton dependencies from the claimed availability scope. Test API,
  pod networking, DNS and AWS credentials during failures; replica count alone
  does not prove availability.
- [ ] **Document storage's separate failure boundary.** EBS-backed workloads need
  AZ-aware scheduling and attach/detach/replacement handling. Prove same-AZ node
  replacement, attachment recovery and retained-volume policy; document what
  happens if the volume's AZ is unavailable. PDBs do not create capacity or make
  an AZ-bound volume multi-AZ. Define application replication/restore separately;
  do not claim uninterrupted stateful workloads from control-plane HA.

## 6. Backups and disaster recovery (parallel hardening; required before 7)

Backups recover lost state; they do not maintain quorum or prevent API downtime.

- [ ] **Qualify real multipart uploads under this bucket policy.** `backup.tf`
  still has `RequireKMS`/`RequireBackupKey` denies and prefix-scoped KMS context.
  Test the exact policy/uploader combination, including wrong-key denial and a
  snapshot larger than 8 MiB; revise only after verifying header/policy semantics.
  Prototype multipart success used a different backup configuration.
- [ ] **Alert on stale backups and preserve a last good restore point.** Current
  lifecycle expires both current/noncurrent snapshots after retention days.
  Define latest/retained-version protection, monitored freshness and restore
  verification. Acceptance: a simulated long backup outage leaves a usable
  snapshot and generates an alert.
- [ ] **Make backup execution reproducible and updates deliverable.** CronJob
  downloads talosctl and installs awscli at runtime; checksums are not tied by
  validation to `talos_version`. Pin a self-contained image/digest and matching
  tools. Prove execution without GitHub/PyPI. Establish how inline-manifest,
  script and credential changes reach an existing cluster; do not assume a
  machine-config apply or Kubernetes upgrade reconciles every manifest.
- [ ] **Replace static backup keys with scoped workload identity.** Preserve
  least-privilege backup role and namespace restrictions, verify secret rotation,
  SSE-KMS uploads and restore decrypt access. Existing prototype IRSA results
  are evidence to reuse, not proof that this module has migrated.
- [ ] **Write and exercise a module restore runbook.** Cover repo-held encrypted
  secrets, S3/KMS access, full quorum loss versus one-member replacement, changed
  IPs/SANs, stale membership, `bootstrap --recover-from`, restore of dependencies
  and post-restore backups. Measure RPO/RTO and compare pre/post-snapshot markers.
  Historical single-controller AWS recovery is useful precedent; a multi-member
  restore and application data recovery remain open. Optional cross-region copy
  requires an explicit recovery requirement and cost/retention decision.

## 7. HA runtime acceptance gates (all open; after 2–6)

For each gate attach source revision, exact versions/topology, sanitized commands,
health/member counts, timestamped API request results, outage duration, expected
budget, recovery steps and rollback/restore outcome. Static checks and single-node
experiments cannot satisfy these gates. Failure injection needs separate scope
and destructive-action approval before execution.

- [ ] **Fresh deployment:** deploy the selected multi-control-plane topology;
  verify unique identities, expected AZ mapping, one bootstrap, complete healthy
  etcd membership and worker joins; repeat reconciliation without re-bootstrap.
  Partial evidence 2026-11-10 (`homelab-talos-ha`, 378c7e8a, Talos v1.14.5,
  Kubernetes 1.37.0, Flannel): 3 persistent Spot arm64 controllers (t4g.large
  us-east-2a, 2 × c7g.large us-east-2c), one bootstrap, 3 voting etcd members,
  3 Ready nodes, `talosctl health` passed, follow-up plan reported no changes.
  Missing: us-east-2b had no arm64 Spot capacity (10 types probed), so only two
  AZs; t4g.medium had no Spot capacity in any AZ; no worker joins (worker_count 0).
- [x] **Suspend and resume:** 2026-11-10 `homelab-talos-ha`. Marker ConfigMap
  written 17:52:24Z; all 3 instances stopped by 17:53:42Z with private IPs kept.
  Resume needed per-node starts (see section 4); nodes 1–2 restored quorum with a
  leader at 18:05:17Z, node 0 running 18:08:25Z, `talosctl health` passed 18:09:06Z
  with 3 members at the same raft index, 3 Ready nodes and the marker present.
- [ ] **Endpoint continuity:** continuously issue authenticated Kubernetes reads
  and writes through the stable private endpoint; verify Talos management access
  independently and TLS identity across backend failover.
- [ ] **Controller loss:** inject loss of one member within the documented budget,
  including the original bootstrap node. Show surviving quorum/API behavior,
  workload/network/DNS checks and bounded endpoint failover.
- [ ] **AZ loss:** for a claimed multi-AZ topology, isolate one AZ within its loss
  budget, including routing/operator/service dependencies. Measure API and scoped
  workload availability; record excluded storage/workload guarantees explicitly.
- [ ] **Recovery and replacement:** restore membership/capacity without a second
  bootstrap, stale member or unexpected state/address churn; prove new worker
  joins and subsequent backups. Exercise rejected unsafe scale-down operations.
- [ ] **Rolling maintenance:** upgrade OS, Kubernetes and relevant config using
  bounded sequencing while observing quorum/API continuously. Meet the declared
  uninterrupted quorum/API expectation or record and fix the gap before acceptance.
- [ ] **Failure and rollback:** inject a failed join/upgrade, stop safely, recover
  or roll back where supported, and exercise full-quorum-loss restore separately.
  Retain evidence that restore, API and application validation passed.

## Decision gate

- [ ] Review topology, private endpoint/access choice, supported failure budget,
  workload/storage scope, recurring capacity/cost and migration risk before HA
  implementation. Decide whether Talos remains preferable to `aws_eks` for that
  scope. Keep the current low-cost single-node callers valid; do not expand
  infrastructure automatically or treat this checklist as provisioning consent.
