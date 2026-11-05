## Usage

No notes
For constrained self-managed clusters, `extra_helm_values` supplies explicit chart overrides merged last. Its empty default preserves existing values. Review single-node replica/anti-affinity choices and namespace exclusions against available capacity; preserve at least one admission/background controller and avoid dependencies on missing scheduler/image-cache services.
