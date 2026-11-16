# kube_kgateway

Installs kgateway v2.5.1 with one public Gateway behind an internet-facing NLB.

`manifests/` holds the Gateway API CRDs, the kgateway CRDs and the Gateway API
safe-upgrades admission policy. They use `apply_only = true` and `prevent_destroy`:
a plan that deletes them fails, and `tofu destroy` removes them from state without
deleting them from the cluster. Deleting a CRD deletes every Gateway and route.

Before upgrading the CRDs, keep every version listed in a CRD's `status.storedVersions`.
