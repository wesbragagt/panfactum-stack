## Usage

No notes
Pod profiles: opt in with `redaction_profiles_enabled = true` together with
`redaction_enabled = true`. Put `panfactum.com/log-redaction-profile: strict`
(or `standard`) on Deployment/StatefulSet **Pod template** annotations. Service
annotations do not select logs. The central `redaction_profiles` category map adds
only categories absent from the global baseline. Missing, unknown and off-like
values retain the baseline. The temporary whitelisted ordinary routing label is
removed before forwarding. Events always use the global stages, without routing.
Legacy defaults remain disabled; enabling profiles alone does not activate masking.
Strict adds bounded phones and explicit personal fields; generic names and IPs are
preserved. Run tests/redaction_runtime.py and tests/profiles_runtime.py with the
pinned Alloy v1.1.0 ALLOY_BINARY. These demonstrate finite format coverage, not a
compliance guarantee; historical stored logs remain unchanged.
