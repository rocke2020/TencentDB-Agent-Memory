# memory-tencentdb Workflow

> TL;DR: memory-tencentdb has two related memory flows. Conversation memory preserves useful information across sessions. Context offload reduces prompt tokens during tool-heavy chats by moving raw tool results out of the active prompt, retaining compact summaries and Mermaid task state, and preserving references for evidence recovery. Skill generation is an optional manual backend capability, not part of the normal online-chat workflow or the reason to enable context offload.

## 1. Architecture Summary

memory-tencentdb has two related paths: conversation memory and context offload. The conversation-memory path remembers cross-session facts, scenes, and persona context. The context-offload path has one primary online-chat purpose: reduce the tool-history tokens sent to the model without making compressed-away results irrecoverable.

```text
Before a turn:
  recall L1 records + L2 scene navigation + L3 persona
  -> inject compact context for the agent

After a turn:
  capture raw messages as L0
  -> schedule conversation-memory L1/L2/L3 extraction

During tool-heavy work:
  archive raw tool results and create compact L1 summaries
  -> assign task boundary with L1.5
  -> build/update L2 Mermaid task graph
  -> let local L3 replace or remove bulky historical prompt messages
  -> inject compact task state so the agent keeps direction
```

The two flows share the same memory philosophy: lower layers preserve evidence, upper layers preserve structure. They differ in scope and timing.

```text
Path / component          Purpose                         Main artifacts
Conversation memory       Cross-session recall             conversations/, records/, scene_blocks/, persona.md
Context offload L1/L1.5/L2 Compression support + recovery   offload-*.jsonl, refs/*.md, mmds/*.mmd
Context offload L3         Prompt token reduction           mutated event.messages, replacement/deletion state
```

Product wording can make these paths sound more unified than the current implementation is. The current code keeps the two runtime paths separate. Conversation memory owns L0/L1/L2/L3 persona extraction and recall. Context offload owns tool-result archiving, compact summaries, MMD task graphs, and local prompt compression.

Two names are especially easy to misread:

```text
L3 compression   Context offload only. It mutates event.messages using offload rows and MMD metadata.
L3 persona       Conversation memory only. It generates/recalls persona.md from scene data.
```

The backend also exposes optional L4 Skill generation from an existing MMD and its node-linked offload rows. It is manually triggered, unsupported in local offload mode, and outside the normal prompt-reduction path.

## 2. Turn-Level Runtime

Each user turn has a recall phase before the model runs and a capture phase after the turn is committed. Recall is latency-bounded and best-effort; capture is durable and feeds the extraction scheduler. Offload contributes to the main chat path primarily during prompt construction and tool-loop message shaping: it injects compact task context, compresses old tool logs, and preserves drill-down links, but it does not feed the conversation-memory L1/L2/L3 extraction.

```text
user prompt
  -> TdaiCore.handleBeforeRecall()
  -> performAutoRecall()  [raced against recall.timeoutMs, default 5s; on timeout injects nothing]
       -> search L1 structured records by keyword, embedding, or hybrid search
       -> load persona.md as L3 persona context
       -> load scene index/navigation as L2 context
       -> return dynamic prependContext + stable appendSystemContext
  -> host builds the LLM prompt
       -> offload may inject active MMD context
       -> offload may replace/delete old tool logs under token pressure
  -> agent works
  -> TdaiCore.handleTurnCommitted()
  -> performAutoCapture()
       -> atomically write new raw messages as L0
       -> index L0 into the configured store when available
       -> notify MemoryPipelineManager
```

`TdaiCore` is the host-neutral facade. OpenClaw and Hermes/Gateway call the same core methods, while host-specific adapters provide runtime context, logging, and LLM runners.

## 3. Conversation Memory Workflow

The conversation-memory workflow is the semantic pyramid described by the main README: L0 conversation -> L1 atom/record -> L2 scene -> L3 persona. It runs after turns are committed and is scheduled per session.

```text
L0 Conversation
  raw user/assistant/tool messages in conversations/
  optional vector/FTS indexing for conversation search

L1 Record
  extracted atomic memories in records/ and store backend
  searchable by tdai_memory_search and auto-recall

L2 Scene
  scene blocks and scene index under scene_blocks/
  injected as navigation so the agent can inspect full scene files

L3 Persona
  persona.md generated from scene data
  stable user/profile context injected on future turns
```

Trigger behavior is scheduler-driven:

```text
agent_end / sync_turn
  -> L0 capture
  -> notifyConversation(sessionKey)
  -> L1 fires by warm-up threshold, conversation count, idle timeout, or shutdown flush
  -> L2 fires after L1 with min/max interval guards
  -> L3 persona generation is queued after L2
```

L1 extraction reads from the store when available and falls back to L0 JSONL files. L2 and L3 use LLM runners when configured, with queueing and deduplication in `MemoryPipelineManager`.

For the detailed artifact-generation path, see `docs/conversation-memory/l0-l3-generation.md`.

## 4. Context-Offload Workflow

The context-offload workflow exists to reduce prompt tokens during the current online chat while keeping removed tool evidence recoverable. L1, L1.5, and L2 prepare compact replacement and task-state artifacts; L3 is the in-process consumer that actually changes the prompt sent to the model.

```text
after_tool_call event
  -> ToolPair buffer
  -> L1 flush writes refs/*.md + offload-<sessionId>.jsonl
  -> L1.5 records a task boundary for future rows
  -> L2 converts eligible rows into Mermaid nodes
  -> L2 backfills node_id into JSONL rows
  -> L3 replaces large historical tool messages with L1 summaries
  -> under greater pressure, L3 removes old messages and injects compact MMD state
  -> model receives a smaller prompt with drill-down references preserved
```

Layer responsibilities:

```text
Layer   Responsibility
L1      Summarize each useful tool result and preserve the raw result in refs/*.md
L1.5    Decide whether future rows belong to a long-task MMD and which MMD to target
L2      Patch/write mmds/*.mmd and backfill node_id for selected rows
L3      Locally replace/delete prompt messages when token thresholds require it
```

L1/L1.5/L2 do not themselves save prompt tokens merely by writing files. Their online value is that they give L3 compact, attributable substitutes for bulky tool history and give the agent a task map after older detail leaves the prompt.

The important state transition for offload rows is:

```text
node_id: null
  -> node_id: "wait"
  -> node_id: "001-N18" or another concrete Mermaid node id
```

`null` means L1 has captured the row but L2 has not attributed it. `wait` means L2 selected the row and is processing it. A concrete node id means the row is traceable from a Mermaid task node back to the JSONL summary and then to the raw ref.

## 5. Prompt Token Reduction

Prompt reduction happens when offload L3 mutates the current `event.messages` before a model call. This is the operational payoff of the preceding materialization stages: verbose tool results can leave the active prompt while their summaries, task relationships, and raw references remain available.

The normal reduction flow is:

```text
before_prompt_build
  -> reapply previously confirmed replacements and deletions to replayed history
  -> count the current prompt tokens
  -> below mild threshold: apply no new compression and inject active MMD if available
  -> mild pressure: replace selected old tool results/tool-use blocks with L1 summaries
  -> aggressive pressure: remove an old history prefix while preserving valid tool pairing
  -> emergency pressure: delete or truncate additional non-user history
  -> inject active/history MMD context for compact task continuity
```

The storage chain makes this reduction recoverable:

```text
compact L1 summary in the prompt
  -> tool_call_id / node_id in offload-*.jsonl
  -> result_ref
  -> full raw tool result in refs/*.md
```

Mild replacement avoids spending tokens on the full result when a shorter L1 summary is sufficient. Aggressive and emergency modes reclaim more space by removing history, while MMD injection preserves a compact view of task progress and recovery links. Confirmed replacements/deletions are recorded and reapplied because the host may replay the original history on a later prompt build.

Optional capability note: backend mode can manually generate a `skills/<skillName>/SKILL.md` from `/create-skill`, using an MMD plus its node-linked offload rows. That path does not reduce prompt history, is not called during ordinary chat, and is unsupported by local offload mode.

## 6. Storage and Traceability

The workflow preserves drill-down paths instead of relying on irreversible summarization. The agent can reason over compact structures, then recover raw evidence when needed.

```text
Conversation memory recall:
  persona.md / scene navigation / recalled L1 record
    -> scene file or memory record
    -> L0 conversation search when exact wording matters

Context offload:
  Mermaid node_id in mmds/*.mmd
    -> offload-*.jsonl row with summary + result_ref
    -> refs/*.md raw tool result
```

The main physical layout is:

```text
<pluginDataDir>/
+-- conversations/        L0 raw conversation files
+-- records/              L1 extracted memory records
+-- scene_blocks/         L2 scene files and index
+-- persona.md            L3 persona profile
+-- vectors.db            SQLite-style local store when configured
+-- <offload-agent>/      offload data, grouped by agent name
    +-- state.json
    +-- offload-*.jsonl
    +-- refs/
    +-- mmds/
```

Store backends abstract SQLite, BM25, embeddings, and Tencent Cloud VectorDB behind `IMemoryStore`. The core workflow should call store interfaces and pipeline utilities rather than duplicating storage-specific logic.

## 7. Recall and Search

Recall runs **once per user turn** — not once per session, and not on every model call inside the tool loop. It happens in `before_prompt_build` -> `TdaiCore.handleBeforeRecall()` -> `performAutoRecall()`, gated by a non-empty user prompt (`event.prompt`); tool-loop continuation calls that carry no fresh prompt skip recall. It is on the critical path and bounded by a hard timeout, racing the actual work against `recall.timeoutMs` (default 5s); on timeout it injects nothing rather than block the user. By default it injects only compact context, then exposes tools for deeper retrieval, keeping the prompt small while preserving access to detailed evidence.

Recall is **not session-scoped and there is no separate session-start injection path**. `performAutoRecall` ignores the session key and reads the global per-data-dir stores (`persona.md`, the scene index, and all L1 records across sessions). A new session therefore recalls prior-session memory on its first user turn through the same per-turn path — selection is by relevance to the current prompt (plus the always-injected persona and scene navigation), not by recency.

Recall performs three independent reads and splits the result for prompt caching:

```text
Auto recall injects:
  L1 relevant memories        -> dynamic prependContext    (user-prompt prefix, changes every turn)
  L3 persona                  -> stable appendSystemContext (system-prompt end, cacheable)
  L2 scene navigation         -> stable appendSystemContext (system-prompt end, cacheable)
  memory tool guide           -> stable appendSystemContext (system-prompt end, cacheable)
```

The split is deliberate: per-turn L1 memories stay out of the system prompt so they do not bust the provider prompt cache, while the rarely-changing persona/scene/tools-guide region stays cacheable.

L1 search is query-driven and strategy-configurable (`recall.strategy`, default hybrid):

```text
keyword     FTS5 BM25 over L1 records
embedding   VectorStore cosine similarity
hybrid      keyword + embedding merged with RRF (k=60);
            TCVDB serves dense + sparse + RRF in one native call
```

Search defaults and guards:

```text
maxResults          5     top-N memories injected
scoreThreshold      0.3   minimum relevance score
embedding fallback        falls back to keyword when embedding resources are unavailable
small-corpus guard        return top FTS5 matches even below threshold (BM25 IDF -> 0 on tiny doc sets)
recall budget             per-memory + total char caps, with a truncation suffix pointing to the search tools
```

Active retrieval tools (capped at 3 search calls per turn):

```text
tdai_memory_search         Search structured L1 memories
tdai_conversation_search   Search raw L0 conversations
read_file                  Read full scene files from scene navigation
```

Cost boundary: auto recall itself does **not** add a separate chat-model call. It performs store/search work before the normal model call: FTS/BM25 lookup, vector or TCVDB hybrid search when enabled, `persona.md` read, scene-index read, and prompt assembly. The memory tool guide is prompt policy, not a controller; if the model later decides the injected summaries are insufficient and calls `tdai_memory_search` or `tdai_conversation_search`, that tool call enters the normal tool loop and can add another model round to consume the tool result.

The intended usage is progressive disclosure: start with injected summaries, search structured memory when the summary is not enough, and inspect raw conversation or scene files only when the exact evidence matters.

The injected `<relevant-memories>` block is turn-local scaffolding: `before_message_write` strips it from the user message before the turn is persisted to L0, so historical transcripts stay clean for future replays.

## 8. Operational Boundaries

Conversation-memory L3 and offload L3 have different meanings. In the conversation-memory path, L3 is the persona layer. In context offload, L3 is the local compression algorithm and the stage that delivers prompt-token reduction.

Key boundaries:

```text
Boundary                            Meaning
Offload L1 -> L1.5 -> L2            Prepare summaries, evidence refs, and compact task state
Offload L3                          Reduce prompt tokens using those prepared artifacts
Conversation L0 -> L1 -> L2 -> L3   Conversation memory extraction into persona
Collect mode                        Runs L1/L1.5/L2 collection, skips L3 compression and MMD injection
```

Because collect mode skips L3 and MMD injection, it records offload artifacts but does not provide the primary online-chat benefit described here.

When debugging, start at the layer that owns the missing artifact:

```text
No raw conversation              Check L0 capture and checkpoint cursor
No structured memory             Check L1 extraction scheduler and store writes
No scene navigation              Check L2 scene extraction and scene index
No persona                       Check L3 persona trigger/generator
No offload JSONL row             Check offload L1 capture/flush
Offload row stays null           Check L1.5 boundary and L2 trigger eligibility
Offload row stays wait           Check L2 generation/backfill failure
Prompt not compressed            Check collect mode, patch effectiveness, and L3 thresholds
```

## 9. Code Map

These files are the main entry points for understanding and changing the workflow. Keep changes at the layer that owns the behavior.

```text
src/core/tdai-core.ts                  host-neutral facade
src/core/hooks/auto-recall.ts          before-turn memory injection
src/core/hooks/auto-capture.ts         after-turn L0 capture and scheduler notification
src/utils/pipeline-manager.ts          conversation-memory L1/L2/L3 scheduling
src/utils/pipeline-factory.ts          store, runner, extractor, persona wiring
src/core/store/                       SQLite/BM25/embedding/TCVDB abstractions

src/offload/index.ts                   offload registration and L1/L1.5/L2 orchestration
src/offload/hooks/after-tool-call.ts   tool result capture and in-loop checks
src/offload/hooks/before-prompt-build.ts pre-LLM offload/L3/MMD handling
src/offload/pipelines/l2-mermaid.ts    Mermaid generation and node_id backfill
src/offload/hooks/llm-input-l3.ts      local prompt compression
src/offload/backend-client.ts          backend L1/L1.5/L2 requests and optional L4 command
src/offload/storage.ts                 offload JSONL, refs, MMD, and state storage
```
