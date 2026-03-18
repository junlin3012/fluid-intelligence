# Mirror Polish Batch 1 — Deployment Infrastructure

**Date**: 2026-03-18
**Target**: Deployment infrastructure (Dockerfiles, entrypoint.sh, cloudbuild.yaml, defaults.env, validate-config.sh)
**Mode**: Code-only verification
**Method**: Brainstorming + Parallel Agents + Systematic Debugging + Verification
**Clean batch counter**: 0/6

## Review Dimensions (10 rounds)

| Round | Dimension | Status |
|-------|-----------|--------|
| R1 | SHA256 hash integrity — Dockerfile.base auth-proxy check | ISSUE FOUND |
| R2 | crypto.py dependency availability in container | ISSUE FOUND (defense-in-depth fix) |
| R3 | env var flow: defaults.env → entrypoint.sh → cloudbuild.yaml consistency | CLEAN |
| R4 | validate-config.sh coverage — DEVMCP_VERSION/SHEETS_VERSION | CLEAN (false positive — defaults.env provides values) |
| R5 | SIGTERM/cleanup race — PIDS array rebuild non-atomic | ISSUE FOUND |
| R6 | start_and_verify signal masking — `wait` not interrupted by SIGTERM | CLEAN (minor, extremely low severity on Cloud Run) |
| R7 | Dockerfile layer ordering — RUN chmod/chown cache invalidation | CLEAN (technically correct but 5s builds make it immaterial) |
| R8 | Startup probe math — comment accuracy + liveness probe port | ISSUE FOUND (comment wrong; liveness probe is correct — Cloud Run probes are container-internal) |
| R9 | URL-encoding — bare `python3` instead of venv python | ISSUE FOUND |
| R10 | Shopify token retry loop structure | CLEAN |

## Fixes Applied (5 issues)

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R1 | Critical | SHA256 hash missing for mcp-auth-proxy binary in Dockerfile.base:27 — integrity check was `echo "  /mcp-auth-proxy"` with no hash | Downloaded binary, computed hash `03ce8538...`, added to Dockerfile.base | `curl -sL <url> \| sha256sum` confirms hash matches |
| R2 | Medium | crypto.py imports `cryptography.hazmat.primitives.ciphers.aead.AESGCM` — may not be in container venv | Added build-time verification to Dockerfile.base: `python -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM"` | Will fail at build time if missing, preventing silent runtime failure |
| R5 | Medium | PIDS array rebuild (lines 324-326) is non-atomic — SIGTERM during rebuild corrupts array | Wrapped rebuild in `trap '' SIGTERM SIGINT` / `trap cleanup SIGTERM SIGINT` to disable signals during the 3-statement operation | Code inspection confirms signals masked during critical section |
| R8 | Low | Comment on line 268 says "~115s already elapsed" — actual elapsed time is ~15-20s based on system-understanding.md timing | Corrected comment to "~15-20s already elapsed" with accurate probe budget math | Cross-referenced with system-understanding.md startup timeline |
| R9 | Medium | Line 90 uses bare `python3` for URL-encoding — UBI Minimal may not have system python3 | Changed to `/app/.venv/bin/python3` (consistent with lines 111, 221, 232, 242) + added stderr capture | Consistent with all other python invocations in the script |

## Additional Fix (Pre-identified)

| Source | Severity | Issue | Fix |
|--------|----------|-------|-----|
| Pre-id #2 | Critical | patterns.md:57 says "SSE for all backends" but Apollo uses STREAMABLEHTTP | Corrected to document actual transports: STREAMABLEHTTP for Apollo, SSE for bridges |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R4: DEVMCP_VERSION/SHEETS_VERSION not in validate-config.sh | NOT a bug — defaults.env provides fallback values `1.7.1`/`0.6.0` via conditional assignment |
| R6: `sleep 2 & wait $!` blocks during SIGTERM | Theoretically interruptible only after sleep completes, but SIGTERM during 2s startup window is vanishingly rare on Cloud Run |
| R7: RUN chmod/chown invalidates all preceding COPY layers | Technically correct but immaterial — thin Dockerfile builds in ~5s regardless |
| R8: Liveness probe on port 4444 | CORRECT — Cloud Run probes are container-internal, not external. Port 4444 (ContextForge) IS reachable |
| R10: `sed '$d'` for HTTP code parsing | Works correctly for standard curl output format; minor fragility but not a bug |

## Key Decisions & Rationale

- **R1 hash computation**: Downloaded the actual binary from GitHub releases to compute the SHA256 rather than guessing or hardcoding a placeholder. This is the only reliable way to get the correct hash.
- **R2 defense-in-depth**: Even if `cryptography` is a transitive dependency of ContextForge, adding an explicit build-time check ensures the Dockerfile fails fast if a future ContextForge update drops the dependency.
- **R5 trap disable**: Using `trap '' SIGTERM` during the array rebuild is the standard bash idiom for atomic-like critical sections. The window is microseconds.
- **R8 false positive**: Agent incorrectly claimed port 4444 is unreachable by liveness probes. Cloud Run probes execute inside the container's network namespace — all ports are reachable. The system-understanding.md statement about "internal only" refers to internet exposure, not probe reachability.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 6 | No | SHA256 hash missing (security), bare python3 (reliability), PIDS race (signal safety) |

**Clean batch counter: 0/6**
**Accumulated verified-clean dimensions: R3 (env var flow), R4 (validate-config coverage), R6 (signal masking), R7 (layer ordering), R8-liveness (probe port), R10 (retry loop)**
