## Maintenance Notes

PgBouncer remains the default. An experimental standalone RustyBouncer backend
can own the writable pooler endpoint with TLS and Vault dynamic-user authentication.
See [the image contract, limitations and migration guide](./RUSTYBOUNCER.md) before
selecting it; replica-only endpoints and graceful transaction draining are unavailable.
