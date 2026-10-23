---
name: moot-review
description: Ask a configured local model for an independent read-only review through Perch Moot, then inspect its findings and continue the current conversation.
---

# Independent review

Use `__MOOT_EXECUTABLE__ rpc` with JSON on stdin. Read `config.read` first. Choose an enabled audit capability or general configuration; preserve any model/account explicitly named by the user. API access is never implicitly enabled.

Write a concise brief with scope, requirements, relevant file paths and review questions. Do not provide your conclusions in advance. Call `audit.start` with `{requestID, trigger:"automatic", capabilityID, briefPath, workdir, hostRef}`; every path is absolute. Include `explicitConnectionID` / `explicitModel` when requested. The surrounding request is `{protocolVersion:1,requestID,operation,payload}`. Use `userRequested` when the user explicitly requests the review.

The returned `id` identifies a detached run. Read `run.read` with `{runID}` until ended/failed/cancelled, with short waits between reads; inspect partial output and errors. Verify findings against actual files, distinguish supported defects from suggestions, and continue the original conversation. Do not change files as part of the read-only review, copy private transcripts unnecessarily, or accept another model's self-report as proof. Respect current repository Git rules; no fixed merge strategy is prescribed.

Host sandbox and tool permissions still apply to the executable and its children. Detaching does not grant access to credentials, network or files. If the host blocks access, report that limitation and use its normal permission flow; never disable or bypass safeguards.
