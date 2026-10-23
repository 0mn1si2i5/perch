---
name: moot-roundtable
description: Convene configured local models for a bounded roundtable with roles, independent first-round opinions, later replies to disagreements, and a summary by the current dialogue agent after every round.
---

# Moot roundtable

You, the current dialogue agent, are the host. Use `__MOOT_EXECUTABLE__ rpc`, with `{protocolVersion:1,requestID,operation,payload}` JSON on stdin. Read `config.read` first. Automatic roundtables are off by default. Set `trigger:"userRequested"` only when the user actually requested a meeting; otherwise `automatic`, which requires the separate configured opt-in. Do not disguise an automatic meeting as a user request.

Write a minimal shared brief and call `meeting.start` with `{requestID,trigger,briefPath,workdir,hostRef}`. All paths are absolute. Uses the saved meetingPreset. `meetingOverride` may contain `{seats:[{seatID,connectionID,model,role,instructions}],maxRounds,allowEarlyFinish}` only within the user's requested/allowed scope. Respect explicitly named models. Keep every seat ID stable and unique.

Read `run.read` with `{runID}`. While `runningRound`, wait and reread. In `awaitingHost`, read every current-round seat's output and earlier open issues. First-round inputs are independent; later rounds receive all previous completed statements and host summaries. A round means all seats speak once and then you summarize. If a seat failed, disclose it; do not invent its position. Before submitting a summary, `meeting.retry` with `{runID}` retries only failed seats after the cause is fixed; successful speeches remain unchanged.

Submit `meeting.summary` with `{runID,summary:{round,inputRevision,commonGround:[],hostJudgment:"...",missingSeats:[],issues:[]}}`. inputRevision is the exact run revision just read. Summarize actual shared positions separately from your own judgment. An issue contains `{issueID,title,status:"open",positions:"...",evidence:"...",next:"...",references:[{round,seatID,messageID}]}`. Use actual speech message IDs. Preserve unresolved issue IDs across rounds; a resolved issue must record its evidence. Omission or majority agreement does not resolve an issue. Include every failed/missing seat in missingSeats. Duplicate identical summaries are safe; on revision conflicts reread before proceeding.

When `readyForNextRound`, call `meeting.advance` with `{runID,expectedRound}`. Continue until `ended`; the round limit is enforced. Never spawn a round after the limit. `endEarly:true` in a summary only works when allowEarlyFinish was enabled. On completion report common ground, your judgment, remaining disagreements and next steps. If the host conversation stops, the run remains awaitingHost; Perch does not generate summaries on your behalf. Use `run.cancel` on user cancellation, preserving partial results.

Host sandbox and tool permissions still apply to the executable and its children. Detaching does not grant access to credentials, network or files. If the host blocks access, report that limitation and use its normal permission flow; never disable or bypass safeguards.
