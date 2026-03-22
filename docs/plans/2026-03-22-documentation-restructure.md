# Documentation & Project Restructure — Implementation Plan

> **For agentic workers:** Execute tasks serially. Each task depends on the previous.

**Goal:** Restructure repo from v3 monolith layout to v6 multi-service layout with comprehensive documentation.

**Architecture:** Move service files from worktree to main under `services/`, archive stale docs, write 4 new doc files.

**Spec:** `docs/specs/2026-03-22-documentation-restructure.md`

---

## Phase 1: Project Structure (file moves)

### Task 1: Create services/ directory and move worktree files

**Files:**
- Create: `services/contextforge/db/init.sql`
- Create: `services/keycloak/` (from worktree `keycloak/`)
- Create: `services/keycloak/db/init.sql`
- Create: `services/apollo/` (from worktree `sidecars/apollo/`)
- Create: `services/devmcp/` (from worktree `sidecars/devmcp/`)
- Create: `services/sheets/` (from worktree `sidecars/sheets/`)

Steps:
- [ ] Create `services/` directory structure
- [ ] Split `scripts/init-postgres.sql` into two files:
  - `services/contextforge/db/init.sql` (contextforge DB + user only)
  - `services/keycloak/db/init.sql` (keycloak DB + user only)
- [ ] Copy service files from worktree:
  - `keycloak/` → `services/keycloak/` (Dockerfile, .dockerignore, realm-fluid.json)
  - `sidecars/apollo/` → `services/apollo/` (Dockerfile, .dockerignore, config.yaml, shopify-schema.graphql)
  - `sidecars/devmcp/` → `services/devmcp/` (Dockerfile, .dockerignore, package.json, package-lock.json)
  - `sidecars/sheets/` → `services/sheets/` (Dockerfile, .dockerignore, requirements.txt)
- [ ] Move tests: `tests/keycloak/` → `services/keycloak/tests/`
- [ ] Move postman: `postman/` → `.postman/`
- [ ] Commit: `chore: restructure to services/ layout`

### Task 2: Update docker-compose.yml

**Files:**
- Modify: `docker-compose.yml`
- Create: `.env.example`

Steps:
- [ ] Replace v3 docker-compose with v6 version from worktree
- [ ] Update build context paths: `./keycloak` → `./services/keycloak`, `./sidecars/apollo` → `./services/apollo`, etc.
- [ ] Update volume mounts for split init SQL files
- [ ] Copy `.env.example` from worktree, update paths
- [ ] Verify: `docker compose config` passes (syntax check, no build)
- [ ] Commit: `chore: update docker-compose for services/ layout`

### Task 3: Archive remaining stale docs

**Files:**
- Move: `docs/agent-behavior/system-understanding.md` → `docs/archive/v3/`
- Move: `docs/agent-behavior/patterns.md` → `docs/archive/v3/`
- Move: `docs/plans/` → `docs/archive/plans/`

Steps:
- [ ] Move stale agent-behavior docs to archive
- [ ] Move plans to archive
- [ ] Commit: `chore: archive stale v3 docs`

---

## Phase 2: Write New Documentation

### Task 4: Write docs/architecture.md

**Files:**
- Create: `docs/architecture.md`

Content outline (~300 lines):
- [ ] System Topology — 5 Cloud Run services + Cloud SQL, connection diagram
- [ ] Auth Flow — Keycloak SSO via Google/Microsoft, browser flow
- [ ] Service Details — per-service: purpose, image, URL, key config, custom code
- [ ] Inter-Service Communication — registration, JWKS, FORWARDED_ALLOW_IPS
- [ ] Custom Code Inventory — per-service file list with purpose
- [ ] Commit: `docs: architecture.md — v6 system overview`

### Task 5: Write docs/config-reference.md

**Files:**
- Create: `docs/config-reference.md`

Steps:
- [ ] Read all env vars from Cloud Run: `gcloud run services describe <service> --format=yaml(spec.template.spec.containers[0].env)`
- [ ] Document per-service: contextforge (25+ vars), keycloak (7 vars), apollo (5 vars), devmcp (1 var), sheets (1 var)
- [ ] Include columns: Name, Value/Default, Source, Description, Dangerous?
- [ ] Highlight dangerous settings (from v6 spec "Env Vars That Sound Harmless But Are Dangerous")
- [ ] Commit: `docs: config-reference.md — all env vars across 5 services`

### Task 6: Write docs/known-gotchas.md

**Files:**
- Create: `docs/known-gotchas.md`
- Move: `docs/agent-behavior/failure-log.md` raw entries → `docs/archive/failure-log-raw.md`
- Move: `docs/agent-behavior/insights.md` raw entries → `docs/archive/insights-raw.md`
- Rewrite: `docs/agent-behavior/failure-log.md` (distilled rules only)
- Rewrite: `docs/agent-behavior/insights.md` (distilled rules only)

Steps:
- [ ] Distill all failure-log entries into one-liner rules with brief context
- [ ] Distill all insights entries into reusable patterns
- [ ] Archive raw narrative versions
- [ ] Write known-gotchas.md with distilled rules organized by category:
  - Cloud Run gotchas
  - Keycloak/SSO gotchas
  - Apollo gotchas
  - ContextForge gotchas
  - Database gotchas
- [ ] Rewrite failure-log.md as distilled rules (keep append-only format)
- [ ] Rewrite insights.md as distilled patterns
- [ ] Commit: `docs: known-gotchas.md + distill failure-log and insights`

### Task 7: Write docs/contributing.md

**Files:**
- Create: `docs/contributing.md`

Steps:
- [ ] Write "Add a New MCP Backend" guide (Dockerfile → build → deploy → register)
- [ ] Write "Deploy a New Version" per-service commands
- [ ] Write "Rotate Secrets" guide (which secrets, where, how)
- [ ] Write "Troubleshoot SSO" guide (common errors from this session)
- [ ] Commit: `docs: contributing.md — operational guides`

---

## Phase 3: Update Root Files

### Task 8: Rewrite README.md

**Files:**
- Modify: `README.md`

Steps:
- [ ] Replace v3 architecture diagram with v6 (5 separate services)
- [ ] Update project structure to match new layout
- [ ] Update quickstart for docker-compose with services/ paths
- [ ] Link to docs/architecture.md for details
- [ ] Commit: `docs: rewrite README for v6 architecture`

### Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

Steps:
- [ ] Update project structure section
- [ ] Update required reading list (architecture.md replaces system-understanding.md)
- [ ] Update project context (Cloud Run URLs, architecture description)
- [ ] Remove references to deleted files
- [ ] Commit: `docs: update CLAUDE.md for v6`

### Task 10: Copy v6 spec from worktree

**Files:**
- Copy: worktree `docs/specs/2026-03-21-fluid-intelligence-v6-design.md` → main `docs/specs/`

Steps:
- [ ] Copy v6 design spec to main branch
- [ ] Commit: `docs: add v6 design spec`

---

## Phase 4: Cleanup

### Task 11: Final cleanup and verification

Steps:
- [ ] Remove empty directories left by moves
- [ ] Update `.gitignore` if needed
- [ ] Verify all doc cross-references resolve (no broken links)
- [ ] Run `find docs/ -name "*.md" | xargs grep -l "deploy/\|scripts/\|config/\|entrypoint\|mcp-auth-proxy\|bootstrap.sh"` — should return 0 results outside archive/
- [ ] Verify docker-compose.yml syntax: `docker compose config`
- [ ] Commit: `chore: final cleanup — verify no stale references`
