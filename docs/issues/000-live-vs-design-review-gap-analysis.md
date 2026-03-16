# Gap Analysis: Why Live Bugs Survived 47 Batches of Design Review + 8 Batches of Code Review

**Date**: 2026-03-16
**Context**: The design review (47 batches, 470 angles, ~100 fixes) and code-only review (8 batches, 80 angles, 6 fixes) both completed successfully. Yet the first live deployment revealed 4 critical issues that prevented the gateway from functioning.

This document analyzes WHY these issues were not caught, what class of defect they represent, and what the review process must improve.

---

## Live Bugs Found

| # | Bug | Severity | Category |
|---|-----|----------|----------|
| 1 | Liveness probe hits auth-proxy (401) → crash loop | Critical | **Build/deploy config vs runtime behavior** |
| 2 | `flock` missing from base image (Dockerfile.base not rebuilt) | Critical | **Build pipeline state vs code state** |
| 3 | `flock` absence silently skips bootstrap (exit code misinterpretation) | Critical | **Defensive coding gap** |
| 4 | Translate bridge reports "ready" before subprocess handles messages | Critical | **External dependency behavioral assumption** |

---

## Why Each Bug Survived Review

### Bug 1: Liveness probe crash loop (401 on auth-proxy /health)

**Design review coverage**: The digest shows R5/Batch 1 (code review) noted: "R5: Liveness probe hits /health on port 8080 (auth-proxy) — Auth proxies typically have built-in health endpoints. Cannot confirm without mcp-auth-proxy source. Will verify in Live mode."

**The review DID flag this** — but classified it as an "observation for live mode" rather than a defect. The code review correctly identified the risk but lacked the ability to verify it without deploying.

**Root cause of gap**: Code-only review can identify WHAT an endpoint does but not HOW an external binary (mcp-auth-proxy) handles unauthenticated requests. The 47-batch design review focused on architecture documents, not runtime config like `--liveness-probe` flags in cloudbuild.yaml.

**Process improvement**: Any health probe pointing at an auth-gated port should be flagged as a PROBABLE defect, not an observation. The default assumption should be "auth proxies block unauthenticated requests" unless proven otherwise.

### Bug 2: Base image not rebuilt after Dockerfile.base changes

**Design review coverage**: Never reviewed. The design review focused on architecture.md and design specs. The code review found the `flock` missing issue in Batch 1 and added `util-linux` to Dockerfile.base. But neither review checked whether the build pipeline would pick up the change.

**Root cause of gap**: The review process treats code changes as the end of the fix. It does not verify that the **build artifact** reflects the code. `Dockerfile.base` is a two-stage build — changes to it require a separate base image rebuild that is NOT triggered by the CI/CD pipeline (no trigger exists for base images).

**Process improvement**: Any fix to `Dockerfile.base` must include a checklist item: "base image rebuilt?" The code review's TDD step (write test, fix code, verify) should extend to "verify the fix reaches the deployed artifact."

### Bug 3: flock absence silently interpreted as "lock held"

**Design review coverage**: Never reviewed. The design review didn't examine shell error code semantics at this level.

**Code review coverage**: Batch 1 found that flock was missing and added `util-linux`. But it did NOT trace what happens when `flock` is absent — it assumed the fix (installing util-linux) was sufficient. The code-only review verified the Dockerfile had the package, not what happens if the package is somehow missing at runtime.

**Root cause of gap**: The code review tested the POSITIVE path (flock installed → works) but not the NEGATIVE path (flock missing → what happens?). The `if ! flock -n 9` pattern is a classic shell trap: command-not-found (exit 127) is indistinguishable from "lock held" (exit 1) through the `!` operator. This is a defensive coding gap that should have been caught by an adversarial review angle like "what if util-linux isn't installed despite being in Dockerfile?"

**Process improvement**: For every fix that adds a dependency, also add a graceful degradation path. The code review should include an angle: "what if this fix is partially applied?"

### Bug 4: Translate bridge readiness gap (ConnectionResetError)

**Design review coverage**: The design documents describe the translate bridge as a component but don't detail its readiness semantics. The 47-batch design review treated the translate bridge as a black box with correct behavior.

**Code review coverage**: The code review verified:
- SSE probe patterns (Batch 1: fixed curl -sf to accept exit 28)
- PID file races (Batch 4: verified no race between entrypoint and bootstrap)
- Bootstrap wait loops (multiple batches: verified timeout math)

But it never questioned: **"does the SSE endpoint being 'up' mean the subprocess is 'ready'?"** This is an ASSUMPTION about external code behavior, not verifiable from our codebase.

**Root cause of gap**: The translate bridge (`mcpgateway.translate`) is external code from IBM ContextForge. Its internal behavior — specifically, that it reports HTTP server readiness before subprocess readiness — is not documented and not inferrable from our code. The code review explicitly noted this limitation: "Cannot confirm without mcp-auth-proxy source" (R5/Batch 1).

**Process improvement**: For every external dependency, document its **behavioral contract** — what does "ready" actually mean? For the translate bridge, "ready" means "HTTP server listening" not "subprocess handling messages." This distinction must be in the architecture docs.

---

## Pattern Analysis

| Gap Type | Bugs | Can Code Review Catch? | Can Design Review Catch? | What Can Catch It? |
|----------|------|----------------------|------------------------|--------------------|
| Runtime behavior of external binary | #1, #4 | No — black box | Partially — if behavioral contract documented | **Live testing** |
| Build pipeline state divergence | #2 | No — outside code scope | No — outside doc scope | **CI/CD validation** |
| Defensive coding (negative path) | #3 | Yes — adversarial angle | No | **Code review with adversarial angles** |

**Key finding**: 3 out of 4 bugs are in the **gap between code and runtime** — the space where code is correct but deployment, external dependencies, or build pipelines introduce failures. Code-only review cannot reach this space. Design review CAN partially reach it if behavioral contracts are documented.

---

## Recommendations

### For the Review Process

1. **Add "deployment path" as a mandatory review angle** — does the fix reach the running container? Is there a build step between code and deployment?
2. **Add "external dependency behavioral contract" as a review category** — for every external binary/library, document: what does "healthy" mean? What does "ready" mean? What happens on failure?
3. **Add "negative path for every fix" as a review principle** — for every fix that adds a dependency or changes a check, ask: "what if this fix is only partially applied?"

### For the Architecture

1. **Document behavioral contracts** for: mcp-auth-proxy, mcpgateway.translate, Apollo MCP Server, ContextForge gateway API
2. **Add base image rebuild to CI/CD** — either automatic trigger or mandatory checklist item
3. **Replace assumptions with probes** — don't assume "SSE up = ready." Probe the actual capability (MCP initialize handshake) before depending on it.

---

## Verdict

The 47-batch design review and 8-batch code review were thorough for their respective domains. The live bugs exist in a third domain — **runtime integration** — that neither review type can fully reach. This is not a failure of the review process; it's a known limitation that Live Mode testing is designed to address. However, the review process CAN be improved to catch Bug #3 (defensive coding) and partially catch Bug #1 (auth-gated health probes should be flagged as probable defects).
