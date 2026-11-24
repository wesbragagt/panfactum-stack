## Usage

On a controller-only cluster whose nodes share an instance type, set
`instance_type_anti_affinity_required = false` to let CoreDNS use separate
nodes of that type. For a running deployment with hard instance-type
anti-affinity, first keep the default rollout settings while changing the
affinity. Wait for two Ready endpoints on separate nodes. Then set
`max_surge = "50%"` and `max_unavailable = 0` to preserve both replicas during
subsequent rollouts. Check that a third eligible node can host the surge pod.
