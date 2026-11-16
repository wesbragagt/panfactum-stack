locals {
  cel_resource_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "${var.pg_cluster_namespace}-cnpg-adjustments-${local.cluster_name}", labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy = "Ignore"
      evaluation    = { admission = { enabled = true }, mutateExisting = { enabled = true } }
      matchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pg_cluster_namespace } }
        resourceRules     = [{ apiGroups = ["postgresql.cnpg.io"], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["clusters", "clusters/status"], resourceNames = [local.cluster_name] }]
      }
      mutations = [{ patchType = "ApplyConfiguration", applyConfiguration = {
        expression = <<-CEL
          Object{spec:Object.spec{resources:Object.spec.resources{
            requests:{'memory':'${var.pg_minimum_memory_mb}Mi','cpu':'${var.pg_minimum_cpu_millicores}m'},
            limits:{'memory':'${max(var.pg_minimum_memory_mb, coalesce(var.pg_non_vpa_memory_limit_mb, ceil(var.pg_minimum_memory_mb * 1.1)))}Mi'}
          }}}
        CEL
      } }]
    }
  }
  cel_backup_gc = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "DeletingPolicy"
    metadata   = { name = "${var.pg_cluster_namespace}-failed-backup-gc-${local.cluster_name}", labels = data.pf_kube_labels.labels.labels }
    spec = {
      schedule = "0 * * * *"
      matchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pg_cluster_namespace } }
        resourceRules     = [{ apiGroups = ["postgresql.cnpg.io"], apiVersions = ["v1"], operations = ["*"], resources = ["backups"] }]
      }
      conditions = [
        { name = "owned-cluster", expression = "object.metadata.name.startsWith(${jsonencode("${local.cluster_name}-")})" },
        { name = "failed", expression = "has(object.status) && has(object.status.phase) && object.status.phase=='failed'" },
        { name = "expired", expression = "time.now() - timestamp(object.metadata.creationTimestamp) > duration('${var.backups_retention_days * 24}h')" },
      ]
    }
  }
  cel_backup_pdb = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "${var.pg_cluster_namespace}-backup-pdb-${local.cluster_name}", labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy = "Ignore"
      evaluation    = { admission = { enabled = true }, mutateExisting = { enabled = true } }
      matchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pg_cluster_namespace } }
        resourceRules     = [{ apiGroups = ["postgresql.cnpg.io"], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["backups", "backups/status"] }]
      }
      variables = [
        { name = "running", expression = "!has(request.object.status) || !has(request.object.status.phase) || request.object.status.phase=='running'" },
      ]
      targetMatchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pg_cluster_namespace } }
        resourceRules     = [{ apiGroups = ["policy"], apiVersions = ["v1"], operations = ["*"], resources = ["poddisruptionbudgets"], resourceNames = ["${local.cluster_name}-pf-pdb"] }]
        expression        = "resource.Get('policy/v1','poddisruptionbudgets',${jsonencode(var.pg_cluster_namespace)},${jsonencode("${local.cluster_name}-pf-pdb")})"
      }
      mutations = [{ patchType = "JSONPatch", jsonPatch = {
        expression = <<-CEL
          !variables.running && has(object.metadata.annotations) &&
          'panfactum.com/voluntary-disruption-window-start' in object.metadata.annotations &&
          object.metadata.annotations['panfactum.com/voluntary-disruption-window-start']!='' ? [] :
          [JSONPatch{op:'add',path:'/spec/maxUnavailable',value:variables.running ? 0 : ${var.voluntary_disruption_window_enabled ? 0 : 1}}] +
          (variables.running ? [JSONPatch{op:'add',path:'/metadata/labels/panfactum.com~1voluntary-disruption-window-id',value:'false'}] :
          [${join(",", [for key, value in local.disruption_window_labels : "JSONPatch{op:'add',path:${jsonencode("/metadata/labels/${replace(replace(key, "~", "~0"), "/", "~1")}")},value:${jsonencode(value)}}"])}])
        CEL
      } }]
    }
  }
}

// The opt-in migration covers the canary's fixed resource budget. Fail closed
// for VPA callers until their recommendation arithmetic is migrated as well.
resource "terraform_data" "cel_compatibility" {
  count = var.kyverno_cel_policies_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = !var.vpa_enabled
      error_message = "CEL PostgreSQL policy migration currently requires vpa_enabled=false. Keep legacy policies for VPA consumers."
    }
  }
}
