moved {
  from = vault_identity_oidc_key.argo
  to   = vault_identity_oidc_key.argo[0]
}

moved {
  from = vault_identity_oidc_assignment.argo
  to   = vault_identity_oidc_assignment.argo[0]
}

moved {
  from = vault_identity_oidc_client.argo
  to   = vault_identity_oidc_client.argo[0]
}

moved {
  from = vault_identity_oidc_scope.groups
  to   = vault_identity_oidc_scope.groups[0]
}

moved {
  from = vault_identity_oidc_provider.argo
  to   = vault_identity_oidc_provider.argo[0]
}

moved {
  from = kubernetes_secret.sso_info
  to   = kubernetes_secret.sso_info[0]
}

moved {
  from = helm_release.argo_events
  to   = helm_release.argo_events[0]
}

moved {
  from = kubectl_manifest.pdb_events_controller
  to   = kubectl_manifest.pdb_events_controller[0]
}

moved {
  from = kubectl_manifest.pdb_webhook
  to   = kubectl_manifest.pdb_webhook[0]
}

moved {
  from = kubernetes_cluster_role_binding.superuser_events_binding
  to   = kubernetes_cluster_role_binding.superuser_events_binding[0]
}

moved {
  from = kubernetes_cluster_role_binding.admin_events_binding
  to   = kubernetes_cluster_role_binding.admin_events_binding[0]
}

moved {
  from = kubernetes_cluster_role_binding.reader_events_binding
  to   = kubernetes_cluster_role_binding.reader_events_binding[0]
}
