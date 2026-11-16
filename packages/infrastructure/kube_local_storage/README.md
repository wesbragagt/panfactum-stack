# kube_local_storage

Node-local dynamic PersistentVolumes for single-node local clusters (kind, Talos in Docker) through
rancher/local-path-provisioner. Not for EKS or multi-node clusters: volumes are bound to one node path
and have no snapshot or expansion support.
