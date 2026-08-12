# memory-tencentdb `src/offload` Overview

> TL;DR: `src/offload` replaces one-shot transcript compaction with a layered memory pipeline for tool-heavy chats, not the long-term persona/scene memory path. L1 records recoverable tool-result summaries, L1.5 assigns future rows to task boundaries, L2 turns unresolved rows into Mermaid task nodes, and L3 locally compresses prompt messages using those rows. In `collect` mode the system still collects L1/L1.5/L2 data but deliberately skips L3 compression and MMD injection.

## 1. Module Shape

`src/offload` is a context-offload subsystem registered through `registerOffload(api, offloadConfig)`. It owns the hook wiring, session state, JSONL/ref/MMD storage, backend/local LLM calls, and local L3 compression.

```
src/offload/
├── index.ts                    registerOffload entry point; L1/L1.5/L2/L4 orchestration
├── types.ts                    OffloadEntry, ToolPair, L15Boundary, PluginConfig
├── state-manager.ts            per-session runtime state and persistent state.json coordination
├── storage.ts                  offload-*.jsonl, refs/*.md, mmds/*.mmd, state.json I/O
├── backend-client.ts           /offload/v1/{l1,l15,l2,l4,store} client
├── local-llm/                  local LLM fallback using the same logical contracts
├── hooks/
│   ├── after-tool-call.ts       ToolPair capture, in-loop MMD refresh, L3 checks
│   ├── before-prompt-build.ts   fast-path reapply, L3 guard, MMD injection
│   ├── before-agent-start.ts    task transition helpers and L4 command handling
│   ├── llm-input-l3.ts          L3 mild/aggressive/emergency algorithms
│   └── llm-output.ts            force-L1 marker handling
└── pipelines/
    └── l2-mermaid.ts           L2 trigger checks and node_id backfill
```

`before-agent-start.ts` still contains task-transition helpers, but L1.5 is triggered from `OffloadContextEngine.assemble()` in context-engine mode and from `before_prompt_build` in collect/gateway mode.

## 2. Pipeline Summary

Each layer has a separate trigger, artifact, and failure mode.

```
Layer  Trigger                         Main artifact                         Prompt effect
L1     pending pairs / pre-flush        offload-*.jsonl + refs/*.md           none directly
L1.5   assemble / before_prompt_build   runtime boundary + active MMD state   controls MMD ownership
L2     null/wait rows + scheduler       mmds/*.mmd + node_id backfill         future MMD context
L3     token thresholds                 mutated event.messages                immediate token reduction
L4     /create-skill command            generated skill artifact              no direct prompt mutation
```

The handoff that matters most:

```
L1    writes one row per tool result with node_id: null
L1.5  records { startIndex, result: "long" | "short", targetMmd }
L2    groups eligible null/wait rows by L1.5 boundary
L2    patches/writes the target MMD
L2    backfills node_id, usually null -> wait -> NNN-Nx
L3    uses summary, score, result_ref, and node_id for local compression
```

See the focused layer docs:

- [L1 Context Offload Summary](./l1-summary.md)
- [L1.5 Context Offload Summary](./l15-summary.md)
- [L2 Context Offload Summary](./l2-summary.md)
- [Before Prompt Build Offload Summary](./before-prompt-build-summary.md)

## 3. Runtime Flow

The main conversation path and background memory path are intentionally split. LLM-heavy summarization and graph work run through backend/local side paths; the high-frequency L3 path is local.

```text
user prompt
  -> before_prompt_build hook
       -> L1 fire-and-forget flush, if pending pairs exist
       -> collect mode:
            -> fire-and-forget judgeL15()
            -> return before L3/MMD injection
       -> normal mode:
            -> createBeforePromptBuildHandler()
            -> fast-path reapply confirmed replacements/deletions
            -> L3 aggressive/mild/emergency guard
            -> active/history MMD injection

tool call finishes
  -> after_tool_call hook
       -> filter duplicate/heartbeat/approval-pending calls
       -> buffer ToolPair
       -> cache latest-turn context for L2
       -> refresh active MMD message when L1.5 has settled
       -> run local L3 checks when token thresholds require it

background / scheduled paths
  -> flushL1() writes JSONL rows and refs
  -> checkL2Trigger() selects unresolved rows
  -> runL2WithBackend() patches MMDs and backfills node_id
```

## 4. L1: Tool Result Rows

L1 is the durable capture layer. During `flushL1()`, its L1.1 ref-write step first writes each raw tool output to `refs/*.md`, then sends tool pairs to the L1 summarizer in batches of 5, and finally appends summary rows to `offload-<sessionId>.jsonl` with `result_ref` pointing at the raw-result backup.

Fresh rows have `node_id: null`:

```json
{
  "timestamp": "2026-06-16T08:46:32.889+08:00",
  "node_id": null,
  "tool_call": "cron list",
  "summary": "确认每日科技摘要 cron 任务存在且启用。",
  "result_ref": "refs/2026-06-16T08-46-32-889p08-00.md",
  "tool_call_id": "call_00_KwGxR3m5I18NHXnGI6ES8841",
  "score": 9
}
```

L1 can degrade gracefully. If a chunk fails repeatedly, it writes fallback rows with `score: 0` and `[L1 degraded]` summaries. That keeps raw-result recovery and later attribution possible even when the summarizer is unavailable.

## 5. L1.5: Task Boundaries

L1.5 is the async task-boundary judge. It answers this question:

```text
Starting at offload entry N, should future L1 rows belong to a long-task MMD?
```

It first flushes pending pairs that existed before the latest user message, then snapshots `stateManager.entryCounter` as `startIndex`.

```ts
{ startIndex, result: "long" | "short", targetMmd }
```

The boundary is runtime-only. It is not written as a JSONL row. L1.5 may still persist normal state changes, such as creating a new MMD shell, reactivating an existing MMD, clearing active MMD state for short work, and saving `state.json`.

Failure behavior is conservative: one delayed retry, then fail-safe to a `short` boundary with no target MMD. That avoids polluting task graphs when classification is unavailable.

## 6. L2: Mermaid Graph and Node IDs

L2 reads all `offload-*.jsonl` files for the current agent, but it only processes rows with `node_id === null` or retry rows with `node_id === "wait"`.

Rows must also be covered by a current long-task L1.5 boundary:

```ts
if (entry.node_id !== null && entry.node_id !== "wait") continue;

const boundary = stateManager.resolveEntryBoundary(i);
if (!boundary) continue;
if (boundary.result !== "long") continue;
if (!boundary.targetMmd) continue;
```

Trigger paths:

```text
null_count >= l2NullThreshold
time since last L2 >= l2TimeoutSeconds
no prior L2 + retry-wait rows
no prior L2 + oldest null row age >= timeout
```

For each target MMD, L2 marks selected null rows as `wait`, sends `existingMmd` plus `newEntries` to the backend/local generator, applies `replaceBlocks` or `mmdContent`, and then backfills concrete node IDs from `nodeMapping` or a fallback derived from the MMD.

L2 does not normally revisit rows that already have concrete node IDs. If a later MMD patch changes or removes a node, existing JSONL rows are not automatically reconciled unless a separate repair path rewrites them.

## 7. L2 Result Consumers

The L2 result is not consumed by the long-term memory pipeline. It stays inside `src/offload` and supports task continuity from tool-output traces for tool-heavy chats.

```text
L2 result
  mmds/*.mmd task graph
  offload-*.jsonl node_id backfill

Consumed inside offload by
  active MMD prompt injection
  L3 local compression/protection
  history MMD recovery after aggressive deletion
  L4 /create-skill generation

Not consumed by
  L0 conversation capture
  L1 long-term memory extraction
  L2 scene_blocks extraction
  L3 persona generation
```

The active MMD injection path reads the current MMD and inserts it as `<current_task_context>` so the agent can keep task direction without replaying raw tool logs. L3 reads `node_id` to protect current-task nodes and to choose historical tool results that can be replaced or deleted. When aggressive deletion removes old tool blocks, history recovery maps deleted tool calls through their `node_id` prefixes back to related MMD files. L4 uses `/create-skill` to send a selected MMD plus offload rows whose `node_id` appears in that MMD to the backend skill generator.

## 8. L3: Local Prompt Compression

L3 is the only offload layer that directly mutates `event.messages`. It is local and does not call an LLM.

L3 uses L1/L2 data:

```text
score       choose high-replaceability rows first
summary     replace tool_result content
result_ref  preserve recovery path after replacement/deletion
node_id     protect active-task nodes when possible
```

Compression levels:

```text
mild        score-cascade replacement of older/high-score tool results
aggressive  deletes larger historical blocks and injects history MMD context
emergency   last-resort truncation when thresholds are still exceeded
```

Default thresholds are defined in `PLUGIN_DEFAULTS`:

```text
mildOffloadRatio          0.50  start score-cascade replacement
aggressiveCompressRatio   0.85  start larger historical deletion
emergencyCompressRatio    0.95  start emergency deletion/truncation
emergencyTargetRatio      0.60  emergency target after deletion
mildOffloadScanRatio      0.70  scan the oldest 70% of messages
```

Mild compression is count-driven inside the cascade. It scans the older part of the message array, sorts candidates by `score`, starts at score `>= 7`, walks down to score `>= 1`, and stops after at least 10 replacements. Token thresholds decide whether L3 enters mild/aggressive/emergency; the mild cascade itself does not receive a token target.

`currentTaskNodeIds` is not a blanket filter for every mild candidate. Its concrete protection role is in helper paths such as `compressNonCurrentToolUseBlocks()` and aggressive deletion: when a tool call already maps to a node in the active MMD, the code can avoid compacting that current-task tool-use block unless it was already selected as replaced.

The `after_tool_call` path also has a quick-skip guard. If the last precise token snapshot says the context is clearly below the mild threshold, it uses a CJK-aware estimate for newly added messages and skips full tiktoken counting. After 5 consecutive quick skips, it forces a precise snapshot to prevent drift.

The `before_prompt_build` handler also re-applies confirmed replacements and deletions because frameworks can replay the full history on the next prompt build.

## 9. Collect Mode

`offload.mode: "collect"` is a data-collection mode. It keeps the memory pipeline active while avoiding prompt mutation.

In `before_prompt_build`:

```text
normal session guard passes
session manager resolves
pending L1 flush starts fire-and-forget
judgeL15() starts fire-and-forget when prompt hash changed
return before createBeforePromptBuildHandler()
```

That means collect mode:

```text
runs        L1 flush, L1.5 judgment, L2 scheduling/backfill
skips       L3 compression, active/history MMD injection
does not    register the context engine slot
uses        host/legacy compaction for prompt pressure
```

The default mode is config-derived:

```ts
if mode is "local" | "backend" | "collect", use it;
else if backendUrl exists, use "backend";
else use "local";
```

`offload.enabled` still defaults to `false`, so the offload subsystem must be enabled separately.

## 10. Physical Data Layout

The storage root is grouped by agent. Each session gets its own JSONL file, while MMDs and refs are shared inside the agent directory.

```text
<dataRoot>/<agentName>/
├── state.json
├── sessions-registry.json
├── offload-<sessionId>.jsonl
├── refs/
│   └── <timestamp>.md
└── mmds/
    └── 001-daily-tech-news-digest.mmd
```

Roles:

```text
offload-*.jsonl  compact per-tool event rows
refs/*.md        raw result backups
mmds/*.mmd       human-readable task graph memory
state.json       active MMD, counters, cursors, last L2 time
```

Ref filenames are derived from the tool-result timestamp only, for example `refs/2026-06-16T08-46-32-889p08-00.md`. The tool name and call ID are stored inside the Markdown file body and linked from each JSONL row through `result_ref`.

Retention is optional. `offloadRetentionDays` defaults to `0`, which disables reclamation. When it is at least 3, the reclaimer can remove expired session JSONL files, orphaned `refs/*.md` files that are no longer referenced by surviving JSONL, expired MMDs while keeping a minimum per agent, and oversized debug logs.

## 11. Why This Differs From Default Compaction

Default compaction is generally transcript-scale: when token pressure is high, summarize a large section of history and replace it. Offload is tool/result-scale and task-scale.

```text
Dimension             Default compaction             memory-tencentdb offload
Granularity           transcript chunk                tool call + task node
LLM on main path      yes, for compaction             no for L3; L1/L1.5/L2 side path
Recoverability        summary only                    refs/*.md preserve raw result
Task continuity       session-local transcript         MMD continuation via L1.5
Compression choice    broad summary                    score/node_id guided local actions
Visualization         none                            Mermaid MMD task graph
Observability          compaction notifier             L3 reports + Opik traces
```

The trade-off is more moving parts: JSONL rows, refs, MMD files, runtime boundaries, L2 scheduling, and several thresholds. The benefit is that the system can drop or compress details without losing task direction or raw-result recovery.

## 12. Operational Risks

The main risks are about stale attribution and runtime state.

```text
Risk                         Effect
L1.5 boundary is runtime-only Session switches reset boundary memory; old concrete rows remain durable
L2 does not reconcile history Later MMD rewrites do not automatically migrate old concrete node_id rows
L3 depends on message patching If event.messages cannot be mutated, prompt compression is skipped
Tokenizer estimates differ    tiktoken/heuristics may not match every provider exactly
Collect mode skips injection   Data accumulates, but active MMD is not added to prompts
```

Patch effectiveness is explicit. `after_tool_call` classifies `event.messages` as `effective`, `missing_field`, or `empty_messages`; if the runtime patch did not expose a usable messages array, L3 cannot inspect or mutate the conversation and skips that turn. When a backend client exists, the skip is reported through the same state-report path used by L3 trigger reports.

When debugging attribution, start with the layer boundary:

```text
No JSONL row?              inspect L1 capture/flush
JSONL row has null?        inspect L1.5 boundary and L2 trigger
JSONL row has wait?        inspect L2 backend/backfill failure
JSONL row has concrete ID? inspect MMD content and L3 lookup/protection
Prompt not compressed?     inspect collect mode, patch effectiveness, and L3 thresholds
```

## 13. Code References

Read these first:

- `src/offload/index.ts`: registration, `flushL1()`, `judgeL15()`, `runL2WithBackend()`, collect-mode branch, context-engine registration.
- `src/offload/hooks/after-tool-call.ts`: tool-pair capture, active MMD refresh, in-loop L3 behavior.
- `src/offload/hooks/before-prompt-build.ts`: pre-LLM fast-path, L3 token guard, MMD injection.
- `src/offload/pipelines/l2-mermaid.ts`: L2 eligibility, trigger rules, `wait`, and `backfillNodeIds()`.
- `src/offload/storage.ts`: per-session/all-session JSONL storage, refs, MMD patch/write helpers.
- `src/offload/state-manager.ts`: `entryCounter`, `l15Boundaries`, active MMD state, and runtime-only compression state.
- `src/offload/state-reporter.ts`: patch-effectiveness classification and fire-and-forget L3 state reports.
- `src/offload/reclaimer.ts`: optional retention cleanup for JSONL, orphan refs, MMDs, registry entries, and logs.
