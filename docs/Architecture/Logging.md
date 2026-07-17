# Logging Policy

Applies to all logging, diagnostics, crash reports, and any future MetricKit payload in
ADBLX — with no exception for debug builds.

## Allowed

- Counts (e.g. rules loaded, duplicates removed, unsupported-rule count)
- Durations (e.g. compile time, reload time)
- Sizes (e.g. memory estimate in bytes, file size)
- Versions (e.g. filter version string, manifest version)
- Checksums (e.g. SHA-256 hex digest)

## Forbidden

- URLs
- Domains
- Hostnames
- Rule text / rule bodies
- Cookies
- Headers
- Query strings

If you're tempted to log "which rules were unsupported," log the *count* of unsupported rules,
never their content. `RuleStatistics` (`ADBLX/Filtering/Models/RuleStatistics.swift`) is the
canonical example of a type that only ever holds allowed fields — use it as the template for
any future diagnostics type.
