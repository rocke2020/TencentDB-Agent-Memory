# L1 Context Offload Summary

> TL;DR: L1 is the tool-result summarizer. It turns buffered tool invocations into one JSONL row per useful tool result, writes the full raw result to `refs/*.md`, and leaves `node_id: null` until L2 later assigns a Mermaid node. L1 does not decide task ownership and does not mutate the prompt; it creates the durable rows that L1.5/L2/L3 use.

## 1. Role

L1 is the first persistent layer in context offload. It converts transient `after_tool_call` events into compact, recoverable records.

```
after_tool_call event
  -> ToolPair buffer
  -> flushL1()
  -> refs/*.md raw-result backup
  -> backend/local L1 summarizer
  -> offload-<sessionId>.jsonl rows
```

Each L1 row describes one tool invocation result, not one user turn and not one assistant reply. The assistant's own text can appear in recent context, but it is not the extraction target.

## 2. Input

L1 consumes buffered `ToolPair` objects. A pair is created by `after_tool_call` after basic filtering.

```ts
{
  toolName,
  toolCallId,
  params,
  result,
  error,
  timestamp,
  durationMs
}
```

The hook skips duplicate tool IDs, heartbeat calls, and approval-pending calls before buffering. The L1 flush path also filters `HEARTBEAT.md` pairs before sending a batch to the summarizer.

L1 sends two inputs to the summarizer:

```
recentMessages    Recent conversation context, used only as reference
toolPairs         The actual extraction target: params + result per tool call
```

## 3. Trigger

L1 runs from several paths, but all roads go through `flushL1()`.

```
Trigger path                         What happens
pending count threshold              Flushes buffered tool pairs once enough accumulate
L1.5 pre-flush                       Flushes pairs that existed before the latest user boundary
before_prompt_build                  Fire-and-forget flush before prompt construction
forced output marker                 `llm-output` can mark the next cycle for L1 flush
```

The important sequencing rule is L1.5 pre-flush:

```
old pending tool pairs
  -> L1 writes rows
  -> entryCounter advances
  -> L1.5 snapshots startIndex
  -> later rows fall under the new boundary
```

That keeps older tool work from being attributed to a newer user task.

## 4. Output

The output is one `OffloadEntry` per summarized tool result:

```ts
{
  timestamp: string,
  node_id: string | null,
  tool_call: string,
  summary: string,
  result_ref: string,
  tool_call_id: string,
  session_key?: string,
  score?: number
}
```

Fresh L1 rows have `node_id: null`. The local parser enforces this for local LLM mode, and the fallback path also writes `node_id: null`.

Example shape:

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

## 5. Persistence

L1 writes two durable artifacts:

```
refs/*.md                  Full raw tool result backup
offload-<sessionId>.jsonl  Compact summary rows, one JSON object per line
```

The raw ref is written before summarization so L3 can later replace or delete prompt messages without losing recoverability. If the L1 response omits `result_ref`, local code fills it from the ref written for the same `tool_call_id`.

`appendOffloadEntries()` deduplicates by `tool_call_id` at write time. It also treats underscore-stripped IDs as equivalent, which protects against provider/tool-call ID shape drift.

## 6. Batching and Failure

L1 batches tool pairs in chunks of 5. Each chunk is tracked by the first `toolCallId`.

```
success
  -> append backend entries
  -> increment entryCounter by rows written

failure before retry limit
  -> re-enqueue the chunk
  -> clear processed IDs for those calls

failure at retry limit
  -> write degraded fallback entries
  -> score: 0
  -> summary starts with [L1 degraded]
```

The degraded path means memory capture can continue even when the L1 LLM path is unavailable. The fallback row is less useful for L3 replacement because its summary is crude and its score is `0`, but it preserves the raw result reference and keeps the pipeline moving.

## 7. Relationship to L1.5 and L2

L1 writes rows; L1.5 decides which future rows belong to which task; L2 writes the task graph and backfills node IDs.

```
L1    writes node_id: null rows
L1.5  records boundary { startIndex, result, targetMmd }
L2    selects eligible null/wait rows covered by long-task boundaries
L2    rewrites selected rows to concrete node IDs
```

So the usual lifecycle is:

```
null -> wait -> 001-N18
```

`wait` is set by L2 while a selected batch is being processed. A final concrete node ID means the row has been attributed to an MMD node. L1 itself does not perform either transition.

## 8. Relationship to L3

L3 uses L1 rows as the lookup table for prompt compression.

```
tool_call_id in prompt message
  -> lookup matching L1 row
  -> use summary/result_ref/score/node_id
  -> replace, delete, or protect the prompt message
```

The `score` field is assigned by L1 and later used by L3's score-cascade replacement. Higher scores mean the tool result is more safely replaceable by its summary.

`node_id` also matters to L3 once L2 has backfilled it: current-task nodes can be protected from aggressive compression so the active work is less likely to be removed.

## 9. Code References

The key code paths are:

- `src/offload/hooks/after-tool-call.ts`: captures useful tool calls as `ToolPair` objects and skips duplicates, heartbeats, and approval-pending calls.
- `src/offload/index.ts`: `flushL1()`, batching, backend request construction, retry handling, fallback entries, and `entryCounter` increments.
- `src/offload/storage.ts`: `appendOffloadEntries()`, JSONL sanitization, write-time deduplication, and all-session reads.
- `src/offload/local-llm/parsers/l1-parser.ts`: local L1 parser that creates entries with `node_id: null`.
- `src/offload/types.ts`: `OffloadEntry` and `ToolPair` contracts.

