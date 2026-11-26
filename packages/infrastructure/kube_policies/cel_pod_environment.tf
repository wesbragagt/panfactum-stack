locals {
  cel_environment_values = {
    "{{ element.image }}"                                            = "c.image"
    "{{ '{{element.image}}' | split(@, ':') | [-1:] | [0] }}"        = "c.image.split(':')[size(c.image.split(':')) - 1]"
    "{{ '{{element.image}}' | split(@, '/') | [1:] | join('/', @)}}" = "c.image.split('/').slice(1, size(c.image.split('/'))).join('/')"
    "{{ '{{element.image}}' | split(@, '/') | [0] }}"                = "c.image.split('/')[0]"
    "{{ termSeconds }}"                                              = "string(object.spec.?terminationGracePeriodSeconds.orValue(30))"
    "{{ request.object.metadata.namespace }}"                        = "request.namespace"
  }

  cel_environment_entries = [
    for name in reverse(distinct([for entry in local.common_env : entry.name])) :
    [
      for entry in local.common_env :
      contains(keys(local.cel_environment_values), try(entry.value, "")) ?
      "dyn({'name': ${jsonencode(entry.name)}, 'value': string(${local.cel_environment_values[entry.value]})})" :
      "json.unmarshal(${jsonencode(jsonencode(entry))})"
      if entry.name == name
    ][0]
  ]

  cel_environment_mutations = [for field in local.cel_pod_fields : {
    patchType = "JSONPatch"
    jsonPatch = {
      expression = <<-CEL
        request.operation != "CREATE" ||
          object.metadata.?labels[?"panfactum.com/inject-env-enabled"].orValue("") == "false" ? [] :
          ${local.cel_containers[field]}.map(c, cel.bind(
            env, c.?env.orValue([]),
            cel.bind(
              nodeOptions, {"name": "NODE_OPTIONS", "value": "--max-old-space-size=" +
                string(int(quantity(c.?resources.?requests[?"memory"].orValue("0")).asApproximateFloat() / 1000000.0))},
              JSONPatch{
                op: "add",
                path: "/spec/${field}/" + string(${local.cel_containers[field]}.indexOf(c)) + "/env",
                value: [${join(",\n        ", local.cel_environment_entries)}]
                  .filter(e, e.name != "NODE_OPTIONS" && !env.exists(old, old.name == e.name)) +
                  (env.exists(e, e.name == "NODE_OPTIONS") ? [] : [nodeOptions]) +
                  dyn(env.map(e, e.name == "NODE_OPTIONS" ? dyn(nodeOptions) : dyn(e)))
              }
            )
          ))
      CEL
    }
  }]
}
