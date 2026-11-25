moved {
  from = kubernetes_namespace.main
  to   = kubernetes_namespace_v1.main
}

moved {
  from = kubernetes_role.admins
  to   = kubernetes_role_v1.admins
}

moved {
  from = kubernetes_role.readers
  to   = kubernetes_role_v1.readers
}

moved {
  from = kubernetes_role_binding.admins
  to   = kubernetes_role_binding_v1.admins
}

moved {
  from = kubernetes_role_binding.readers
  to   = kubernetes_role_binding_v1.readers
}
