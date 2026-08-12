# Before Prompt Build Offload Summary

> TL;DR: `before_prompt_build` is the offload prompt-shaping entry point. It coordinates pending L1 flush, optional L1.5 boundary judgment, L3 compression, and active MMD injection before the next model call. In the gateway path, active MMD is inserted directly into `event.messages` as a marked `role: "user"` message; this differs from the Context Engine `assemble()` path, which no longer directly injects active MMD into returned messages.

## 0. `/v1/responses` Gateway Flow

`/v1/responses` is the only external ingress for this flow. Each tool loop re-enters prompt building from the same session message state; `after_tool_call` runs immediately after tool execution and before any continuation model call, while heavier memory work may continue fire-and-forget in the background.

```text
/v1/responses
  -> buildAgentPrompt(payload.input)
  -> agentCommandFromIngress({ message, extraSystemPrompt, sessionKey, ... })
  -> resolve activeContextEngine = memory-tencentdb
  -> contextEngine.assemble(...)
  -> activeSession.agent.state.messages = assembled.messages
  -> before_prompt_build({ prompt, messages: activeSession.messages })
       -> maybe start L1 flush fire-and-forget
            -> L1 writes offload entries with node_id=null
            -> arm L2 poll if unresolved rows exist
       -> maybe start L1.5 judgment fire-and-forget
            -> selects or changes active MMD ownership boundary
       -> L2 poll, fire-and-forget background path
            -> wait until l15Settled, or force-settle after timeout
            -> read L1 null/wait rows
            -> use L1.5 boundary to choose target MMD
            -> update active/history MMD files and backfill node_id
       -> Fast-Path Reapply
            -> reapply confirmed L1 replacements/deletions to event.messages
       -> L3 token compression
            -> aggressive deletion / mild replacement / emergency fallback
       -> active MMD injection
            -> read latest active MMD file and mutate event.messages
  -> provider request builder consumes final messages + system prompt
  -> model call
       -> if the model returns final text:
            -> /v1/responses returns final output
       -> if the model requests tools:
            -> tool execution
            -> after_tool_call(...)
                 -> buffer tool pair
                 -> maybe mutate event.messages if the runtime supplies it
                 -> maybe start L1 flush fire-and-forget
                      -> L1 writes offload entries with node_id=null
                      -> arm L2 poll if unresolved rows exist
                      -> L2 waits for l15Settled, groups by boundary, then updates MMD/backfills node_id
            -> next before_prompt_build / model call, if the agent loop continues
```

## 1. Role

`before_prompt_build` runs just before the host builds the next LLM prompt. Its job is to make the current message list smaller and more structured for tool-heavy chats without feeding offload artifacts into the long-term memory pipeline.

```text
before_prompt_build
  -> start pending L1 flush, if tool pairs exist
  -> maybe start L1.5 task-boundary judgment
  -> collect mode: stop before prompt mutation
  -> normal mode: run prompt cleanup and compression
  -> inject active MMD context when applicable
```

The hook handles OpenClaw gateway/harness paths that expose prompt-building hooks. In context-engine mode, `OffloadContextEngine.assemble()` handles L3 compression and history MMD injection, but active MMD injection is no longer added directly by `assemble()` to its returned `messages`.

## 2. Is This L3?

No. `before_prompt_build` is a hook that may run L3.

```text
before_prompt_build hook
  includes L1 fire-and-forget flush
  includes L1.5 fire-and-forget judgment
  includes L3 local compression
  includes active MMD injection
```

L3 specifically means the local prompt-compression algorithms: fast reapply, mild score-cascade replacement, aggressive deletion with history MMD injection, and emergency deletion/truncation. The hook is broader than L3 because it also coordinates L1/L1.5 and MMD injection.

## 3. Inputs

The hook reads runtime message state and persisted offload artifacts. It mutates only the current `event.messages` array; it does not write long-term `scene_blocks/` or `persona.md`.

```text
event.messages
  current prompt message array to mutate

pending ToolPair buffer
  unflushed tool results that L1 can summarize asynchronously

offload-*.jsonl
  L1 summaries, scores, result refs, node_id, replacement/deletion flags

refs/*.md
  raw tool-result recovery files, not normally injected

mmds/*.mmd
  L2 task graphs for active/history task context

state.json/runtime state
  activeMmdFile, l15Settled, confirmedOffloadIds, deletedOffloadIds,
  cached lookup maps, force-emergency flag
```

## 4. Normal Flow

Normal mode uses `createBeforePromptBuildHandler()` after the outer hook starts L1/L1.5 side work. The handler has three main phases.

```text
outer before_prompt_build
  -> flushL1(..., fire-and-forget)
  -> if collect mode:
       -> judgeL15(..., fire-and-forget)
       -> return
  -> createBeforePromptBuildHandler()

handler phase 1
  -> filter heartbeat messages
  -> reapply confirmed replacements
  -> reapply confirmed deletions
  -> rebuild offload lookup map

handler phase 2
  -> count tokens
  -> aggressive compression if above aggressive threshold
  -> mild score-cascade compression if above mild threshold
  -> emergency compression if still above emergency threshold

handler phase 3
  -> inject active MMD if L1.5 has settled and injection is ready
```

If there are no confirmed replacements or deletions, the handler skips the heavy lookup/compression path and only attempts active MMD injection.

## 5. Runtime Split

OpenClaw has two prompt-shaping surfaces that can both affect model input, but they do not merge inside this plugin. With `/v1/responses` as the entry point and `memory-tencentdb` configured as the active context engine, the observed local OpenClaw `2026.6.8` order is: context engine `assemble()` first, `before_prompt_build` second, then the model call, with `after_tool_call` running after tool execution.

OpenClaw has a separate runtime-backend split before that prompt-shaping order becomes visible. The public docs describe two runtime families: embedded harnesses run inside OpenClaw's prepared agent loop, while CLI backends run a local CLI process and keep the model ref canonical. See the OpenClaw docs for [Agent runtimes](https://docs.openclaw.ai/concepts/agent-runtimes) and [CLI backends](https://docs.openclaw.ai/gateway/cli-backends).

```text
/v1/responses
  -> agentCommandFromIngress(...)
  -> agent runtime resolves provider/model/runtime
  -> if the execution provider is a registered CLI backend:
       -> runCliAgentWithLifecycle(...)
  -> else:
       -> runEmbeddedAgent(...)
          -> selectAgentHarness(openclaw | codex | copilot | plugin harness)
```

This means `codex` is an embedded harness/runtime, not the same thing as a CLI backend. CLI backends such as `claude-cli` are intentionally separate from embedded harness selection; the docs describe them as a conservative local-CLI fallback path rather than the usual primary path for ordinary API providers.

The local OpenClaw source matches that model. The `/v1/responses` handler enters `agentCommandFromIngress(...)`, then the runtime computes `cliExecutionProvider`. If `isCliProvider(cliExecutionProvider, runtimeConfig)` is true, it calls `runCliAgentWithLifecycle(...)` and returns that result. Otherwise it calls `runEmbeddedAgent(...)`.

`isCliProvider(...)` treats a provider as CLI-backed only when it resolves to a configured or plugin CLI backend.

After entering the embedded backend, OpenClaw still has a second selection step for the embedded harness. That is where `openclaw`, `codex`, `copilot`, or another plugin harness is chosen.

The `/opt/homebrew/lib/node_modules/openclaw/dist/*` paths in these snippets are the globally installed OpenClaw package artifacts, not source files. On this machine, `/opt/homebrew/bin/openclaw` points into that global package tree. The matching source checkout is `/Users/rocke_dong/codes/openclaw`; for this snippet, the source is `src/agents/embedded-agent-runner/run.ts`, and `selectAgentHarness(...)` itself lives in `src/agents/harness/selection.ts`. The hash in `embedded-agent-*.js` is generated by the tsdown bundle, so it can change after each build.

To refresh the global runtime from the local OpenClaw source checkout:

```sh
cd /Users/rocke_dong/codes/openclaw
pnpm install
pnpm build
pnpm link --global
```

`pnpm build` runs `scripts/build-all.mjs`, whose `tsdown` step compiles TypeScript from `src/` into `dist/`; the later postbuild steps copy runtime/plugin assets and write package metadata. `pnpm link --global` then makes the global `openclaw` command use that built checkout instead of a registry-installed package. If the global package was installed from npm, `npm install -g /Users/rocke_dong/codes/openclaw` is the package-style equivalent after the build.

```js
// /opt/homebrew/lib/node_modules/openclaw/dist/embedded-agent-BgvyyCVT.js
const agentHarness = selectAgentHarness({
  provider,
  modelId,
  config: params.config,
  agentId: params.agentId,
  sessionKey: params.sessionKey,
  agentHarnessId: params.agentHarnessId,
  agentHarnessRuntimeOverride: params.agentHarnessRuntimeOverride
});
```

```text
/v1/responses
  -> buildAgentPrompt(payload.input)
  -> agentCommandFromIngress({ message, extraSystemPrompt, sessionKey, ... })
  -> resolve activeContextEngine = memory-tencentdb
  -> contextEngine.assemble(...)
  -> activeSession.agent.state.messages = assembled.messages
  -> before_prompt_build({ prompt, messages: activeSession.messages })
  -> plugin mutates event.messages in place
  -> activeSession.prompt(...)
  -> provider request builder consumes final messages + system prompt
  -> model call
       -> final text: return /v1/responses output
       -> tool request: execute tool
            -> after_tool_call(...)
            -> next before_prompt_build / model call, if the agent loop continues
```

The Context Engine surface itself is a return-value API: the host calls `contextEngine.assemble(...)`, and the plugin returns `{ messages, estimatedTokens, systemPromptAddition }`.

```js
// /opt/homebrew/lib/node_modules/openclaw/dist/context-engine-lifecycle-TJVPBHTV.js
async function assembleHarnessContextEngine(params) {
  if (!params.contextEngine) return;
  const messages = stripRuntimeContextCustomMessages(params.messages);
  return ensureAssembleResultShape(await params.contextEngine.assemble({
    sessionId: params.sessionId,
    sessionKey: params.sessionKey,
    messages,
    tokenBudget: params.tokenBudget,
    ...params.availableTools ? { availableTools: params.availableTools } : {},
    ...params.citationsMode ? { citationsMode: params.citationsMode } : {},
    model: params.modelId,
    ...params.prompt !== void 0 ? { prompt: params.prompt } : {}
  }), params.contextEngine.info.id);
}
```

In the embedded-agent branch, the ordering is `assemble()` first, then `before_prompt_build`. The embedded path consumes the `assemble()` result by writing `assembled.messages` back to the active session message view and applying `systemPromptAddition` to the system prompt. The later `before_prompt_build` hook receives that updated message view as its mutable `messages` array.

```js
// /opt/homebrew/lib/node_modules/openclaw/dist/selection-kQiC501t.js
if (activeContextEngine) try {
  const assembled = await assembleHarnessContextEngine({
    contextEngine: activeContextEngine,
    sessionId: params.sessionId,
    sessionKey: params.sessionKey,
    messages: activeSession.messages,
    tokenBudget: params.contextTokenBudget,
    availableTools: new Set(capabilityToolNames),
    citationsMode: params.config?.memory?.citations,
    modelId: params.modelId,
    ...params.prompt !== void 0 ? { prompt: params.prompt } : {}
  });
  const assembledMessages = transcriptPolicy.repairToolUseResultPairing ? repairAttemptToolUseResultPairing(assembled.messages, isOpenAIResponsesApi) : assembled.messages;
  if (assembledMessages !== activeSession.messages) activeSession.agent.state.messages = assembledMessages;
  if (assembled.systemPromptAddition) {
    setActiveSessionSystemPrompt(prependSystemPromptAddition({
      systemPrompt: systemPromptText,
      systemPromptAddition: assembled.systemPromptAddition
    }));
  }
}
```

Only after that does the embedded-agent branch run the prompt hook. The `messages` passed to the hook come from `activeSession.messages`, so they already reflect the context engine assembly step.

```js
// /opt/homebrew/lib/node_modules/openclaw/dist/selection-kQiC501t.js
const promptBuildMessages = pruneProcessedHistoryImages(activeSession.messages) ?? activeSession.messages;
const hookResult = isRawModelRun ? void 0 : await resolvePromptBuildHookResult({
  config: params.config ?? getRuntimeConfig(),
  prompt: params.prompt,
  messages: promptBuildMessages,
  hookCtx,
  hookRunner,
  beforeAgentStartResult: params.beforeAgentStartResult
});
```

The Codex app-server branch has the same relative order. It applies the active context engine projection before it calls `resolveAgentHarnessBeforePromptBuildResult(...)`.

```js
// /opt/homebrew/lib/node_modules/openclaw/dist/run-attempt-BXh5Tiph.js
if (activeContextEngine) try {
  await applyActiveContextEngineProjection(!nativeToolSurfaceEnabled ? void 0 : startupBinding);
} catch (assembleErr) {
  log.warn("context engine assemble failed; using Codex baseline prompt", { error: formatErrorMessage(assembleErr) });
}

const buildPromptFromCurrentInputs = () => resolveAgentHarnessBeforePromptBuildResult({
  prompt: prependCurrentInboundContext(promptText, params.currentInboundContext),
  developerInstructions,
  messages: codexModelInputHistoryMessages,
  ctx: hookContext
});
let promptBuild = await buildPromptFromCurrentInputs();
```

For `/v1/responses`, the HTTP handler still does not directly call `contextEngine.assemble()`. It parses `payload.input`, builds an agent command, and the later agent runtime performs the context-engine and hook steps.

```text
/v1/responses HTTP handler
  payload.input
    -> buildAgentPrompt(payload.input)
    -> extraSystemPrompt = instructions + system/developer/file/tool-choice context
    -> agentCommandFromIngress({ message, extraSystemPrompt, sessionKey, ... })
```

So the final merge point is the OpenClaw runtime/provider layer, not this plugin. In the default active-context-engine path, context engine output is applied first, `before_prompt_build` mutates that assembled message view second, and the provider layer consumes the final messages.

## 6. Fast-Path Reapply

Fast-path reapply is the cheap, idempotent first pass inside `before_prompt_build`. It is a threshold-independent replay step, not a new L3 compression decision: it reapplies replacement/deletion decisions already recorded for this session so host-replayed raw history cannot resurrect old tool logs. The tradeoff is real because replayed decisions can hide raw tool detail from the current model call and expose only the stored summary/ref path.

The key runtime state is two tool-call id sets:

```text
confirmedOffloadIds
  tool calls that already have an accepted L1/offload entry

deletedOffloadIds
  tool calls whose historical messages were deleted by aggressive/emergency L3
```

These sets are rebuilt from the session's `offload-*.jsonl` entries when the session is selected, then updated by `after_tool_call`, mild replacement, aggressive deletion, and emergency deletion. The hook also reads the latest offload entries and builds an `offloadMap` so each confirmed id can be resolved to its stored `summary`, `result_ref`, and `node_id`.

Fast-path reapply only uses `confirmedOffloadIds` and `deletedOffloadIds` as they exist at the start of a `before_prompt_build` invocation. If an id is already in those sets when the hook starts, that same prompt build can hide or rewrite the raw tool detail. If the id is added later during that hook, it will not be picked up by fast-path reapply until a later `before_prompt_build`.

The trigger is not "the next user turn". It is "the next `before_prompt_build` invocation that starts after the state set contains the tool id". That can happen inside the same user request if a tool call returns, `after_tool_call` confirms it, and the runtime immediately builds another model prompt with the full message history.

```text
before_prompt_build receives event.messages
  -> filter heartbeat messages
  -> if no confirmed/deleted ids:
       -> skip reapply and only inject MMD
  -> read offload entries
  -> build tool_call_id -> offload entry map
  -> walk messages once
```

For confirmed ids, fast-path reapply replaces raw tool output with the existing L1 summary. This is the "mild replacement" replay path: the model still sees that a tool ran and gets a compact result, while the raw output stays recoverable through the stored ref. It is still a lossy prompt mutation for the current model call: if the summary omitted a key detail from the raw result, the model will not see that detail unless another path reads or injects the referenced full result.

```text
tool_result with id in confirmedOffloadIds
  -> replace content with summary/result_ref/node_id text
  -> mark msg._offloaded = true

assistant tool_use-only message where every tool_use id is confirmed
  -> replace assistant tool_use block with summary-shaped compact content

mixed assistant message with text + tool_use blocks
  -> compact confirmed non-current tool_use blocks in place
```

Concrete example:

```text
User asks:
  "Find today's Tencent news and compare the regulatory item with the cloud item."

Tool result call_news_001 contains:
  - 20 article snippets
  - exact dates
  - source URLs
  - quoted figures from a regulatory article
  - quoted figures from a cloud product article

after_tool_call writes an offload entry:
  tool_call_id: call_news_001
  summary: "Found Tencent regulatory and cloud news. Regulatory item concerns X; cloud item concerns Y."
  result_ref: results/call_news_001.md
  offloaded: true

The next prompt build receives the full raw history from the host:
  tool_result call_news_001 with all 20 snippets

Fast-path reapply sees call_news_001 in confirmedOffloadIds and rewrites that message to:
  [Offloaded Tool Result | node: ...]
  Summary: Found Tencent regulatory and cloud news. Regulatory item concerns X; cloud item concerns Y.
  result_ref: results/call_news_001.md (read this file for full tool call and raw result)

What the model sees in that prompt:
  the summary and ref

What the model no longer sees in that prompt:
  the exact article snippets, dates, URLs, and quoted figures unless they survived in the summary or are re-injected from result_ref
```

For deleted ids, fast-path reapply removes the matching historical tool exchange again. This is the "aggressive/emergency deletion" replay path. It must also preserve provider message invariants: if a `tool_result` is gone, the matching assistant `tool_use` cannot remain as an orphaned call.

```text
tool_result with id in deletedOffloadIds
  -> delete the whole message

deletedOffloadIds
  -> delete assistant tool_use-only messages when all contained tool calls were deleted
  -> strip deleted tool_use/toolCall blocks from mixed assistant messages
```

The replacement text keeps the recovery path visible instead of silently erasing evidence:

```text
summary
result_ref
node_id
```

This means the design relies on the replacement summary being sufficiently faithful for follow-up reasoning. `result_ref` preserves recoverability on disk, but it is not the same as keeping raw evidence in the prompt. Any feature that needs exact news details, URLs, numeric values, code output, or legal/financial text must either prevent early replacement, require a high-fidelity summary, or add an explicit retrieval path from `result_ref` before the next model call.

Two details matter for correctness:

```text
_offloaded marker
  prevents replacing the same message twice in one prompt-build pass

normalized tool ids
  lets lookups match ids even when providers/runtime surfaces differ in underscore formatting
```

After this pass, the message array is back in the same compressed shape that previous rounds established. Only then does the hook run the token guard and decide whether new L3 work is needed.

## 7. Token Guard and L3

The hook enters L3 compression only when token pressure crosses configured thresholds. Below those thresholds, it avoids expensive compression work.

```text
mildOffloadRatio
  replace older high-score tool results with summaries

aggressiveCompressRatio
  delete larger historical blocks until below threshold
  then inject related history MMD context when possible

emergencyCompressRatio
  last-resort deletion/truncation toward emergencyTargetRatio
```

L3 uses L1/L2 fields this way:

```text
score       choose safer replacement candidates first
summary     replacement content for tool_result
result_ref  recovery pointer to raw refs/*.md
node_id     protect active-task nodes and find related MMDs
```

## 8. MMD Injection

MMD injection is separate from L3 compression, even though the same hook calls it. In the gateway `before_prompt_build` path, the active MMD selected by L1.5/L2 is read from disk in full and inserted directly into `event.messages` as a marked user message.

```text
activeMmdFile
  -> read the entire mmds/<active>.mmd file
  -> wrap as <current_task_context>
  -> build { role: "user", content: [{ type: "text", text: mmdText }] }
  -> insert or replace the marked active MMD message in event.messages
```

The injected block contains:

```text
task goal
task file
node-index guidance
Mermaid graph
directional note about doing/done nodes
```

For example, if `context-offload/mmds/001-daily-tech-news-digest.mmd` is the active MMD file, the whole file content is read and placed inside the Mermaid fenced block. There is no truncation in `readMmd()`:

```ts
const mmdContent = await readMmd(stateManager.ctx, activeMmdFile);

const mmdText = [
  `<current_task_context>`,
  `【当前活跃任务的mermaid流程图】这是你最近正在执行的任务的阶段性记录（此条下方的tool use未被汇总，进程可能有延迟，仅供参考）。`,
  taskGoal ? `**任务目标:** ${taskGoal}` : "",
  `**任务文件:** ${activeMmdFile}`,
  "```mermaid", mmdContent, "```",
  `标记为 "doing" 的节点是近期焦点（注：可能有延迟，下方的tool use未被统计，仅供参考），"done" 的已完成。请参考此保持方向感，避免重复已完成的工作。`,
  `</current_task_context>`,
].filter((line) => line !== "").join("\n");
```

The active MMD message is updated in place when it already exists:

```ts
event.messages[existingIdx] = newMsg;
```

Otherwise, it is inserted into the live prompt message array:

```ts
event.messages.splice(insertIdx, 0, newMsg);
```

History MMD injection is different. It happens only after aggressive deletion removes old tool blocks. The deleted tool call IDs are mapped through their `node_id` prefixes to candidate MMD files, and those MMDs are injected within an MMD token budget.

## 9. Tool-Loop MMD Updates

`after_tool_call` can also inject or refresh active MMD during tool loops, but only when the runtime supplies `event.messages`. This keeps the gateway prompt updated when L2 patches the active MMD file between tool calls.

The hook checks whether `event.messages` exists and is an array, waits until L1.5 has settled, reads the current active MMD file, and then either replaces the existing marked message or splices in a new one:

```text
after_tool_call
  -> require event.messages to be an array
  -> require l15Settled
  -> require activeMmdFile
  -> read the whole active MMD file
  -> build a role:user <current_task_context> message
  -> replace existing _mmdContextMessage="active"
  -> or splice a new active MMD message into event.messages
```

This is not guaranteed by the stock `after_tool_call` event shape in the local OpenClaw `2026.6.8` build. The local runtime code constructs the default tool hook event with tool fields only:

```text
dist/selection-*.js
  hookEvent = {
    toolName,
    params,
    runId,
    toolCallId,
    result,
    error,
    durationMs
  }
```

The offload code therefore treats `event.messages` as a patch-health signal. If the field is missing or empty, `after_tool_call` reports the patch as ineffective and skips in-loop MMD/L3 mutation for that turn. `before_prompt_build` remains the reliable gateway prompt-mutation point because OpenClaw's prompt hook helper passes `{ prompt, messages }` into `runBeforePromptBuild(...)`.

This means active MMD can enter gateway prompts in two places:

```text
before_prompt_build
  full pre-prompt active MMD injection

after_tool_call
  in-loop active MMD injection/update after tool calls, only when event.messages is supplied
```

## 10. Collect Mode

Collect mode keeps the offload data pipeline running while avoiding prompt mutation.

```text
collect mode runs
  L1 flush
  L1.5 judgment
  L2 scheduling/backfill

collect mode skips
  fast-path prompt mutation
  L3 compression
  active MMD injection
  history MMD injection
```

This mode is useful when the system should gather offload artifacts but leave prompt pressure to the host or legacy compaction path.

## 11. Code References

Read these paths for the exact behavior:

- `src/offload/index.ts`: outer `before_prompt_build` hook, collect-mode branch, fire-and-forget L1/L1.5 coordination.
- `src/offload/hooks/before-prompt-build.ts`: fast-path reapply, token guard, L3 calls, final MMD injection.
- `src/offload/hooks/after-tool-call.ts`: in-loop active MMD injection/update into `event.messages`.
- `src/offload/state-reporter.ts`: `after_tool_call` patch-health detection for missing/empty `event.messages`.
- `src/offload/hooks/llm-input-l3.ts`: mild/aggressive/emergency compression and history MMD injection helper.
- `src/offload/mmd-injector.ts`: active MMD read/wrap/insert behavior.
- `src/offload/storage.ts`: `readMmd()` reads the complete MMD file from disk.
- `src/offload/l3-helpers.ts`: offload lookup, summary replacement, active-node protection.
- `/opt/homebrew/lib/node_modules/openclaw/dist/context-engine-lifecycle-*.js`: local OpenClaw context-engine lifecycle, including `assembleHarnessContextEngine()`.
- `/opt/homebrew/lib/node_modules/openclaw/dist/selection-*.js`: local OpenClaw consumption of `assembled.messages` and stock `after_tool_call` event construction.
- `/opt/homebrew/lib/node_modules/openclaw/dist/openresponses-http-*.js`: local OpenClaw `/v1/responses` gateway handler that converts `payload.input` to `agentCommandFromIngress(...)`.
- `/opt/homebrew/lib/node_modules/openclaw/dist/openai-responses-*.js`: provider request builder that converts final `context.messages` into Responses API `input`.
