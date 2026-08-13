# tencent-memory Local BM25 Solution — Report

## TL;DR

`tencent-memory` ships a **pure-TypeScript local BM25 sparse encoder** at `src/core/store/bm25-local.ts` that replaces the previous Python sidecar `BM25Client`. It wraps `@tencentdb-agent-memory/tcvdb-text` (jieba-wasm tokenizer + **frozen pre-trained corpus statistics** for `zh` / `en`) and is wired into both storage backends (`tcvdb` and `sqlite`) via the store factory. The encoder is on by default, fails soft (returns `[]` on error rather than throwing), and is consumed by the TCVDB backend to build hybrid dense + sparse search.

> **Important characteristic:** the IDF / corpus statistics are **fixed at package-publish time** — they are not learned from the user's own data and do not update as the memory store grows. See §6.1.

## 1. Module Overview

**File:** `src/core/store/bm25-local.ts` (92 lines)

The module exposes three surfaces:

- `BM25LocalEncoder` — the encoder class.
- `BM25LocalConfig` — config interface.
- `createBM25Encoder(config, logger)` — factory that returns `BM25LocalEncoder | undefined`.

It re-exports `SparseVector` from `@tencentdb-agent-memory/tcvdb-text` so downstream code has a single import path for the sparse vector type.

## 2. Design Rationale

The header comment states the design goal explicitly:

> Pure TypeScript replacement for the Python sidecar BM25 client.

This removes a runtime dependency on a Python process (sidecar IPC, separate venv, deployment complexity) and folds BM25 encoding into the Node.js process. The contract — `encodeTexts` for upsert, `encodeQueries` for search — is preserved so the rest of the codebase (notably `tcvdb.ts`) didn't need a shape change during the migration.

## 3. Public API

### 3.1 `BM25LocalConfig`

```ts
interface BM25LocalConfig {
  enabled: boolean;            // default: true
  language?: "zh" | "en";      // default: "zh"
}
```

Backed in `src/config.ts` by the `bm25` config group:

```
bool(bm25Group, "enabled") ?? true
(str(bm25Group, "language") === "en" ? "en" : "zh")
```

So `language` defaults to `zh` and any value other than `"en"` falls back to `"zh"` — no third option is supported.

### 3.2 `BM25LocalEncoder`

Constructed with `(language, logger?)`. Internally instantiates `BM25Encoder.default(language)` from the `tcvdb-text` package, which loads pre-trained corpus statistics for the chosen language (this is what lets queries use IDF without a per-deployment training step).

Two methods, both returning `SparseVector[]`:

| Method | Purpose | BM25 scoring mode |
|---|---|---|
| `encodeTexts(texts)` | Encode documents for upsert | TF-based |
| `encodeQueries(texts)` | Encode queries for search | IDF-based |

Both early-return `[]` on empty input and wrap the underlying call in `try/catch` — failures are logged at `warn` level and downgraded to an empty array. This is the **fail-soft** behavior: BM25 disappearing must not break ingestion or recall; the system silently degrades to dense-only search (see §5).

### 3.3 `createBM25Encoder`

```ts
function createBM25Encoder(
  config: BM25LocalConfig,
  logger?: Logger,
): BM25LocalEncoder | undefined
```

Returns `undefined` when `config.enabled === false`. Every consumer must `if (this.bm25Encoder)` guard before using it — this is the contract the type signature enforces.

## 4. Integration Points

### 4.1 Factory wiring (`src/core/store/factory.ts:48`)

```ts
const bm25Encoder = createBM25Encoder(config.bm25, logger);
```

The encoder is created **once per `StoreBundle`**, independent of the chosen backend, then:

- Passed into `TcvdbMemoryStore` constructor (`factory.ts:69`) when backend is `tcvdb`.
- Attached to the returned bundle (`factory.ts:80`, `factory.ts:120`) so callers outside the store can reach it.
- Logged in the store-creation debug line as `bm25=enabled|disabled`.

### 4.2 TCVDB consumer (`src/core/store/tcvdb.ts`)

This is the **only active consumer today**. Grep shows:

- Upsert path: `this.bm25Encoder.encodeTexts([record.content])` at lines 432, 476, 761, 793 — every record / message gets a sparse vector at write time.
- Search path: `this.bm25Encoder.encodeQueries([queryText])` at lines 698, 1012 — query text becomes a sparse vector at recall time.
- Capability flag: `hasBm25 = !!this.bm25Encoder` (line 334) and `return !!this.bm25Encoder` (line 1173) — exposed so callers can branch on hybrid vs dense-only.
- Dense-only fallback comment at line 717: *"BM25 unavailable — use /document/search with embedding"*.

### 4.3 SQLite backend

The factory still creates and attaches `bm25Encoder` to the `sqlite` bundle, but `VectorStore` in `sqlite.ts` doesn't take it as a constructor argument. The SQLite path uses FTS5 for lexical search, so the local BM25 encoder is effectively a no-op for that backend. The hook is in place if hybrid sparse-vector search is ever added to the SQLite store.

## 5. Failure Modes & Fallback

There are two distinct disabled states, and they matter for ops:

| State | Source | `bm25Encoder` value | TCVDB behavior |
|---|---|---|---|
| Explicitly disabled | `config.bm25.enabled = false` | `undefined` | Dense-only `/document/search` |
| Runtime error | `encodeTexts` / `encodeQueries` throws | encoder exists but returns `[]` | Hybrid path runs with empty sparse vector |

The second case is subtle: the capability flag `hasBm25` stays `true`, so TCVDB will still take the hybrid code path, but with an empty `SparseVector`. Whether that degrades recall quality or is treated as dense-only by the TCVDB server depends on `hybridSearch` semantics on the server side — worth confirming when tuning recall.

## 6. Dependencies

- `@tencentdb-agent-memory/tcvdb-text` (`^0.1.1`) — provides `BM25Encoder` and the `SparseVector` type. Bundles jieba-wasm for tokenization and the pre-trained BM25 corpus stats.

No native modules, no Python, no network calls at encode time — everything runs in-process.

### 6.1 Pre-trained, Fixed Corpus Statistics

The constructor calls:

```ts
this.encoder = BM25Encoder.default(language);
```

`BM25Encoder.default(language)` loads **statically packaged** IDF / document-frequency tables for general Chinese or English corpora. Practical consequences:

- **No training step.** Deployments don't need to ingest a sample of the user's corpus before BM25 works — encoding is available from process start.
- **No online updates.** Adding more memories to the store does **not** refine these statistics. A term that's rare in the package's reference corpus but common in the user's domain will keep its high IDF weight forever, and vice versa.
- **Statistics are version-locked.** They change only when `@tencentdb-agent-memory/tcvdb-text` is upgraded. Bumping the package version is the *only* way to refresh corpus stats.
- **Cross-deployment consistency.** Every install of the same package version produces identical sparse vectors for the same input, which makes sparse-vector indexes comparable across environments — but means there is no per-tenant adaptation.
- **Domain skew risk.** For specialized vocabularies (legal, medical, code identifiers, internal product names), the fixed IDF can be a poor match for the actual term distribution, which may either over- or under-weight terms during recall.

This is a deliberate trade — it removes a training/refresh pipeline from the deployment surface in exchange for accepting a generic corpus prior.

## 7. Observability

Logging is namespaced with `[memory-tdai][bm25-local]`:

- `debug` on construction: `Initialized BM25 local encoder (language=...)`.
- `debug` when disabled: `BM25 sparse encoding disabled`.
- `warn` on encode failure with the underlying error message.

Factory adds a higher-level `bm25=enabled|disabled` line in the store-creation debug log, which is the easiest single-line signal for "is hybrid search live".

## 8. Open Observations

1. **SQLite backend receives `bm25Encoder` but ignores it.** Either drop the parameter from the SQLite branch of the factory or wire it through to a future sparse-search path. Today it's harmless but slightly misleading.
2. **Empty-sparse-vector vs no-sparse-vector** are different states reaching the TCVDB server — see §5. If recall quality regressions are ever observed under BM25 errors, this is the first thing to inspect.
3. **Language is binary (`zh` / `en`).** Mixed-language corpora go through whichever default the deployment picked. No per-record language detection.
4. **No training / corpus-stats refresh.** Covered in detail in §6.1 — corpus statistics are frozen at package-publish time. Refreshing them requires a `@tencentdb-agent-memory/tcvdb-text` version bump.

---

*Source files inspected:* `src/core/store/bm25-local.ts`, `src/core/store/factory.ts`, `src/core/store/tcvdb.ts` (grep), `src/config.ts` (bm25 group).
