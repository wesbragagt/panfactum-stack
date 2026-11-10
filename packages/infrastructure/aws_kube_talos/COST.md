# aws_kube_talos HA cost estimate

Estimate for the proposed HA topology, not a deployed or accepted one (see
[CHECKLIST.md](CHECKLIST.md)). Prices are us-east-2 list prices from the AWS
Pricing API and Spot price history on 2026-11-10, at 730 hours per month.

## Topology

- 3 Spot `t4g.medium` controllers, one per AZ (a/b/c), tainted so only
  cluster controllers schedule on them.
- Spot `c7g.large` workers, one per AZ.
- 3 fck-nat `t4g.nano` instances, one per AZ, so no AZ depends on another for egress.
- Kubernetes API through a Route53 private name to the controller IPs; no API load balancer.
- Existing internet-facing NLB for ingress.

## Monthly breakdown

| Item | Qty | Unit price | $/month |
|---|---|---|---|
| Controllers, `t4g.medium` Spot (a $0.0082, b $0.0135, c $0.0091/h) | 3 | Spot | 22.48 |
| Controller root disks, gp3 50 GB | 3 | $0.08/GB-month | 12.00 |
| Workers, `c7g.large` Spot (a $0.0292, b $0.0499, c $0.0208/h) | 3 | Spot | 72.93 |
| Worker disks, gp3 60 GB | 3 | $0.08/GB-month | 14.40 |
| fck-nat, `t4g.nano` on-demand | 3 | $0.0042/h | 9.20 |
| fck-nat disks, gp3 8 GB | 3 | $0.08/GB-month | 1.92 |
| Public IPv4 (3 NAT EIPs, 3 NLB) | 6 | $0.005/h | 21.90 |
| NLB, hourly plus about 1 LCU | 1 | $0.0225/h + $0.006/LCU-h | 20.81 |
| Route53 private zone, KMS key, S3 backups, cross-AZ traffic | - | estimate | 4.00 |
| **Total** | | | **179.64** |

With 2 Spot workers in AZs a and c instead of 3, the total is about $138.41.
On-demand controllers instead of Spot add $51.10 (`t4g.medium` at $0.0336/h).

## Spot controller risk

A Spot interruption gives a 2-minute notice. Three members tolerate one member
loss; two interruptions before the first replacement rejoins etcd lose quorum
and need a restore from backup. Quorum-safe replacement (CHECKLIST.md section 4)
is a prerequisite, not optional, for Spot controllers.

## Limits of this estimate

- Spot prices change hourly; AZ b was over twice AZ c on the sample date.
- Disk sizes come from `.specs/talos-cluster-hardening`, not a live HA build.
- Data transfer and LCU usage assume light traffic. Cross-AZ traffic
  costs $0.01/GB in each direction.
- List prices only; not reconciled against an AWS bill.
