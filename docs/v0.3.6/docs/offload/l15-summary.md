# L1.5 Context Offload Summary

> TL;DR: L1.5 is the async task-boundary judge. It does not write L1 summary rows or build L2 Mermaid nodes. It decides that future L1 entries starting at `startIndex` belong to a long-task MMD, or to no MMD for short/casual work. An **L1 row** is one tool-call summary line in `offload-*.jsonl`; an **L2 node** is one `NNN-N<k>[...]` line in `mmds/*.mmd` that aggregates every L1 row sharing the same `node_id`. `node_id` is the join key. (Live data below from `./context-offload`, a symlink to the local running tencent-memory instance.)

## 1. Workflow

L1.5 starts from the latest user turn, cleans up any older pending tool-pair work, asks the backend to classify task continuity, then records an in-memory boundary for future L1 rows.

```
latest user turn
  -> OffloadContextEngine.assemble() / collect-mode before_prompt_build
  -> flush existing pending tool pairs through L1
  -> snapshot startIndex = stateManager.entryCounter
  -> build L1.5 input:
       recentMessages
       currentMmd
       availableMmdMetas
  -> backend /offload/v1/l15/judge
  -> normalize TaskJudgment
  -> handleTaskTransition()
       create new MMD shell, reactivate old MMD, keep active MMD, or clear active MMD
  -> push runtime boundary:
       { startIndex, result: "long" | "short", targetMmd }
  -> mark l15Settled and allow/skip MMD injection
  -> later L1 rows at or after startIndex are grouped by this boundary for L2
```

Failure path:

```
first L1.5 attempt fails
  -> wait 3000 ms
  -> retry once
  -> if retry fails:
       activeMmd = null
       boundary = { startIndex, result: "short", targetMmd: null }
       l15Settled = true
```

## 2. Example: L1 Row vs L2 Node

One real L1 row — a single tool call, summarized and tagged with the L2 node it belongs to:

```json
{"tool_call_id":"call_01_JAkg3LeGcT0FnYMK7VT36901","tool_call":"read: ~/.openclaw/workspace/skills/tech-news-digest/SKILL.md","summary":"获取技能元数据（版本3.16.0）及环境变量配置要求，为后续流水线执行提供基础依赖信息。","score":8,"node_id":"001-N18","result_ref":"refs/2026-06-14T07-00-10-949p08-00.md"}
```

Key fields: `node_id` is the L2 node this row rolls into (backfilled by L2), `score` is L1 importance (0-10), `result_ref` points to the full tool result under `refs/`.

That row, plus the other tool calls of the same June 14 pipeline run, all carry `node_id: "001-N18"`. L2 collapses them into one task-level node:

```
001-N18["6月14日修复与运行pipeline<br/>status: done<br/>summary: 修复cron→读取技能/模板→并行抓取(6源)→合并15条→摘要→写入daily-2026-06-14.md (4525字节)并归档<br/>Timestamp: 2026-06-14T18:39:06+08:00"]
001-N1 --> 001-N18
```

So many fine-grained L1 rows (one per tool call) collapse into one L2 node (one task step), joined by `node_id`; `status` is `done`/`doing`/`blocked` and `001-N1 --> 001-N18` is the edge from the task-root node. See [Output](#6-output) and [Persistence](#7-persistence) for the full field semantics.

### 2.1 startIndex usage — new MMD on a mid-chat pivot

When the user pivots to a brand-new long task mid-conversation, L1.5 snapshots the current `entryCounter` as `startIndex`, calls `createNewMmd()` to write a root-only shell, and pushes a `long` boundary pointing at that new file. This is a real case: `002-fix-unauthorized-access.mmd` exists on disk as a shell only —

```
flowchart TD
    002-N1["fix-unauthorized-access"]
```

Suppose the session already wrote 5 casual L1 rows (`entryIndex 0..4`), then the user says "now fix the unauthorized-access bug". L1.5 classifies it as a new long task:

```ts
const startIndex = stateManager.entryCounter; // 5
// backend: { taskCompleted:false, isContinuation:false, newTaskLabel:"fix-unauthorized-access", isLongTask:true }
// createNewMmd() writes the 002 shell above
{ startIndex: 5, result: "long", targetMmd: "002-fix-unauthorized-access.mmd" }
```

Every L1 row from `entryIndex 5` onward is attributed to `002-fix-unauthorized-access.mmd`; L2 later fills in `002-N2`, `002-N3`, … under the root and backfills their `node_id`. The shell having only `002-N1` is exactly what a not-yet-L2-processed new task looks like.

**L1 file: none yet.** This is the honest live-data state — no `offload-*.jsonl` row carries a `002-*` `node_id`, and no row mentions "unauthorized". The shell (51 bytes, created `2026-06-04 15:04`, never updated) is a boundary L1.5 opened but under which no tool work was ever attributed/L2-processed. The `startIndex: 5` and "5 casual rows" above are illustrative of the pivot mechanics, not read off a real file. A new-MMD pivot only gains an L1 file once tool calls run after its boundary and L2 backfills `002-*` ids — which never happened for this shell.

### 2.2 startIndex usage — attach existing MMD on a mid-chat topic switch

When the user switches back to a task that already has an MMD, L1.5 returns a continuation, reactivates the existing file (no new shell is written), and pushes a `long` boundary pointing at it. This is the live `001-daily-tech-news-digest.mmd` case — a fully populated graph whose nodes (`001-N2` … `001-N20`) are spread across several session files, all attributed back to the same MMD.

**L1 file: `offload-af31ea9c-b54e-41bd-bf50-d7aa2fee1689.jsonl`** (39 rows; 37 attributed to the digest, last 2 attributed to another MMD after later L2 backfill). The session opens directly on tech-news work, so L1.5 judged the very first user turn a continuation of the already-populated digest and pushed the boundary at `entryCounter == 0`. `startIndex` is the 0-based index *within the current session file*, and this fresh session starts at 0:

```ts
const startIndex = stateManager.entryCounter; // 0 — first turn of this session file
// backend: { taskCompleted:false, isContinuation:true, continuationMmdFile:"001-daily-tech-news-digest.mmd", isLongTask:true }
// handleTaskTransition() reactivates the existing MMD; no createNewMmd()
{ startIndex: 0, result: "long", targetMmd: "001-daily-tech-news-digest.mmd" }
```

(A *same-session* topic switch — pivoting back mid-chat without a new session file — would instead snapshot a non-zero `startIndex`, e.g. 12 if 12 rows were already written; the mechanic is identical, only the index differs. This real file happens to be a fresh session, so its continuation boundary is 0 — the §9 case.)

The file has **39 rows total**, and the split across them is the real point of this example:

```
rows 1–28   node_id 001-N19   verify daily-digest cron             ┐ digest attribution
rows 29–37  node_id 001-N20   timeout / model-abort investigation  ┘
rows 38–39  node_id 003-N3    gateway-timeout / stuckSession probe  ← later attributed elsewhere
```

Rows 1–37 land in the attached digest MMD, distributed by L2 across two task steps — the boundary owns the *MMD*, and L2 decides which node within it each row joins. Row 1, already L2-backfilled to `001-N19`:

```json
{"tool_call_id":"call_00_KwGxR3m5I18NHXnGI6ES8841","tool_call":"cron list","summary":"确认每日科技摘要cron任务（c31e8831）存在且启用，schedule为每日07:00，payload包含完整的工作流指令。任务配置正常，但尚未执行实际摘要生成。","timestamp":"2026-06-16T08:46:32.889+08:00","score":9,"node_id":"001-N19","result_ref":"refs/2026-06-16T08-46-32-889p08-00.md"}
```

But rows 38–39 carry `"node_id": "003-N3"` — L2 did **not** roll them into the digest. They are the session moving off-task into a separate gateway-timeout/`stuckSession` probe that was later backfilled under another MMD. Row 38, the first non-digest row:

```json
{"tool_call_id":"call_00_q2Lwr2XGmTTt3wG8sJiY9323","tool_call":"exec: 搜索 gateway 文档中 timeout/abort 相关配置，检查 yieldMs 默认行为","summary":"未发现明确的 380s 超时设置，但定位到认证、配置相关超时参数（talk.silenceTimeoutMs、remoteCdpTimeoutMs等），对根因排查无直接突破，需进一步检查模型层或系统级超时","timestamp":"2026-06-16T08:56:35.355+08:00","score":8,"node_id":"003-N3","result_ref":"refs/2026-06-16T08-56-35-355p08-00.md"}
```

So this one file shows the persisted outcome of an **attach** to the existing digest MMD: rows 1–37 were later backfilled by L2 with `001-*` node IDs, while rows 38–39 were later backfilled with `003-*` node IDs. The runtime `startIndex` was not inferred from those persisted `node_id` values; L1.5 snapshots it from `stateManager.entryCounter` before the judgment and keeps the boundary in memory. Because L1.5 boundaries are runtime-only (§7), the node-id prefix transition can show where persisted L2 attribution stops belonging to the digest in this file, but it is not a durable record of the exact L1.5 switch boundary. `null` would strictly mean "not rolled into any MMD"; this current file has no remaining `null` rows.

Historical rows can therefore change after the chat turn that created them. L1 initially appends rows with `node_id: null`; when L2 later decides those rows belong to an MMD, it first rewrites the selected rows to `node_id: "wait"` while the backend is running, then rewrites them again to the backend `nodeMapping` result or to a fallback node derived from the MMD. That is why rows 38–39 may once have appeared as `null`, but now appear as `003-N3`.

`wait` is normally a transient retry marker, not a stable final state. In a successful L2 pass, the row moves `null → wait → concrete node_id` in the same processing flow. A saved `wait` row means L2 started processing that row but did not complete the backfill, for example because the backend failed, mapping/fallback failed, or the process stopped before the final rewrite.

The `003-N3` node is visible in `003-hulunbuir-family-trip-plan.mmd` as a dotted/blocked node:

```
003-N1 -.-> 003-N3["排查超时故障（无关）<br/>status: blocked<br/>summary: ..."]
```

That graph status does not mean the JSONL rows should go back to `null`; it means L2 kept them attached to a concrete node while marking the node as unrelated/blocked in the chart. In the normal scheduler path, rows with a concrete `node_id` are skipped by future L2 grouping (`checkL2Trigger()` only considers `node_id === null` or `"wait"`), so they are not expected to revert to `null` unless a separate repair/manual rewrite path changes the JSONL.

Contrast with §2.1: a new task writes a shell first, a continuation reuses an existing file untouched.

## 3. Role

L1.5 answers the ownership question between L1 and L2. L1 summarizes individual tool calls; L2 patches task-level Mermaid memory; L1.5 decides which task bucket the next L1 entries should flow into.

In one sentence, L1.5 says:

```
Starting at offload entry N, future tool-call summaries belong to this long-task MMD, or to no MMD.
```

This is why the core output is a boundary, not a new row in `offload.jsonl`.

### 3.1 Extraction target: tool results only; LLM response is context

Both L1 and L2 extract from tool results, never from the assistant's own response text. The LLM response is passed only as reference context to help summarization/grouping.

```
L1   extracts = tool pairs (params + result)        one JSONL row per tool result
L2   extracts = L1 tool-call rows → task nodes       groups rows into MMD nodes
both context  = recent conversation, incl. [Assistant] LLM replies (reference only)
```

- L1's `L1Request` is `{ recentMessages, toolPairs }`; the extraction target is `toolPairs` (`toolName/params/result`), and `recentMessages` is reference context only (`src/offload/index.ts:464`).
- L2's `newEntries` are `{ tool_call_id, tool_call, summary, timestamp }` — all derived from L1 tool-call rows — while `recentHistory`/`currentTurn` are sent as context (`src/offload/index.ts:714`).
- The shared context block is assembled as user/assistant turns and *does* include `[Assistant]: …` LLM text (`src/offload/index.ts:198`), but that text is reference only and is truncated (assistant replies to 400 chars, user prompt to 500 chars) — it is never the thing being summarized.

### 3.2 What counts as a "tool call"

A tool call is one tool invocation by the agent, captured via the framework's `after_tool_call` hook (`src/offload/index.ts:1026`) and stored as a `ToolPair` (`src/offload/hooks/after-tool-call.ts:177`):

```
toolName     e.g. read, exec, grep, cron, an MCP tool, a skill-as-tool
toolCallId   unique id for this invocation
params       the call arguments
result       the tool's output
```

So the captured unit is **(params + result) of one tool invocation** — this is exactly what L1 summarizes into one JSONL row.

The agent's output splits into two kinds: its own **assistant text** (the direct LLM API response — never a tool call, used as context only) and **tool-use requests** (each fires `after_tool_call` and becomes a ToolPair). So "tool call" does *not* mean "any action other than the LLM reply" in the abstract — it specifically means a tool-use invocation surfaced by that hook. Several invocations are deliberately dropped before buffering:

```
already-processed (duplicate) toolCallId   src/offload/hooks/after-tool-call.ts:160
heartbeat tool calls                       src/offload/hooks/after-tool-call.ts:161
approval-pending tools (no useful result)  src/offload/hooks/after-tool-call.ts:170
HEARTBEAT.md pairs (filtered at L1 flush)  src/offload/index.ts:424
```

Net: a tool call = one agent tool invocation (params+result) surfaced by `after_tool_call`, minus duplicates / heartbeats / approval-pending. The LLM's own text reply is never a tool call.

## 4. Trigger

L1.5 runs before prompt construction for a new prompt, not in the old `before_agent_start` location. It is not triggered on every hook invocation: the runtime needs a non-empty prompt, an available backend/local LLM client, and a prompt hash that differs from the last L1.5 judgment for this state manager.

```
Mode                  Trigger point                         Behavior
Normal context engine OffloadContextEngine.assemble()        May call judgeL15() asynchronously
collect mode          before_prompt_build                   May call judgeL15() asynchronously, then skips L3/MMD injection
Old hook              before_agent_start                    Not the L1.5 trigger anymore
```

Trigger conditions:

```
prompt exists and is a non-empty string
backendClient / local LLM client exists
simpleHash(prompt) !== stateManager.lastL15PromptHash
```

Non-trigger cases:

```
no prompt or empty prompt                 Skip; no user turn to classify
no backend/local LLM client               Skip; L1.5 cannot judge task boundary
same prompt hash as last L1.5 judgment    Skip; avoids duplicate boundary judgment for replayed prompt builds
normal before_prompt_build path           Does not start L1.5; assemble() is the trigger point in context-engine mode
before_agent_start                        Not used as the L1.5 trigger anymore
```

When L1.5 does trigger, it is fire-and-forget from the prompt path. The caller sets `lastL15PromptHash` to the new hash, sets `l15Settled = false`, and starts `judgeL15(...)`; later L2 polling waits for `l15Settled` before grouping unresolved L1 rows by the boundary.

Core flow:

```ts
const judgeL15 = async (stateManager, event, ctx) => {
  stateManager.l15Settled = false;

  const snapshotCount = stateManager.getPendingCount();
  if (snapshotCount > 0) {
    await flushL1(stateManager, "l15_pre_flush", false, snapshotCount);
  }

  const startIndex = stateManager.entryCounter;

  if (await attemptL15(stateManager, startIndex)) return;

  // one delayed retry; if that also fails, fail-safe marks this segment short
};
```

## 5. Input

L1.5 input is recent conversation context plus task-memory context. The current active MMD is sent with full content, while older candidates are sent as compact metadata so the judge can detect continuation without loading every MMD in full.

Before calling the backend, L1.5 first flushes pending tool pairs that existed before the latest user turn. This prevents old work from being written after the new boundary.

```
old pending tool pairs
  -> L1 pre-flush writes offload.jsonl rows
  -> entryCounter advances
  -> L1.5 records startIndex
  -> new tool calls after this user prompt fall after the boundary
```

The L1.5 backend judge receives:

```ts
{
  recentMessages,
  currentMmd,
  availableMmdMetas
}
```

```
Field                 Meaning
recentMessages        Recent conversation context, with history as reference and latest user message as focus
currentMmd            Active MMD filename/content/path, or null
availableMmdMetas     Metadata for up to the last 10 lexicographically filename-sorted MMD files
```

`availableMmdMetas` contains compact fields such as filename, path, task goal, done/doing/todo counts, updated time, and recent node summaries. The current code gets all MMD filenames with `listMmds()`, applies JavaScript's default lexicographic `.sort()` to the full filename strings, and sends `slice(-10)`.

## 6. Output

The backend returns a task judgment, but local L1.5 turns it into active-MMD state and a runtime boundary. The backend does not return `startIndex`; local code snapshots it before the backend call and attaches it to the boundary after the judgment succeeds.

Backend judgment:

```ts
{
  taskCompleted: boolean,
  isContinuation: boolean,
  continuationMmdFile?: string,
  newTaskLabel?: string,
  isLongTask: boolean
}
```

Local boundary:

```ts
{ startIndex, result: "long" | "short", targetMmd }
```

The boundary means entries with `entryIndex >= startIndex` use this L1.5 decision until a later boundary supersedes it.

```
boundary @ 0  -> long 001-daily-tech-news-digest.mmd
entries 0..6  -> belong to 001-daily-tech-news-digest.mmd

boundary @ 7  -> short null
entries 7..8  -> short/casual, no MMD

boundary @ 9  -> long 002-fix-recall.mmd
entries 9..   -> belong to 002-fix-recall.mmd
```

## 7. Persistence

The L1.5 boundary itself is runtime-only in the current code. However, L1.5 can still cause persistent side effects through state saving and task transition. The precise answer is: L1 and L2 persist their primary artifacts; L1.5 does not persist boundary rows, but it may persist active-MMD state and MMD shell changes.

```
Layer   Persistent output                                      Notes
L1      offload-*.jsonl rows + refs/*.md                       One row per tool-call result pair, keyed by tool_call_id
L1.5    No persisted boundary file or boundary rows            Runtime l15Boundaries; may save active MMD state
L2      mmds/*.mmd patches + node_id backfill into JSONL       Writes task graph content for the chosen MMD
```

Compact version:

```
L1    persists offload-*.jsonl rows + refs/*.md
L1.5  runtime boundary; may persist activeMmd state and create/reactivate MMD shell
L2    persists/patches mmds/*.mmd and backfills node_id into offload-*.jsonl
```

Important nuance: `stateManager.save()` after L1.5 persists normal plugin state, such as active MMD selection. It does not persist `l15Boundaries`. On session switch, `entryCounter` is restored from the current offload JSONL length and `l15Boundaries` is reset to an empty array.

## 8. MMD Ownership

L1.5 owns MMD selection and initial shell creation; L2 owns graph content updates. L2 may physically write a missing file if asked to write MMD content, but the task identity and target filename come from L1.5.

The split is:

```
L1.5
  - decides whether the turn is long-task or short/casual
  - creates an initial NNN-label.mmd shell for a new long task
  - reactivates an existing MMD for continuation
  - clears active MMD for short/casual work
  - pushes an in-memory boundary

L2
  - reads existingMmd for the target selected by L1.5
  - sends L1 entries to the backend L2 generator
  - applies patchMmd() or writeMmd()
  - backfills node_id into offload-*.jsonl
```

So in normal operation:

```
L1.5 creates/selects the MMD shell and target.
L2 writes or patches the Mermaid graph content inside that target.
```

Concretely, L1.5's `createNewMmd()` (`src/offload/hooks/before-agent-start.ts:68`) `writeMmd`s a file containing only the root node — not an empty file and not task content:

```
flowchart TD
    001-N1["<label>"]
```

L2's generate path (`src/offload/index.ts:757`) then fills in the real task nodes (`001-N2`, `001-N18`, …), edges, statuses, and summaries via `patchMmd(replaceBlocks)`, falling back to `writeMmd(resp.mmdContent)`:

```ts
const patchOk = await patchMmd(ctx, mmdFile, resp.replaceBlocks);
if (!patchOk && resp.mmdContent) await writeMmd(ctx, mmdFile, resp.mmdContent);
```

Edge case: because of that `writeMmd` fallback, L2 *can* physically create the file if `patchMmd` finds it missing — so "only L1.5 creates files" is not strictly true. But the task identity and filename always originate from L1.5.

## 9. Real Entry Index Example

A JSONL line is 1-based on disk, but L1.5 boundaries use 0-based entry indexes. If a new June 16 tech-news session starts with an empty offload file, its first future L1 row has `entryIndex = 0`, so a continuation boundary would start at `startIndex = 0`.

For a file with 33 rows:

```
JSONL line 1  -> entryIndex 0
JSONL line 2  -> entryIndex 1
...
JSONL line 33 -> entryIndex 32
next row       -> entryIndex 33
```

If a new chat creates a new empty `offload-<session-id>.jsonl`, then before any tool rows are written:

```ts
stateManager.entryCounter === 0;
const startIndex = 0;

// likely if L1.5 sees the latest user turn as a continuation of tech-news work
{ startIndex: 0, result: "long", targetMmd: "001-daily-tech-news-digest.mmd" }
```

Later, L1 writes rows into the new session file. L2 uses the active runtime boundary to attribute those rows to `001-daily-tech-news-digest.mmd` and then backfills their `node_id`.

## 10. Failure Path

L1.5 has a one-retry fail-safe that prefers not polluting long-task memory. If both attempts fail, or both attempts return an all-null judgment, the segment is marked short in memory and active MMD injection is disabled for that round.

```ts
{
  startIndex,
  result: "short",
  targetMmd: null
}
```

This means future L1 entries after that boundary will not be eligible for L2 task-graph construction unless a later L1.5 boundary reclassifies subsequent entries as long-task work.

## 11. Code References

The key code paths are small and concentrated. Read these files first when debugging L1.5 behavior.

- `src/offload/index.ts`: `judgeL15()`, `attemptL15()`, fail-safe, pre-flush, and boundary push.
- `src/offload/backend-client.ts`: `L15Request` and `L15Response` request/response types.
- `src/offload/hooks/before-agent-start.ts`: `normalizeJudgment()` and `handleTaskTransition()`.
- `src/offload/state-manager.ts`: `entryCounter`, `l15Boundaries`, `pushBoundary()`, and `resolveEntryBoundary()`.
- `src/offload/pipelines/l2-mermaid.ts`: L2 grouping by `resolveEntryBoundary(entryIndex)`.
