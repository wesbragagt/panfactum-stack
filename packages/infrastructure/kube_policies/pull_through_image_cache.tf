locals {
  pull_through_cache_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
  registry_replacements = [
    { host = "ghcr.io", prefix = "github" },
    { host = "cr.l5d.io", prefix = "github" }, // Linkerd also hosts their images on GitHub
    { host = "docker.io", prefix = "docker-hub" },
    { host = "index.docker.io", prefix = "docker-hub" },
    { host = "quay.io", prefix = "quay" },
    { host = "registry.k8s.io", prefix = "kubernetes" },
    { host = "public.ecr.aws", prefix = "ecr-public" }
  ]
  exclude_pull_through_cache = {
    any = [
      {
        resources = {
          selector = {
            matchLabels = {
              "panfactum.com/pull-through-cache-enabled" = "false"
            }
          }
        }
      }
    ]
  }

  rule_use_pull_through_image_cache = var.pull_through_cache_enabled ? [
    for field in ["containers", "initContainers"] : {
      name    = field == "containers" ? "update-containers" : "update-init-containers"
      match   = local.match_any_pod_create
      exclude = local.exclude_pull_through_cache
      preconditions = {
        all = [{
          key      = "{{ request.object.spec.${field}[].image || `[]` }}"
          operator = "AnyNotIn"
          value    = ["${local.pull_through_cache_registry}/*"]
        }]
      }
      mutate = {
        // Keep the list unfiltered so elementIndex matches the original Pod array.
        foreach = concat([for config in local.registry_replacements : {
          list = "request.object.spec.${field}"
          preconditions = {
            all = [{
              key      = "{{ element.image }}"
              operator = "Equals"
              value    = "${config.host}/*"
            }]
          }
          patchesJson6902 = yamlencode([{
            op    = "replace"
            path  = "/spec/${field}/{{elementIndex}}/image"
            value = "${local.pull_through_cache_registry}/${config.prefix}/{{ trim_prefix(element.image, '${config.host}/') }}"
          }])
          }], [{
          list = "request.object.spec.${field}"
          preconditions = {
            all = [{
              key      = "{{ contains(element.image, ':') && !contains(split(element.image, ':')[0], '.') }}"
              operator = "Equals"
              value    = true
            }]
          }
          patchesJson6902 = yamlencode([{
            op    = "replace"
            path  = "/spec/${field}/{{elementIndex}}/image"
            value = "${local.pull_through_cache_registry}/docker-hub/{{ element.image }}"
          }])
        }])
      }
    }
  ] : [null, null]
}
