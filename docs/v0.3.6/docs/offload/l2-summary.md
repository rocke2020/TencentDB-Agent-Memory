# L2 Context Offload Summary

> TL;DR: L2 reads all saved L1 JSONL rows for the current agent, but only unresolved rows (`node_id: null`) and retry rows (`node_id: "wait"`) are eligible for a new L2 pass. L2 sends those new eligible rows plus existing MMD text to the backend, applies the returned Mermaid patch/write, then backfills only the current batch's rows to concrete node IDs. Existing historical rows that already have concrete node IDs are not automatically re-mapped if a later MMD patch changes a node.

## 1. Role

L2 is the Mermaid memory builder. It turns L1 tool-call summaries into task-level graph nodes inside a selected MMD, then writes the chosen node ID back into the L1 JSONL rows.

The core split is:

```
L1    writes one JSONL row per tool result, initially node_id: null
L1.5  creates/selects the target MMD via runtime boundaries
L2    groups eligible L1 rows by boundary target, patches/writes MMD, backfills node_id
```

L2 does not decide the task boundary from scratch. It asks `stateManager.resolveEntryBoundary(entryIndex)` which L1.5 decision covers each unresolved row.

## 2. Eligible Rows

L2 scans all `offload-*.jsonl` files under the current agent data directory, but it does not process every row. The first filter is strict:

```ts
if (entry.node_id !== null && entry.node_id !== "wait") continue;
```

That means:

```
node_id: null    eligible as new unresolved L1 data
node_id: "wait" eligible as retry data, after wait timeout
node_id: "003-N3" skipped as already attributed
```

After that filter, L2 asks the runtime boundary which MMD owns the row:

```ts
const boundary = stateManager.resolveEntryBoundary(i);
if (!boundary) continue;
if (boundary.result !== "long") continue;
if (!boundary.targetMmd) continue;
```

So "L2 scans history" means "L2 reads all saved L1 rows, then filters down to unresolved/retry rows covered by a current long-task boundary." It does not revisit stable concrete-node rows in normal scheduling.

## 3. Trigger

L2 is independently scheduled after L1/L1.5, not called directly by L1. The trigger check reads all saved entries and groups eligible rows by target MMD.

Current trigger conditions are:

```
null_count >= l2NullThreshold
time since last L2 >= l2TimeoutSeconds
no prior L2 + retry-wait rows
no prior L2 + oldest null row age >= timeout
```

If `l2TimeTriggerRequiresNewOffload` is true, the time-based trigger requires a new `node_id: null` row newer than the last L2 time, except for retry-wait cases.

## 4. L2 Input

For each target MMD, L2 batches eligible rows and sends the backend a request containing existing graph text plus only the new eligible rows in that batch.

```ts
{
  existingMmd,
  newEntries: [
    { tool_call_id, tool_call, summary, timestamp }
  ],
  recentHistory,
  currentTurn,
  taskLabel,
  mmdPrefix,
  mmdCharCount
}
```

In local LLM mode, the prompt includes:

```
Existing Mermaid content:
L1: ...
L2: ...

New offload entries to incorporate:
1. [tool_call_id] tool_call -> summary (timestamp)
```

This input shape explains the common behavior: L2 usually appends a new node or updates a nearby existing node to incorporate the current batch. But the implementation and prompt are not append-only.

## 5. L2 Output

The backend returns a structured result:

```ts
{
  fileAction: "replace" | "write",
  mmdContent?: string,
  replaceBlocks?: Array<{ startLine, endLine, content }>,
  nodeMapping: Record<string, string>
}
```

A real `replace` output, from the L2 pass that attributed L1 row `call_00_kBGKGk2bcXG0GcRlwJ2O7918` into `003-hulunbuir-family-trip-plan.mmd`:

```json
{
  "fileAction": "replace",
  "replaceBlocks": [
    {
      "startLine": 4,
      "endLine": 4,
      "content": "    003-N1 -.-> 003-N3[\"排查超时故障（无关）<br/>status: blocked<br/>summary: 发现stuckSessionAbortMs=300000可能为超时根因，但与当前旅行任务无关，标记为弃用。<br/>Timestamp: 2026-06-16T08:56:55.713+08:00\"]"
    }
  ],
  "nodeMapping": {
    "call_00_kBGKGk2bcXG0GcRlwJ2O7918": "003-N3"
  }
}
```

The local code patches line 4 of the MMD with the new `003-N3` node, then backfills the matching L1 row's `node_id` from `null`/`wait` to `003-N3` via `nodeMapping`.

`replace` applies line-based patches. `write` overwrites the whole MMD. The local code does not interpret graph semantics; it applies the returned text.

The local prompt allows:

```
replace: small updates to existing node status/timestamp/text, or appending a few nodes
write: full rewrite for major restructuring or initialization
```

So current behavior is best described as "new eligible rows drive the update, usually append/update, but backend output can patch existing lines or rewrite the file."

## 6. Wait Rows

`wait` is a transient retry marker. Before calling the backend, L2 rewrites selected `null` rows to `node_id: "wait"`:

```ts
if (batchWaitIds.has(entry.tool_call_id) && entry.node_id === null) {
  entry.node_id = "wait";
}
```

If the backend succeeds, L2 rewrites those rows again to concrete node IDs using `nodeMapping` or a fallback derived from the MMD:

```ts
const mapped = mapping[entry.tool_call_id];
if (mapped) entry.node_id = mapped;

if (entry.node_id === "wait" && waitIds.has(entry.tool_call_id)) {
  entry.node_id = effectiveFallback;
}
```

In normal final data, `wait` should disappear. A saved `wait` row means L2 started processing that row but did not complete backfill, for example backend failure, mapping/fallback failure, or process interruption.

## 7. Pending Null Rows

> A `node_id: null` row is not lost or orphaned — it is a **pending** row awaiting attribution. L2 re-scans every null row on each cycle and backfills it to a concrete node ID the first time the row is covered by a long-task boundary with a target MMD. Until then it stays null and is retried.

L1 always writes a new row as `node_id: null`. The row is updated only by a later L2 run, and only if §2's eligibility holds for it at that time:

```
L1 writes                                   node_id: null            (pending)
L2 run, row covered by long + targetMmd  →  wait → backfill          node_id: "003-N3"  (attributed)
L2 run, row covered by short / no boundary  skipped, stays null      (pending, retried next cycle)
```

Real before → after for the same row (`call_00_kBGKGk2bcXG0GcRlwJ2O7918`):

```jsonc
// pending — as L1 first wrote it
{ "tool_call_id": "call_00_kBGKGk2bcXG0GcRlwJ2O7918",
  "tool_call": "exec: 检查 stuckSessionAbortMs=300000 ...", "node_id": null }

// after an L2 run that covered it with the 003 long-task MMD
{ "tool_call_id": "call_00_kBGKGk2bcXG0GcRlwJ2O7918",
  "node_id": "003-N3", "result_ref": "refs/2026-06-16T08-56-55-713p08-00.md" }
```

A row stays null whenever **no long-task MMD boundary has covered it yet**. That boundary comes from L1.5, so the causes are:

```
L1.5 not called / not settled    no boundary pushed → resolveEntryBoundary = null → skipped   (index.ts:910)
L1.5 failed (after retry)         fail-safe pushes SHORT boundary, activeMmd=null → skipped     (index.ts:541-543)
L1.5 succeeded but judged short   short boundary by design → skipped                            (index.ts:635-641)
```

The first two are L1.5 not running or failing; the third is normal — genuinely short tasks never get an MMD node. In all three the mechanism is the same: no long boundary means the pending null row is carried forward to the next L2 run, not discarded.

## 8. MMD Mutation

L2 can mutate an MMD in two ways:

```
replaceBlocks -> patchMmd()
mmdContent    -> writeMmd()
```

`patchMmd()` is line-based. If `endLine >= startLine`, it removes the selected line range and replaces it with returned content. If `endLine < startLine`, it inserts content before the start line. This means local code can apply deletions if the backend returns a patch that omits or replaces a line.

There is no local rule that deletes a node because its text says `status: blocked`, `无关`, or `标记为弃用`. Those are Mermaid node contents. A node disappears only if the backend/LLM returns a patch or full rewrite that removes it, or if a manual/repair process edits the file.

## 9. No Historical Reconciliation

Current code does not run a reconciliation pass like:

```
scan MMD node changes -> update all L1 rows pointing to updated/removed/renamed node IDs
```

Backfill only updates the current L2 batch:

```
current null rows -> wait -> mapped/fallback node
retry wait rows   -> mapped/fallback node
old concrete rows -> skipped
```

If L2 changes the text of node `003-N3` but keeps the same ID, old L1 rows pointing to `003-N3` remain structurally consistent. If L2 removes or renames `003-N3`, old L1 rows are not automatically migrated or reset to `null`; they keep their concrete `node_id` unless another explicit rewrite path changes JSONL.

## 10. Example: Rows 38-39

Rows 38-39 in `offload-af31ea9c-b54e-41bd-bf50-d7aa2fee1689.jsonl` currently point to `003-N3`. They may once have been `null`, then moved through `wait`, then became `003-N3` after L2 backfill.

The current `003-hulunbuir-family-trip-plan.mmd` contains:

```mermaid
003-N1 -.-> 003-N3["排查超时故障（无关）<br/>status: blocked<br/>summary: 发现stuckSessionAbortMs=300000可能为超时根因，但与当前旅行任务无关，标记为弃用。<br/>Timestamp: 2026-06-16T08:56:55.713+08:00"]
```

That `blocked`/`标记为弃用` text is not an auto-delete instruction. It is a warning/tombstone node in the graph. Future normal L2 runs will not pick the old rows again because their `node_id` is already concrete.

## 11. Code References

The key code paths are:

- `src/offload/pipelines/l2-mermaid.ts`: trigger checks, eligible-row filtering, `wait` retry handling, and `backfillNodeIds()`.
- `src/offload/index.ts`: `runL2WithBackend()`, backend request construction, `wait` marking, MMD patch/write application, and batch backfill.
- `src/offload/storage.ts`: `readAllOffloadEntries()`, `rewriteAllOffloadEntries()`, `patchMmd()`, and `writeMmd()`.
- `src/offload/local-llm/prompts/l2-prompt.ts`: local L2 prompt shape and allowed `replace`/`write` behavior.
- `src/offload/local-llm/parsers/l2-parser.ts`: local parser for `file_action`, `replace_blocks`, `mmd_content`, and `node_mapping`.
