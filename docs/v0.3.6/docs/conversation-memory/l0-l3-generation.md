# Conversation Memory L0-L3 Generation

> TL;DR: Conversation memory artifacts are generated after a turn is committed, not during recall. L0 captures raw messages, the scheduler decides when to run L1, L1 extracts structured memory records, L2 consolidates those records into scene files and a scene index, and L3 generates `persona.md` from the scene data for future recall.

## Runtime Entry

The generation path starts after the agent turn, when capture receives committed messages. Recall only reads previously generated artifacts; it does not create L1 records, L2 scenes, or L3 persona content.

Here `agent_end / sync_turn` means the host signal for one completed agent turn: from one user input through the model's final assistant response, including any intermediate tool calls and tool-loop model calls. In OpenClaw this signal is the `agent_end` hook; in Hermes/Gateway-style integration the equivalent path is `sync_turn` or `/capture`. Both enter `TdaiCore.handleTurnCommitted()` and then `performAutoCapture()`.

```text
agent_end / sync_turn
  -> performAutoCapture()
  -> recordConversation()                 # L0
  -> scheduler.notifyConversation()
  -> L1 runner when threshold/idle/flush fires
  -> L2 runner after L1 with interval guards
  -> L3 runner after L2 if persona trigger says yes
```

Primary code:

- `src/core/hooks/auto-capture.ts`
- `src/utils/pipeline-manager.ts`
- `src/utils/pipeline-factory.ts`
- `src/core/record/l1-extractor.ts`
- `src/core/scene/scene-extractor.ts`
- `src/core/persona/persona-generator.ts`

## L0 Capture

L0 is the durable raw-conversation layer. It records the new committed messages locally first, then optionally indexes them into the configured store for L0 conversation search.

`performAutoCapture()` does three things:

1. Uses `CheckpointManager.captureAtomically()` to read the per-session cursor, write only new messages, and advance the cursor in one locked operation.
2. Writes L0 search/index data to `IMemoryStore` when available.
3. Calls `scheduler.notifyConversation(sessionKey, [])`.

The empty array in `notifyConversation(sessionKey, [])` is intentional. L1 does not consume an in-memory message buffer from capture; the L1 runner later reads new L0 rows from VectorStore or from L0 JSONL files using the checkpoint cursor.

Artifacts:

```text
conversations/                  raw L0 JSONL conversation files
store L0 tables / collections    optional L0 metadata, FTS, vector index
.metadata/recall_checkpoint.json capture and pipeline cursors
```

## Pipeline Scheduling

`MemoryPipelineManager` owns when extraction happens. Capture only notifies the scheduler; it does not directly run L1/L2/L3 extraction.

L1 trigger paths:

```text
conversation threshold     conversation_count >= effectiveThreshold
idle timeout               session has been quiet for l1IdleTimeoutSeconds
shutdown/session flush     pending work is drained before stop/end
```

With warm-up enabled, new sessions use an effective threshold sequence that doubles and is capped by `everyNConversations`. With the current default `everyNConversations = 5`, the threshold batches are `1 -> 2 -> 4 -> 5 -> 5 ...`. This makes the first memories available quickly, then reduces extraction frequency as the session matures.

Example when `everyNConversations = 5`, warm-up is enabled, and no idle timeout fires between turns:

```text
Turn 1  conversation_count=1/1  -> L1 runs for turn 1, then next threshold becomes 2
Turn 2  conversation_count=1/2  -> no threshold run yet
Turn 3  conversation_count=2/2  -> L1 runs for turns 2-3, then next threshold becomes 4
Turn 4  conversation_count=1/4  -> no threshold run yet
Turn 5  conversation_count=2/4  -> no threshold run yet
Turn 6  conversation_count=3/4  -> no threshold run yet
Turn 7  conversation_count=4/4  -> L1 runs for turns 4-7, then warm-up graduates to steady 5
Turn 12 conversation_count=5/5  -> L1 runs for turns 8-12
```

If the session is quiet for `l1IdleTimeoutSeconds` before a threshold is reached, the idle timer fires earlier and L1 processes whatever has accumulated since the last L1 cursor. For example, if turn 2 is followed by a long pause, turn 2 can be extracted alone before turn 3 arrives.

L2 trigger paths:

```text
after L1 completes         fire after delayAfterL1Seconds, but not before minInterval
max interval guarantee     run periodically while the session is still active
shutdown flush             drain pending L2 timers
```

L3 is global rather than per-session. After L2 completes, the scheduler enqueues one persona-generation task; if another L2 finishes while L3 is running, it marks L3 pending and runs it again afterward.

## L1 Records

L1 turns raw conversation messages into structured, searchable memory records. It uses one LLM extraction pass for scene segmentation plus memory extraction, then optionally performs batch deduplication before writing records.

The standard L1 runner:

1. Reads new L0 messages for the session:
   - primary: `vectorStore.queryL0GroupedBySessionId(sessionKey, l1Cursor)`
   - fallback: `readConversationMessagesGroupedBySessionId(...)`
2. Groups messages by `sessionId`.
3. Calls `extractL1Memories()` for each group.
4. Advances the L1 checkpoint cursor with `markL1ExtractionComplete()`.

`extractL1Memories()` then:

1. Applies the L1 quality gate via `shouldExtractL1()`.
2. Splits qualified messages into recent `newMessages` and older `backgroundMessages`.
3. Calls the LLM with `EXTRACT_MEMORIES_SYSTEM_PROMPT`.
4. Parses scene-segmented output containing `scene_name`, `message_ids`, and `memories`.
5. Normalizes memory types to `persona`, `episodic`, or `instruction`.
6. Limits the batch to `extraction.maxMemoriesPerSession`.
7. Runs `batchDedup()` when enabled.
8. Writes final records with `writeMemory()`.

Artifacts:

```text
records/YYYY-MM-DD.jsonl      append-only L1 record shard
store L1 tables / collections searchable L1 metadata, FTS, and vectors
```

Each L1 record includes:

```text
id
content
type                       persona | episodic | instruction
priority
scene_name
source_message_ids
metadata
timestamps
createdAt / updatedAt
sessionKey / sessionId
```

## L2 Scene Navigation

L2 consolidates L1 records into scene documents and an index. The recall path injects only the scene navigation, while full scene files remain available for on-demand `read_file`.

The L2 runner:

1. Reads L1 records updated after the last L2 cursor:
   - primary: `queryMemoryRecords(vectorStore, { sessionKey, updatedAfter })`
   - fallback: `readMemoryRecords(sessionKey, pluginDataDir)`
2. Passes those records to `SceneExtractor.extract()`.
3. Updates the L2 cursor to the latest processed record `updatedAt`.
4. Increments scene-processing checkpoint counters.

`SceneExtractor` is a tool-enabled LLM agent sandboxed to `scene_blocks/`. It receives the new L1 memories, current scene summaries, existing scene filenames, the current timestamp, and scene-count constraints. The LLM creates, updates, merges, or soft-deletes scene `.md` files; engineering code then cleans up soft deletes, normalizes filenames, and rebuilds the index.

Scene count is capped by `persona.maxScenes` (default 15, `src/config.ts`). The cap is a prompt-attention budget, not a storage limit — the LLM must reason about every scene summary at once when choosing CREATE/UPDATE/MERGE/DELETE, and merge quality degrades as N grows. A tiered warning is injected into the prompt based on current count:

| scenes | level | LLM is forced to |
|---|---|---|
| ≥ maxScenes | red | MERGE 2-4 → 1 first, delete merged files, then process |
| = maxScenes-1 | orange | UPDATE only, CREATE blocked |
| ≥ maxScenes-3 | yellow | prefer UPDATE / proactive MERGE |

So "more scenes" is absorbed by MERGE, not by raising the cap. If a long-running user genuinely needs more: bump `persona.maxScenes` (fine up to ~30); beyond that the real fix is hierarchical scenes (top-level domains + sub-scenes, LLM sees only the relevant slice), since the flat `scene_blocks/` + single `scene_index.json` model assumes O(15) entries.

Artifacts:

```text
scene_blocks/*.md             L2 scene narrative files
.metadata/scene_index.json    rebuilt index of scene filename, summary, heat, created, updated
persona.md                    navigation section may be refreshed after L2
```

Scene navigation is generated from `.metadata/scene_index.json` by `generateSceneNavigation()`. It renders absolute paths to `scene_blocks/*.md` so the agent can use `read_file` only when it needs full evidence.

## L3 Persona

L3 generates stable user/profile context from the scene layer. It is triggered after L2, but it only writes `persona.md` when `PersonaTrigger` says generation is needed.

`PersonaTrigger.shouldGenerate()` returns true for these cases:

```text
explicit persona update request
first scene extraction with no persona yet
existing persona body missing or empty
first scene block extraction
memories_since_last_persona >= persona.triggerEveryN
```

When triggered, `PersonaGenerator.generateLocalPersona()`:

1. Reads existing `persona.md` and strips any old scene navigation.
2. Reads `.metadata/scene_index.json`.
3. Selects scenes changed since the last persona generation.
4. Reads the full changed scene files.
5. Builds the persona prompt.
6. Runs a tool-enabled LLM agent in the data directory.
7. Requires the LLM to write `persona.md`.
8. Strips accidental navigation, escapes XML-like tags, and rejects empty output.
9. Appends fresh scene navigation and writes the final `persona.md`.
10. Marks persona generation complete in the checkpoint.

Artifact:

```text
persona.md                    L3 user narrative profile + generated scene navigation
```

## Recall Consumption

Recall consumes artifacts that were already generated by the post-turn pipeline. It does not run L1, L2, or L3 generation.

On a future user turn, `performAutoRecall()`:

```text
L1 records        search by keyword / embedding / hybrid -> <relevant-memories>
L3 persona        read persona.md body                    -> appendSystemContext
L2 navigation     read scene_index + generate nav          -> appendSystemContext
memory tool guide append static retrieval policy           -> appendSystemContext
```

This split keeps dynamic per-turn L1 memories out of the system prompt while keeping persona, scene navigation, and tool guidance cacheable.

## Debugging Map

Start from the layer that owns the missing artifact. A missing later layer is often caused by an earlier layer not producing input.

```text
No raw conversation
  Check L0 capture, checkpoint cursor, and conversations/ or store L0 rows.

No structured memory
  Check L1 scheduler triggers, L1 cursor, extraction LLM output, dedup decisions, and records/ or store L1 rows.

No scene navigation
  Check L2 timer/cursor, L1 records updated after last L2 cursor, scene_blocks/, and .metadata/scene_index.json.

No persona
  Check L3 trigger conditions, changed scene files, persona-generation LLM run, and persona.md write/post-processing.
```

Related overview: `docs/workflow.md`.
