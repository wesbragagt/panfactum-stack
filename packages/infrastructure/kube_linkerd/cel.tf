// Opt-in CEL equivalents for the legacy Kyverno rules. Keep the legacy branch
// available until every consuming cluster has reviewed its replacement plan.
locals {
  cel_pod_rules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["pods", "pods/status"] }]
  cel_cni_container = {
    name    = "remove-taint"
    image   = coalesce(var.cni_remove_taint_image, "${module.aws_pull_through.docker_hub_registry}/bitnamilegacy/kubectl:${data.kubectl_server_version.version.major}.${data.kubectl_server_version.version.minor}")
    command = ["bash", "-c", "sleep 10; while true; do kubectl taint nodes \"$NODE_NAME\" panfactum.com/linkerd-not-ready- || true; sleep 300; done"]
    env     = [{ name = "NODE_NAME", valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } }]
    securityContext = {
      runAsGroup             = 1000, runAsUser = 1000, allowPrivilegeEscalation = false,
      readOnlyRootFilesystem = true, privileged = false, capabilities = { drop = ["ALL"] }
    }
    resources = { requests = { cpu = "2m", memory = "4Mi" }, limits = { memory = "64Mi" } }
  }
  cel_cni_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "linkerd-cni", labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy = "Ignore"
      evaluation    = { admission = { enabled = true }, background = { enabled = false } }
      matchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.namespace } }
        resourceRules     = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["pods"] }]
      }
      matchConditions = [{
        name = "cni-pod"
        # Controllers submit generateName before the API server assigns a name.
        expression = "(has(object.metadata.name) && object.metadata.name.startsWith('linkerd-cni-')) || (has(object.metadata.generateName) && object.metadata.generateName.startsWith('linkerd-cni-'))"
      }]
      variables = [{ name = "taintHelper", expression = "json.unmarshal(${jsonencode(jsonencode(local.cel_cni_container))})" }]
      mutations = [{ patchType = "JSONPatch", jsonPatch = {
        expression = "[JSONPatch{op:'add',path:'/spec/hostNetwork',value:true}] + (object.spec.containers.exists(c,c.name=='remove-taint') ? [] : [JSONPatch{op:'add',path:'/spec/containers/-',value:variables.taintHelper}])"
      } }]
    }
  }
  cel_cni_ds_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "linkerd-cni-ds", labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy = "Ignore"
      evaluation    = { admission = { enabled = true }, mutateExisting = { enabled = true } }
      matchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.namespace } }
        resourceRules     = [{ apiGroups = ["apps"], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["daemonsets"], resourceNames = ["linkerd-cni"] }]
      }
      mutations = [{ patchType = "JSONPatch", jsonPatch = {
        expression = "[JSONPatch{op:'add',path:'/spec/updateStrategy',value:json.unmarshal('{\"type\":\"RollingUpdate\",\"rollingUpdate\":{\"maxUnavailable\":\"34%\"}}')}]"
      } }]
    }
  }
  cel_pod_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "linkerd-rules", labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy    = "Ignore"
      evaluation       = { background = { enabled = false } }
      matchConstraints = { resourceRules = local.cel_pod_rules }
      variables        = [{ name = "grace", expression = "string((has(object.spec.terminationGracePeriodSeconds) ? object.spec.terminationGracePeriodSeconds : 30) > 0 ? (has(object.spec.terminationGracePeriodSeconds) ? object.spec.terminationGracePeriodSeconds : 30) - 1 : 0) + 's'" }]
      mutations = [
        { patchType = "JSONPatch", jsonPatch = {
          expression = "has(object.spec.initContainers) && (!has(object.status) || !has(object.status.phase) || object.status.phase=='Pending') ? [JSONPatch{op:'replace',path:'/spec/initContainers',value:object.spec.initContainers.filter(c,c.name!='linkerd-network-validator')}] : []"
        } },
        { patchType = "JSONPatch", jsonPatch = {
          expression = "request.operation!='CREATE' ? [] : !has(object.metadata.annotations) ? [JSONPatch{op:'add',path:'/metadata/annotations',value:{'config.linkerd.io/shutdown-grace-period':variables.grace}}] : !('config.linkerd.io/shutdown-grace-period' in object.metadata.annotations) ? [JSONPatch{op:'add',path:'/metadata/annotations/config.linkerd.io~1shutdown-grace-period',value:variables.grace}] : []"
        } },
      ]
    }
  }
  cel_taint_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "linkerd-taint-cleanup", labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy    = "Ignore"
      evaluation       = { mutateExisting = { enabled = true } }
      matchConstraints = { resourceRules = local.cel_pod_rules, namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.namespace } } }
      matchConditions  = [{ name = "running-cni", expression = "object.metadata.name.startsWith('linkerd-cni-') && has(object.status) && has(object.status.phase) && object.status.phase=='Running' && has(object.spec.nodeName)" }]
      variables        = [{ name = "targetNode", expression = "request.object.spec.nodeName" }]
      targetMatchConstraints = {
        resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["*"], resources = ["nodes"] }]
        expression    = "resource.Get('v1', 'nodes', '', variables.targetNode)"
      }
      mutations = [{ patchType = "JSONPatch", jsonPatch = {
        expression = "object.metadata.name==variables.targetNode && has(object.spec.taints) ? [JSONPatch{op:'replace',path:'/spec/taints',value:object.spec.taints.filter(t,t.key!='panfactum.com/linkerd-not-ready')}] : []"
      } }]
    }
  }
}

resource "kubectl_manifest" "cel_taint_cleanup" {
  count             = var.kyverno_cel_policies_enabled ? 1 : 0
  yaml_body         = yamlencode(local.cel_taint_policy)
  server_side_apply = true
  force_conflicts   = true
}
