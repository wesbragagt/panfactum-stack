// Source contract: Forgejo wesbragagt/rustybouncer d9d985fbdfaa66e8f0ba9e9b54ae31c4758d5fe0.
// One CNPG-managed writable Service avoids static Pod ordinals and follows replacements.
// Replica-only endpoints are deliberately rejected: this binary requires a primary.
locals {
  rustybouncer_poolers = var.pooler_implementation == "rustybouncer" ? local.poolers_to_enable : toset([])
  rustybouncer_config = join("\n", concat(
    [for key, value in merge(var.rustybouncer_config, {
      listen         = "0.0.0.0:5432"
      metrics_listen = "0.0.0.0:9090"
      route_selects  = true
      probe_user     = "rustybouncer_auth"
      probe_database = "app"
      // A single writable service has no replica routing and must never replay queries.
      read_max_attempts = 1
    }) : "${key} = ${jsonencode(value)}"],
    [<<-TOML

      [frontend_tls]
      cert_file = "/tls/server/tls.crt"
      key_file = "/tls/server/tls.key"

      [backend_tls]
      ca_file = "/tls/ca/ca.crt"
      cert_file = "/tls/client/tls.crt"
      key_file = "/tls/client/tls.key"

      [auth_query]
      user = "rustybouncer_auth"
      database = "app"
      query = "SELECT usename, passwd FROM public.rustybouncer_user_search($1)"

      [[nodes]]
      name = "cnpg-primary"
      host = "${local.cluster_name}-rw.${var.pg_cluster_namespace}.svc"
      tls_server_name = "${local.cluster_name}-rw.${var.pg_cluster_namespace}.svc"
      port = 5432
    TOML
    ]
  ))

  // A separate psql container verifies the actual frontend, SCRAM credentials,
  // TLS hostname/CA and SQL routing. Secrets are reread on every readiness probe.
  // hostaddr targets this Pod, avoiding circular dependency on Service endpoints.
  rustybouncer_readiness_command = ["/bin/sh", "-ec", <<-SH
    export PGUSER="$(cat /probe-creds/username)"
    export PGPASSWORD="$(cat /probe-creds/password)"
    exec psql -X -w -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' "host=${local.cluster_name}-pooler-rw.${var.pg_cluster_namespace}.svc hostaddr=127.0.0.1 port=5432 dbname=app sslmode=verify-full sslrootcert=/tls/ca/ca.crt connect_timeout=3"
  SH
  ]

  rustybouncer_deployments = { for mode in local.rustybouncer_poolers : mode => {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "${local.cluster_name}-pooler-${mode}"
      namespace = var.pg_cluster_namespace
      labels    = module.util_pooler[mode].labels
      // PEM files and probe credentials are reread on new connections. Panfactum's
      // autoReloadAll controller must not interrupt sessions on Secret rotation.
      annotations = { "reloader.stakater.com/auto" = "false" }
    }
    spec = {
      replicas = var.pg_instances
      selector = { matchLabels = module.util_pooler[mode].match_labels }
      strategy = { type = "RollingUpdate", rollingUpdate = { maxUnavailable = 0, maxSurge = 1 } }
      template = {
        metadata = {
          labels = module.util_pooler[mode].labels
          annotations = {
            "panfactum.com/config-hash"            = sha256(local.rustybouncer_config)
            "linkerd.io/inject"                    = var.linkerd_enabled ? "enabled" : "disabled"
            "config.linkerd.io/skip-inbound-ports" = "5432"
          }
        }
        spec = {
          automountServiceAccountToken  = false
          imagePullSecrets              = [for name in var.rustybouncer_image_pull_secrets : { name = name }]
          schedulerName                 = module.util_pooler[mode].scheduler_name
          priorityClassName             = module.constants.workload_important_priority_class_name
          topologySpreadConstraints     = module.util_pooler[mode].topology_spread_constraints
          tolerations                   = module.util_pooler[mode].tolerations
          affinity                      = module.util_pooler[mode].affinity
          terminationGracePeriodSeconds = 30
          securityContext = {
            runAsNonRoot   = true
            runAsUser      = 10001
            runAsGroup     = 10001
            fsGroup        = 10001
            seccompProfile = { type = "RuntimeDefault" }
          }
          containers = [
            {
              name            = "rustybouncer"
              image           = var.rustybouncer_image
              imagePullPolicy = "IfNotPresent"
              args            = ["/config/rustybouncer.toml"]
              ports           = [{ name = "postgres", containerPort = 5432 }, { name = "metrics", containerPort = 9090 }]
              securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
              // Kubernetes waits for endpoint propagation; source still has no transaction drain.
              lifecycle = { preStop = { sleep = { seconds = 5 } } }
              resources = {
                requests = { cpu = "${var.pgbouncer_minimum_cpu_millicores}m", memory = "${var.pgbouncer_minimum_memory_mb}Mi" }
                limits   = { memory = "${ceil(var.pgbouncer_minimum_memory_mb * 1.2)}Mi" }
              }
              volumeMounts = [
                { name = "config", mountPath = "/config", readOnly = true },
                { name = "server-tls", mountPath = "/tls/server", readOnly = true },
                { name = "client-tls", mountPath = "/tls/client", readOnly = true },
                { name = "backend-ca", mountPath = "/tls/ca", readOnly = true }
              ]
            },
            {
              name            = "sql-readiness"
              image           = var.pg_custom_image != null ? var.pg_custom_image : "${module.pull_through.github_registry}/cloudnative-pg/postgresql:${var.pg_version}"
              command         = ["/bin/sh", "-ec", "exec sleep infinity"]
              securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
              resources       = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "64Mi" } }
              readinessProbe = {
                exec             = { command = local.rustybouncer_readiness_command }
                periodSeconds    = 10
                timeoutSeconds   = 5
                failureThreshold = 2
              }
              volumeMounts = [
                { name = "probe-creds", mountPath = "/probe-creds", readOnly = true },
                { name = "backend-ca", mountPath = "/tls/ca", readOnly = true }
              ]
            }
          ]
          volumes = [
            { name = "config", configMap = { name = "${local.cluster_name}-rustybouncer" } },
            { name = "server-tls", secret = { secretName = module.server_certs.secret_name } },
            { name = "client-tls", secret = { secretName = module.rustybouncer_certs[0].secret_name } },
            // Project only the CA public certificate, never a CA private key.
            { name = "backend-ca", secret = { secretName = module.server_certs.secret_name, items = [{ key = "ca.crt", path = "ca.crt" }] } },
            { name = "probe-creds", secret = { secretName = "${local.cluster_name}-reader-creds", items = [{ key = "username", path = "username" }, { key = "password", path = "password" }] } }
          ]
        }
      }
    }
  } }
}

resource "kubectl_manifest" "rustybouncer_config" {
  count = var.pooler_implementation == "rustybouncer" ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "${local.cluster_name}-rustybouncer", namespace = var.pg_cluster_namespace, labels = module.util_cluster.labels }
    data       = { "rustybouncer.toml" = local.rustybouncer_config }
  })
  force_conflicts   = true
  server_side_apply = true
  lifecycle {
    precondition {
      condition     = var.rustybouncer_image != null
      error_message = "RustyBouncer requires a compatible immutable rustybouncer_image; no public default image exists."
    }
    precondition {
      condition     = !var.pgbouncer_read_only_enabled
      error_message = "RustyBouncer cannot preserve replica-only semantics; set pgbouncer_read_only_enabled=false or retain PgBouncer."
    }
  }
}

resource "kubectl_manifest" "rustybouncer" {
  for_each          = local.rustybouncer_deployments
  yaml_body         = yamlencode(each.value)
  force_conflicts   = true
  server_side_apply = true
  depends_on        = [kubectl_manifest.rustybouncer_config, kubernetes_manifest.postgres_cluster, module.rustybouncer_certs, module.schema_init_job, kubectl_manifest.vault_secrets]
}

resource "kubectl_manifest" "rustybouncer_service" {
  for_each = local.rustybouncer_poolers
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = "${local.cluster_name}-pooler-${each.key}", namespace = var.pg_cluster_namespace, labels = module.util_pooler[each.key].labels }
    spec = {
      selector = module.util_pooler[each.key].match_labels
      ports    = [{ name = "postgres", port = 5432, targetPort = "postgres" }]
    }
  })
  force_conflicts   = true
  server_side_apply = true
  depends_on        = [kubectl_manifest.rustybouncer]
}

resource "kubectl_manifest" "rustybouncer_monitor" {
  for_each = var.monitoring_enabled ? local.rustybouncer_poolers : toset([])
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata   = { name = "${local.cluster_name}-pooler-${each.key}", namespace = var.pg_cluster_namespace, labels = module.util_pooler[each.key].labels }
    spec = {
      selector            = { matchLabels = module.util_pooler[each.key].match_labels }
      namespaceSelector   = { matchNames = [var.pg_cluster_namespace] }
      podMetricsEndpoints = [{ port = "metrics", path = "/metrics" }]
    }
  })
  force_conflicts   = true
  server_side_apply = true
  depends_on        = [kubectl_manifest.rustybouncer]
}

// Independent cert-manager client identity; CNPG Pooler deletion cannot revoke it.
module "rustybouncer_certs" {
  count       = var.pooler_implementation == "rustybouncer" ? 1 : 0
  source      = "../kube_internal_cert"
  secret_name = "${local.cluster_name}-rustybouncer-client"
  namespace   = var.pg_cluster_namespace
  usages      = ["client auth"]
  common_name = "rustybouncer_auth"
}
