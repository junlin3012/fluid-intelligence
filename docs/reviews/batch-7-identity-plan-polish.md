# Mirror Polish Batch 7 — Identity RBAC Plan

**Date**: 2026-03-17
**Target**: `docs/superpowers/plans/2026-03-17-identity-rbac.md`
**Mode**: Code-only
**Clean batch counter**: 0/3 (reset — 1 fix)

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R61 | Concurrent instances during deploy (flock + 409) | CLEAN |
| R62 | ContextForge DB migration (env vars only, no schema) | CLEAN |
| R63 | `@` in URL path (RFC 3986 allows in pchar) | CLEAN |
| R64 | Working directory between tasks (Task 6 has explicit cd) | CLEAN |
| R65 | Lightweight vs annotated tag (gh release accepts both) | CLEAN |
| R66 | Forked binary checksum (plan handles with placeholder) | CLEAN |
| R67 | Missing secrets (none needed) | CLEAN |
| R68 | Error propagation under pipefail (all guarded) | CLEAN |
| R69 | Plan title says "RBAC" but only setup, not enforcement | ISSUE FOUND |
| R70 | Fork repo visibility (public fork of public repo) | CLEAN |

## Fixes Applied

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R69 | Low | Goal says "RBAC controlling tool access" but only setup is implemented | Changed goal to clarify "RBAC infrastructure set up (enforcement via per-team virtual servers is a follow-up)" |

## Cumulative

| Batch | Fixes | Clean? |
|-------|-------|--------|
| Pre | 5 | — |
| 1 | 3 | No |
| 2 | 7 | No |
| 3 | 4 | No |
| 4 | 1 | No |
| 5 | 1 | No |
| 6 | 0 | **YES** |
| 7 | 1 | No |

**Fix trend: 5→3→7→4→1→1→0→1**
**Clean batch counter: 0/3 (reset)**
