locals {
  native_pull_through_cache_enabled = var.pull_through_cache_enabled && var.cluster_wide_pull_through_cache_enabled
  pull_through_cache_policy_name    = "pf-pull-through-cache"
  pull_through_cache_image_domain   = "(container.image.contains(\"/\") ? container.image.split(\"/\", 2)[0] : \"\")"
  pull_through_cache_image_prefix   = "variables.registries[?${local.pull_through_cache_image_domain}.lowerAscii()].orValue(\"docker-hub\")"
  pull_through_cache_image_path     = "(${local.pull_through_cache_image_domain}.lowerAscii() in variables.registries ? container.image.split(\"/\", 2)[1] : container.image)"
}

resource "kubectl_manifest" "pull_through_cache_policy" {
  count = local.native_pull_through_cache_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "MutatingAdmissionPolicy"
    metadata   = { name = local.pull_through_cache_policy_name, labels = data.pf_kube_labels.labels.labels }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      matchConstraints = {
        resourceRules = [
          { apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["pods"] },
          { apiGroups = [""], apiVersions = ["v1"], operations = ["UPDATE"], resources = ["pods/ephemeralcontainers"] }
        ]
      }
      # NOTE: Talos runs static pods locally. Rewriting their API mirror would misreport the image in use.
      matchConditions = [{
        name       = "exclude-static-pod-mirrors"
        expression = "!(\"kubernetes.io/config.mirror\" in object.metadata.?annotations.orValue({}))"
      }]
      variables = [{
        name = "registries"
        expression = jsonencode(merge(
          { for registry in local.registry_replacements : registry.host => registry.prefix },
          { "registry-1.docker.io" = "docker-hub", "reg.kyverno.io" = "github" }
        ))
      }]
      mutations = [for field in concat(local.cel_pod_fields, ["ephemeralContainers"]) : {
        patchType = "JSONPatch"
        jsonPatch = {
          # NOTE: Existing ephemeral containers are immutable and can appear at new indexes after an update.
          expression = <<-CEL
            request.operation != "${field == "ephemeralContainers" ? "UPDATE" : "CREATE"}" ? [] :
            object.spec.?${field}.orValue([]).transformList(index, container,
              ${field == "ephemeralContainers" ? "!oldObject.spec.?ephemeralContainers.orValue([]).exists(old, old.name == container.name) &&" : ""}
              container.image != "" &&
              (!container.image.contains("/") ||
               ${local.pull_through_cache_image_domain}.lowerAscii() in variables.registries ||
               ${local.pull_through_cache_image_domain}.matches("^[a-z0-9_-]+$") &&
               ${local.pull_through_cache_image_domain} != "localhost"),
              JSONPatch{
                op: "replace",
                path: "/spec/${field}/" + string(index) + "/image",
                value: ${jsonencode(local.pull_through_cache_registry)} + "/" +
                  ${local.pull_through_cache_image_prefix} + "/" +
                  ((${local.pull_through_cache_image_prefix} == "docker-hub" &&
                    !${local.pull_through_cache_image_path}.contains("/")) ? "library/" : "") + ${local.pull_through_cache_image_path}
              })
          CEL
        }
      }]
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

resource "kubectl_manifest" "pull_through_cache_binding" {
  count = local.native_pull_through_cache_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "MutatingAdmissionPolicyBinding"
    metadata   = { name = local.pull_through_cache_policy_name, labels = data.pf_kube_labels.labels.labels }
    spec       = { policyName = local.pull_through_cache_policy_name }
  })
  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.pull_through_cache_policy]
}
