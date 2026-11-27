locals {
  cel_cilium_tolerations = ["burstable", "spot", "arm64", "controller"]
  cel_pod_fields         = ["containers", "initContainers"]
  cel_containers = {
    for field in local.cel_pod_fields : field => "object.spec.?${field}.orValue([])"
  }
  # NOTE: Keep these mutations in one policy so environment values see rewritten images.
  cel_pod_mutations = concat(
    [
      {
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-CEL
            request.namespace != ${jsonencode(local.cilium_test_namespace)} ? [] :
              cel.bind(labels, {"panfactum.com/descheduler-enabled": "false", "linkerd.io/inject": "disabled"},
                !has(object.metadata.labels) ? [JSONPatch{op: "add", path: "/metadata/labels", value: labels}] :
                  ["panfactum.com/descheduler-enabled", "linkerd.io/inject"].filter(k, !(k in object.metadata.labels))
                    .map(k, JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey(k), value: labels[k]})) +
              (!has(object.metadata.annotations) ?
                [JSONPatch{op: "add", path: "/metadata/annotations", value: {"karpenter.sh/do-not-disrupt": "true"}}] :
                ("karpenter.sh/do-not-disrupt" in object.metadata.annotations ? [] :
                  [JSONPatch{op: "add", path: "/metadata/annotations/karpenter.sh~1do-not-disrupt", value: "true"}]))
          CEL
        }
      }
    ],
    var.pull_through_cache_enabled && !var.cluster_wide_pull_through_cache_enabled ? [for field in local.cel_pod_fields : {
      patchType = "JSONPatch"
      jsonPatch = {
        expression = <<-CEL
          request.operation != "CREATE" ||
            object.metadata.?labels[?"panfactum.com/pull-through-cache-enabled"].orValue("") == "false" ? [] :
            ${local.cel_containers[field]}.map(c, cel.bind(
              registry, ${jsonencode(local.registry_replacements)}.filter(r, c.image.startsWith(r.host + "/")),
              cel.bind(
                isShort, c.image.contains(":") && !c.image.split(":")[0].contains("."),
                size(registry) == 0 && !isShort ? [] : [
                  cel.bind(
                    prefix, size(registry) != 0 ? registry[0].prefix : "docker-hub",
                    cel.bind(
                      path, size(registry) != 0 ? c.image.substring(size(registry[0].host) + 1) : c.image,
                      JSONPatch{
                        op: "replace",
                        path: "/spec/${field}/" + string(${local.cel_containers[field]}.indexOf(c)) + "/image",
                        value: ${jsonencode(local.pull_through_cache_registry)} + "/" + prefix + "/" +
                          (prefix == "docker-hub" && !path.contains("/") ? "library/" : "") + path
                      }
                    )
                  )
                ]
              )
            )).flatten()
        CEL
      }
    }] : [],
    [
      {
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-CEL
            request.operation != "CREATE" ? [] : cel.bind(
              existing, object.spec.?tolerations.orValue([]),
              cel.bind(
                labels, object.metadata.?labels.orValue({}),
                cel.bind(
                  defaults, request.namespace == ${jsonencode(local.cilium_test_namespace)} ?
                    ${jsonencode(local.cel_cilium_tolerations)} :
                    ${jsonencode(local.default_tolerations)}.filter(k, labels[?("panfactum.com/" + k + "-enabled")].orValue("") != "false"),
                  cel.bind(
                    missing, defaults.filter(k, !existing.exists(t, t.?key.orValue("") == k)),
                    cel.bind(
                      added, missing + (existing.exists(t, t.?key.orValue("") == "controller") || "controller" in missing ?
                        ["arm64", "spot", "burstable"].filter(k, !(k in missing) && !existing.exists(t, t.?key.orValue("") == k)) : []),
                      size(added) == 0 ? [] : [
                        JSONPatch{op: "add", path: "/spec/tolerations", value:
                          dyn(existing) + added.map(k, {"key": k, "operator": "Equal", "value": "true", "effect": "NoSchedule"})}
                      ] + (has(object.metadata.labels) ? [] : [JSONPatch{op: "add", path: "/metadata/labels", value: {}}]) +
                        added.map(k, JSONPatch{op: "add", path: "/metadata/labels/" +
                          jsonpatch.escapeKey("panfactum.com/" + k + "-enabled"), value: "true"})
                    )
                  )
                )
              )
            )
          CEL
        }
      }
    ],
    var.environment_variable_injection_enabled ? local.cel_environment_mutations : [],
    [
      for target, values in {
        labels      = merge({ "panfactum.com/kyverno-mutated" = "true" }, var.common_pod_labels)
        annotations = var.common_pod_annotations
        } : {
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-CEL
            request.operation != "CREATE" ? [] :
              (!has(object.metadata.${target}) ?
                [JSONPatch{op: "add", path: "/metadata/${target}", value: ${jsonencode(values)}}] :
                ${jsonencode(keys(values))}.filter(k, !(k in object.metadata.${target})).map(k,
                  JSONPatch{op: "add", path: "/metadata/${target}/" + jsonpatch.escapeKey(k), value: ${jsonencode(values)}[k]}))
          CEL
        }
      } if length(values) > 0
    ]
  )

  cel_cilium_namespace_rule = {
    apiGroups     = [""]
    apiVersions   = ["v1"]
    resources     = ["namespaces"]
    resourceNames = [local.cilium_test_namespace]
  }

  # NOTE: Separate cache lookups so a transient context failure cannot suppress ordinary Pod mutations.
  cel_create_pod_rules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["pods"] }]

  cel_pod_policy_documents = concat([
    {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "MutatingPolicy"
      metadata   = { name = "pf-pod-policies", labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy        = "Ignore"
        webhookConfiguration = { timeoutSeconds = 30 }
        reinvocationPolicy   = "IfNeeded"
        evaluation           = { background = { enabled = false } }
        matchConstraints = {
          resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["pods"] }]
        }
        mutations = local.cel_pod_mutations
      }
    },
    {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "MutatingPolicy"
      metadata   = { name = "pf-pod-linkerd-availability", labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy        = "Ignore"
        webhookConfiguration = { timeoutSeconds = 30 }
        evaluation           = { background = { enabled = false } }
        matchConstraints     = { resourceRules = local.cel_create_pod_rules }
        mutations = [{
          patchType = "JSONPatch"
          jsonPatch = {
            expression = <<-CEL
              cel.bind(destination, globalContext.Get("linkerd-destination-count", ""),
                cel.bind(identity, globalContext.Get("linkerd-identity-count", ""),
                  destination == null || identity == null || (size(destination.items) > 0 && size(identity.items) > 0) ? [] :
                    [has(object.metadata.annotations) ?
                      JSONPatch{op: "add", path: "/metadata/annotations/linkerd.io~1inject", value: "disabled"} :
                      JSONPatch{op: "add", path: "/metadata/annotations", value: {"linkerd.io/inject": "disabled"}}]))
            CEL
          }
        }]
      }
    },
    {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "MutatingPolicy"
      metadata   = { name = "pf-cilium-test-daemonset", labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy = "Ignore"
        evaluation    = { background = { enabled = false } }
        matchConstraints = {
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.cilium_test_namespace } }
          resourceRules     = [{ apiGroups = ["apps"], apiVersions = ["v1"], operations = ["CREATE"], resources = ["daemonsets"] }]
        }
        mutations = [{
          patchType = "JSONPatch"
          jsonPatch = {
            expression = <<-CEL
              cel.bind(keys, ${jsonencode(local.cel_cilium_tolerations)}, [
                JSONPatch{op: "add", path: "/spec/template/spec/tolerations", value:
                  dyn(object.spec.template.spec.?tolerations.orValue([])) +
                    keys.map(k, {"key": k, "operator": "Equal", "value": "true", "effect": "NoSchedule"})}
              ] + (has(object.metadata.labels) ? [] : [JSONPatch{op: "add", path: "/metadata/labels", value: {}}]) +
                keys.map(k, JSONPatch{op: "add", path: "/metadata/labels/" +
                  jsonpatch.escapeKey("panfactum.com/" + k + "-enabled"), value: "true"}))
            CEL
          }
        }]
      }
    },
    {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "MutatingPolicy"
      metadata   = { name = "pf-cilium-test-namespace-ttl", labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy = "Ignore"
        evaluation    = { mutateExisting = { enabled = true } }
        matchConstraints = {
          resourceRules = [merge(local.cel_cilium_namespace_rule, { operations = ["CREATE"] })]
        }
        mutations = [{
          patchType = "JSONPatch"
          jsonPatch = {
            expression = <<-CEL
              !has(object.metadata.labels) ?
                [JSONPatch{op: "add", path: "/metadata/labels", value: {"cleanup.kyverno.io/ttl": "4h"}}] :
                ("cleanup.kyverno.io/ttl" in object.metadata.labels ? [] :
                  [JSONPatch{op: "add", path: "/metadata/labels/cleanup.kyverno.io~1ttl", value: "4h"}])
            CEL
          }
        }]
      }
    },
    {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "GeneratingPolicy"
      metadata   = { name = "pf-cilium-test-pdb", labels = data.pf_kube_labels.labels.labels }
      spec = {
        evaluation = { synchronize = { enabled = true }, generateExisting = { enabled = true } }
        matchConstraints = {
          resourceRules = [merge(local.cel_cilium_namespace_rule, { operations = ["CREATE", "UPDATE", "DELETE"] })]
        }
        generate = [{
          expression = <<-CEL
            generator.Apply(${jsonencode(local.cilium_test_namespace)}, [{
              "apiVersion": dyn("policy/v1"),
              "kind": dyn("PodDisruptionBudget"),
              "metadata": dyn({"name": ${jsonencode(local.cilium_test_namespace)}, "namespace": ${jsonencode(local.cilium_test_namespace)}}),
              "spec": dyn({"minAvailable": dyn(1000), "selector": dyn({
                "matchLabels": {"panfactum.com/descheduler-enabled": "false"}
              })})
            }])
          CEL
        }]
      }
    }
    ], var.panfactum_scheduler_enabled ? [{
      apiVersion = "policies.kyverno.io/v1"
      kind       = "MutatingPolicy"
      metadata   = { name = "pf-pod-panfactum-scheduler", labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy        = "Ignore"
        webhookConfiguration = { timeoutSeconds = 30 }
        evaluation           = { background = { enabled = false } }
        matchConstraints     = { resourceRules = local.cel_create_pod_rules }
        matchConditions = [{
          name       = "scheduler-not-disabled"
          expression = "request.object.metadata.?labels[?'panfactum.com/scheduler-enabled'].orValue('') != 'false'"
        }]
        mutations = [{
          patchType = "JSONPatch"
          jsonPatch = {
            expression = <<-CEL
            cel.bind(schedulers, globalContext.Get("scheduler-pods", ""),
              schedulers != null && size(schedulers.items) > 0 ?
                [JSONPatch{op: "add", path: "/spec/schedulerName", value: "panfactum"}] : [])
          CEL
          }
        }]
      }
  }] : [])
}

resource "kubectl_manifest" "cel_pod_policy" {
  for_each = { for policy in local.cel_pod_policy_documents : policy.metadata.name => policy if var.kyverno_cel_policies_enabled }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.pull_through_cache_binding,
    kubectl_manifest.linkerd_destination_global_context,
    kubectl_manifest.linkerd_identity_global_context,
    kubectl_manifest.scheduler_global_context,
    module.secret_sync
  ]
}

output "kyverno_cel_pod_policy_documents" {
  description = "CEL documents for the core pod and Cilium test policies"
  value       = [for policy in local.cel_pod_policy_documents : policy if var.kyverno_cel_policies_enabled]
}
