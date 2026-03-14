# Failure Log

> Record design and implementation failures here. Future agents learn from these. Each entry must include root cause analysis and a concrete lesson.

---

## 2026-03-14: Missing User Identity in MCP Gateway Design

- **What happened**: Designed an entire MCP gateway with OAuth 2.1, RS256 JWT, tool aggregation, structured logging — but no concept of user identity. The system couldn't tell humans apart. Logs showed "api_key_hash:abc123" instead of "junlin."
- **Root cause**: Anchored on the current architecture (which has no identity) and improved the plumbing instead of fixing the foundation. Confused better crypto for better security. The agent read the existing `oauth-server/server.js` and designed "a better version of the same broken thing."
- **What was missed**: The Security Fundamentals Checklist — specifically Identity, Authorization, Revocation, and Least Privilege. All four were absent from the design.
- **How it should have been caught**: The user said "I want admin to talk to every detail" and "who accessed my store" — both require identity. The agent should have flagged identity as prerequisite before designing anything else. The 5 WHYs (WHO is this for?) would have caught it immediately.
- **What changed**: Added Module 0: IAM to the spec. Per-user API keys, per-user passphrases, role-based tool filtering. Identity baked into Phase 1, not bolted on later.
- **Lesson**: Identity is not a feature. It is the foundation. Everything else (logging, admin tools, security audit) is useless without it. When designing security, answer WHO before HOW.

## 2026-03-14: Static Agent Instructions

- **What happened**: Created `introspect.md` as a static instruction document. It told agents how to think but didn't tell them to update the document itself when they learned something. No mechanism for storing reflections, recording insights, or improving the process.
- **Root cause**: Treated the introspection protocol as a one-time deliverable instead of a living system. Designed instructions for agents but not a feedback loop.
- **How it should have been caught**: The user asked a simple question: "does your behaviour md teach the agent how to reiterate reflect and store reflection?" The answer was no.
- **What changed**: Rewrote introspect.md with the Self-Improvement Rule, Reflection Loop, and supporting files (failure-log.md, insights.md, patterns.md). Agents must now read AND write to these files.
- **Lesson**: Instructions without feedback loops are dead documents. Every system that teaches must also learn. If agents can't update their own instructions, the instructions will become outdated and wrong.
