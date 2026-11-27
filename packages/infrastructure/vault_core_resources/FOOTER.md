## Usage

No notes
Self-managed clusters can explicitly set aws_secrets_use_workload_identity=true to use the Vault pod SDK web identity and attach scoped vault-* user management permissions to its existing role. This creates no bootstrap IAM user/access key. The default remains the existing static-root-credential path, with moved blocks preserving addresses. This is AWS SDK credential sourcing supported by the pinned open-source Vault version, not Enterprise plugin WIF.
