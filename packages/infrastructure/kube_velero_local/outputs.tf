output "backup_bucket" {
  description = "The bucket of the default BackupStorageLocation"
  value       = var.bucket
}

output "backup_prefix" {
  description = "The prefix of the default BackupStorageLocation"
  value       = var.prefix
}
