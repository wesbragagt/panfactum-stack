output "cron_job_name" {
  description = "CronJob used for scheduled and controlled manual snapshot jobs."
  value       = var.name
}
output "namespace" {
  description = "Existing namespace containing the backup CronJob."
  value       = var.namespace
}
output "role_arn" {
  description = "Scoped AWS web-identity role; no credentials are returned."
  value       = module.aws_auth.role_arn
}
output "snapshot_uri_prefix" {
  description = "Protected snapshot destination; no bucket lifecycle or deletion is managed here."
  value       = "s3://${var.s3_bucket}/${local.prefix}/"
}
