# kube_chaos_mesh

Installs Chaos Mesh 2.8.8 with containerd support. No experiments or schedules are installed.
Targets require the namespace annotation chaos-mesh.org/inject=enabled. Host-network testing is disabled. The privileged daemon runs on every node with mTLS to the controller. Restrict access to Chaos Mesh custom resources to cluster operators.

The dashboard requires Kubernetes credentials and exposes only ClusterIP. Access with kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333 using the talos-2 kubeconfig.

## Initial qualification

Use a disposable application namespace first. Record baseline success rate, request latency, pod readiness and recovery time in the observability stack. Run one bounded fault at a time with an explicit selector and duration, then verify recovery and remove the experiment.

1. Kill one replica and verify service continuity.
2. Add dependency latency and verify timeouts and retries.
3. Partition one replica and verify failover.
4. Apply bounded CPU or memory pressure and verify alerts.

Stateful restore, controller loss and AWS instance interruptions need separate recovery criteria and approval. Do not begin with clock changes, kernel faults or filesystem corruption. Namespace opt-in does not establish that every experiment type is safe. Preserve controller-to-daemon connectivity for fault recovery.

## Talos qualification

Verify the configured containerd socket against the live workload runtime before container-kill tests. Verify sch_netem availability before network delay/loss tests. Installation health alone does not prove fault injection compatibility.

The homelab caller uses the local vendored fork source. It is not a published upstream Panfactum module. Logging and monitoring are deployed separately.

## Verified deployment limitations

2026-11-17 on homelab-talos-2: controller and dashboard Ready, all six daemon pods Ready, final Terragrunt plan has no changes. Daemon startup reports failure to grant /dev/fuse access because it cannot find the device cgroup. Treat IOChaos as unqualified until a targeted compatibility test resolves this. No faults were injected.
