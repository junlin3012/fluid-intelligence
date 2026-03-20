# Mirror Polish Batch 21
**Date**: 2026-03-20 | **Clean counter**: 0/5 (reset — 1 fix)

9 CLEAN, 1 ISSUE: 5MB response limit vs 1MB payload limit ambiguity — clarified 1MB is request-only, tool responses are separate.

Fix: Added "request" qualifier and cross-reference to Section 8 tool response validation.
