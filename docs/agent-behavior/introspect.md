# Agent Introspection Protocol

> This is a **living document**. Agents MUST read it before designing, and MUST update it when they learn something new. The document itself should evolve — add new traps, refine checklists, record insights. If you discover a pattern not captured here, add it. If a section is wrong or incomplete, fix it.

---

## The Core Problem

AI agents anchor on existing code. If the current system is missing something fundamental (like user identity), the agent will design "a better version of the same broken thing" instead of asking what's actually needed. This document exists to break that pattern.

---

## Before Designing Anything: The 5 WHYs

Before writing a single line of spec or code, answer these questions **in order**. If you can't answer one, stop and figure it out before proceeding.

1. **WHO** is this system for? Name the actual humans. Not "users" — names.
2. **WHAT** do those humans need to do? Not what the system does — what the humans need.
3. **WHY** does this system exist? What problem would remain unsolved without it?
4. **HOW** will you know it's working? What does success look like to the human, not the engineer?
5. **WHAT COULD GO WRONG** that would make the human say "this is useless"?

Example of getting it wrong:
```
Q: WHO is this for?
A: "MCP clients" ← WRONG. MCP clients are machines. WHO are the humans?
A: "junlin (admin, tanjl0320@gmail.com) and juntan (operator, juntan@deloitte.com)" ← RIGHT.
```

Example of getting it wrong:
```
Q: HOW will you know it's working?
A: "RS256 JWT tokens are correctly signed with kid headers" ← WRONG. That's engineering, not success.
A: "junlin asks Claude 'who accessed my store today?' and gets a list of named users with their actions" ← RIGHT.
```

---

## The Anchoring Trap

**Definition**: When you read existing code before designing, your brain treats the existing approach as the baseline and only makes incremental improvements. You inherit all of the original design's blind spots.

**How to detect it**: After writing your design, ask:
- "If I had never seen the current code, would I design it this way?"
- "What does the current code NOT do that it should?"
- "Am I carrying forward assumptions from the existing implementation?"

**How to break it**:
1. Write down what the system MUST do before reading any code.
2. Read the code only to understand constraints and interfaces.
3. Design from the requirements, not from the existing code.

---

## The Plumbing Trap

**Definition**: Spending design energy on implementation details (RS256 vs HS256, hono vs express, stateless vs stateful) while missing fundamental capabilities (identity, authorization, audit).

**How to detect it**: Count the words in your design. If you wrote more about key rotation than about who the users are, you fell into this trap.

**How to break it**:
1. Design the capabilities first (what the system can do).
2. Design the interfaces second (how users interact with it).
3. Design the implementation last (how it works internally).

---

## The "Magnum Opus" Test

Before calling any design complete, it must pass ALL of these checks:

### Security Fundamentals Checklist
- [ ] **Identity**: Does the system know WHO each user is (by name, not by token hash)?
- [ ] **Authentication**: Can it verify that the person is who they claim to be?
- [ ] **Authorization**: Can it control WHAT each user is allowed to do?
- [ ] **Audit**: Can it answer "who did what, when, from where?" with real names?
- [ ] **Revocation**: Can you cut off ONE user without affecting others?
- [ ] **Least privilege**: Does each user see only what they need?

### User Experience Checklist
- [ ] **The admin question**: Can the admin ask "what happened today?" and get a useful answer with named users and specific actions?
- [ ] **The breach question**: If credentials are compromised, can you identify the scope of damage by user?
- [ ] **The onboarding question**: Can you add a new user without redeploying?
- [ ] **The offboarding question**: Can you remove a user's access immediately?

### Architecture Checklist
- [ ] **First principles**: Did you design from requirements, or from existing code?
- [ ] **Capability before plumbing**: Did you define WHAT before HOW?
- [ ] **No inherited blind spots**: Did you explicitly list what the current system is missing?
- [ ] **Challenge your assumptions**: Did you argue against your own design?

---

## The Reflection Loop

This is the most important part of this document. Reflection is not optional — it is how the system improves.

### When To Reflect

| Trigger | What To Do |
|---------|-----------|
| After completing a design | Run the Magnum Opus Test. Record what you missed in the Failure Log. |
| After the user pushes back | Ask: "What did they see that I didn't?" Add the blind spot to Anti-Patterns. |
| After a successful implementation | Record what worked in the Insights Log. What pattern should future agents reuse? |
| After discovering a new trap | Add it to the Traps section with detection + prevention. |
| After reading this document | Ask: "Is anything here wrong, outdated, or incomplete?" Fix it. |

### How To Reflect

Run this protocol after any significant work:

```
1. WHAT HAPPENED — Describe what you built/designed in one sentence.
2. WHAT WORKED — What decision or approach was correct? Why?
3. WHAT DIDN'T — What did you miss, get wrong, or waste time on?
4. WHY — Root cause. Not "I forgot" — WHY did you forget? What in your process allowed this gap?
5. WHAT CHANGES — What should change in this document, in the codebase, or in the approach?
6. WRITE IT DOWN — Update the relevant section of this document. Don't just think it — commit it.
```

### Where To Store Reflections

```
docs/agent-behavior/
├── introspect.md          ← THIS FILE. Traps, checklists, protocols.
├── failure-log.md         ← Distilled rules from past failures.
└── insights.md            ← Distilled patterns from successes.
```

Related docs (outside agent-behavior/):
- `docs/architecture.md` — system topology, auth flow, service details
- `docs/known-gotchas.md` — things that will bite you (distilled from failure-log)
- `docs/config-reference.md` — every env var across all services

- **introspect.md** (this file): The thinking protocol itself. Update when you discover new traps.
- **failure-log.md**: Distilled rules from failures. One line per lesson, not narratives.
- **insights.md**: Distilled patterns from successes. What worked, as reusable rules.

---

## The Self-Improvement Rule

**This document is not sacred.** It is a tool. If a section is wrong, fix it. If a section is missing, add it. If a section is outdated, update it.

Agents MUST:
1. **Read** this document before any design or architecture work.
2. **Challenge** this document — is anything here wrong or incomplete?
3. **Update** this document when they learn something new.
4. **Record failures** in `failure-log.md` with root cause analysis.
5. **Record successes** in `insights.md` so future agents benefit.
6. **Add new traps** to the Anti-Patterns table when they fall into one.
7. **Refine checklists** when they discover a gap (like the missing identity checklist item).

The goal is that each agent session leaves this system smarter than it found it.

---

## The Iteration Protocol

After completing a design, run this loop:

```
1. Read your design as if you're a hostile reviewer. What's the dumbest mistake?
2. Ask: "What would make the user say 'you wasted my time'?"
3. Ask: "What's the most important thing this system does?"
   → Is that the part you spent the most design effort on?
   → If not, your priorities are wrong.
4. Ask: "If I showed this to a security auditor, what would they flag first?"
5. Ask: "Six months from now, what will the user wish this system could do?"
   → Does the foundation support it?
6. Run the Reflection Loop above and WRITE DOWN what you find.
```

---

## Anti-Patterns To Watch For

| Anti-Pattern | What It Looks Like | What To Do Instead |
|---|---|---|
| Anchoring | "The current system uses a shared API key, so I'll make the shared API key better" | "The current system has no user identity. This is the first thing to fix." |
| Plumbing over purpose | "Let me spend 500 words on RS256 key rotation" | "Let me first define who the users are and what they can do" |
| Technical correct, design wrong | "The spec reviewer approved it!" | "Does it solve the actual problem the human described?" |
| Premature "magnum opus" | "This is the best possible design" | "What am I missing? What would a hostile reviewer say?" |
| Incrementalism | "Let's improve what exists" | "Let's define what's needed, then see what to keep" |
| Echo chamber review | "The reviewer checked my crypto choices" | "The reviewer should also ask: does this system know its users?" |
| Static instructions | "I read introspect.md and followed it" | "I read introspect.md, found a gap, and updated it" |
| Reflecting without recording | "I learned something but didn't write it down" | "I learned something and added it to insights.md / failure-log.md" |

---

## When To Use This Document

1. **Before any design**: Read the 5 WHYs and answer them.
2. **During design**: Check Anti-Patterns. Am I falling into one?
3. **After completing a design**: Run the Magnum Opus Test checklist.
4. **After a design failure**: Run the Reflection Loop. Update failure-log.md and this file.
5. **After a success**: Update insights.md. What worked and why?
6. **When the user pushes back**: Re-read this document. The user is probably catching a blind spot. Add it.
7. **At the end of every session**: Ask "did I learn something that should be recorded?"
