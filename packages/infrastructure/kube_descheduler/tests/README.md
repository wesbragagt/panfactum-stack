Run with Helm, Python and PyYAML available:

```sh
python packages/infrastructure/kube_descheduler/tests/check_chart_contract.py
```

This exercises the actual pinned chart 0.35.1 for both dry-run values. The
reusable input defaults false, preserving eviction behavior; observation-only
callers must explicitly set true. It verifies emitted flags and the chart's
lack of init containers, not runtime policy parsing or permission enforcement.
`tofu init -backend=false` and `tofu validate` also passed with an isolated cache.
No module plan or cluster mutation is part of this verification.

The customizationHash now resolves each matching filename relative to
`path.module`, consistent with `fileset`. The current module has no matching
kustomize files; the correction also works if customizations are added later.
