# How Wiki turns documents into structured pages and a link graph

> **TL;DR:** Wiki keeps uploaded documents as raw sources, asks an LLM to turn their knowledge into persistent Markdown pages, merges those pages into the existing wiki, and derives search and graph indexes from the saved pages. The result compounds across ingests: a new design spec can update an existing service page and add links to an operational concept instead of becoming another isolated chunk.

This document explains the implementation behind the claim in the [project overview](../../README.md): “Wiki turns product docs, design specs, and ops runbooks into structured pages with a link graph.” It also shows one example through every stage of the workflow. For request and response schemas, use the [Knowledge Service OpenAPI specification](../../MemoryKnowledge/openapi.yaml) as the API reference.

## The idea: compile documents into a maintained knowledge artifact

Wiki follows Karpathy's [LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) pattern: raw sources remain available as evidence, while an LLM maintains a separate, cumulative set of interlinked Markdown pages. Queries reuse that compiled knowledge instead of reconstructing the same entities and relationships from raw chunks every time.

The implementation has three corresponding layers:

| Layer | On-disk or service representation | Responsibility |
| --- | --- | --- |
| Raw sources | `raw/sources/*.md` or `*.txt` | Preserve the uploaded document text and its source identity. |
| Wiki | `wiki/**/*.md` | Store generated source summaries, entities, concepts, comparisons, synthesis pages, and `[[wikilink]]` references. |
| Schema | `wiki/purpose.md` and `wiki/schema.md` | Tell the LLM what this wiki is for, which page types to create, and which naming and language rules to follow. |

TencentDB Agent Memory adds a production workflow around that pattern: team authorization, asynchronous builds, incremental source tracking, page merge rules, BM25 search, a materialized link graph, status callbacks, and read-only tools for Agents.

## End-to-end workflow

The workflow has two halves. The write path turns sources into pages and indexes; the read path lets people and Agents list, search, traverse, and read the result.

```text
Browser / API
    |
    | create wiki, upload raw files, request ingest
    v
Memory Panel  -- authorization and asset registration
    |
    v
Knowledge Service
    |
    | enqueue asynchronous build
    v
Source classification -> LLM analysis -> LLM page generation -> merge
    |                                                  |
    |                                                  v
    |                                       wiki/**/*.md + [[links]]
    v                                                  |
index.md + log.md + overview.md                        |
    |                                                  |
    +---------------------- scan pages ----------------+
                               |
                               v
                index.db: BM25 + page metadata + graph edges
                               |
             +-----------------+-----------------+
             v                                   v
       Panel page/graph UI              Agent tools/list + tools/call
```

### Step 1: Create an empty Wiki asset

Creation establishes identity and storage, but it deliberately does not start ingestion. This separation lets a caller upload one or more sources before spending LLM tokens.

The Panel calls `POST /api/v1/knowledge/wiki/create`; after authorization it forwards the request to `POST /v3/wiki/create`. The Knowledge Service creates:

- a `wiki-...` metadata row with team, owner, status, and version fields;
- `raw/sources/`, where uploaded source documents will live;
- `index.db`, with tables for sources, page metadata, BM25 content, and graph edges;
- a registered Memory Asset in the Panel, so ACL and Agent binding can use the same `wiki_id`.

Example: create a Wiki named `Checkout Reliability`. At this point it has an ID such as `wiki-a1b2c3d4`, no source files, and no generated pages.

### Step 2: Upload product docs, design specs, or runbooks

Upload stores source text and records its content hash; it still does not generate pages. The UI accepts `.md`, `.txt`, and `.markdown` files, reads them as text, and sends each `{ filename, content }` to the raw-write API. The current ingestion scanner processes `.md` and `.txt`; until it also scans `.markdown`, use `.md` for Markdown sources that must be ingested.

For the running example, upload these three files:

```text
product-checkout.md
  Checkout must return a price within three seconds.
  If pricing is unavailable, show the last known quote with a stale-data warning.

design-edge-gateway.md
  Edge Gateway calls Checkout API and Pricing Service.
  The request timeout budget is three seconds.

ops-pricing-timeout.md
  Alert when Pricing Service timeout rate exceeds the operating threshold.
  During an incident, enable stale-quote fallback and verify the warning banner.
```

For every upload, the service writes the file under `raw/sources/` and upserts a `source` row containing its filename, SHA-256, size, uploader, and status. New or changed content gets status `uploaded`; uploading identical content is idempotent.

### Step 3: Trigger an asynchronous ingest

Ingest changes the Wiki from a passive collection of files into a background build. Both the Panel and Knowledge Service reject an empty Wiki, and the service rejects another ingest while the same Wiki is already `pending` or `processing`.

The direct Knowledge Service request, `POST /v3/wiki/ingest`, returns HTTP 202 after the service:

1. increments the Wiki version;
2. sets status to `pending`;
3. enqueues a fire-and-forget build keyed by `wiki_id`.

The browser calls the Panel endpoint, `POST /api/v1/knowledge/wiki/ingest`, rather than the Knowledge Service directly. The Panel consumes the upstream 202 response and currently returns its own HTTP 200 success envelope. In this path, 200 means that the ingest request succeeded and was accepted; it does not mean that page generation finished.

After the request returns, the worker changes the Wiki status to `processing`. The UI calls `wiki/get` after 800 milliseconds and then every two seconds. Each successful poll returns HTTP 200, with build progress carried in the response body:

| Response body state | Meaning |
| --- | --- |
| `status: pending` | The build is queued. |
| `status: processing`, `internal_status: scanning` | The worker has started and is scanning inputs. |
| `status: processing`, `internal_status: ingesting` | The LLM extraction and page merge are running. |
| `status: processing`, `internal_status: rebuilding-index` | Pages are being scanned into search and graph indexes. |
| `status: ready` | The completed pages and indexes are available. |
| `status: failed` | The build stopped; `sync_error` contains the bounded error message. |

The UI stops polling only at `ready` or `failed`. Because the first poll happens after 800 milliseconds, a fast worker may move past `pending` before the user sees that state.

In the example, clicking **Ingest** queues `wiki-a1b2c3d4`. The three uploaded files remain untouched while the generated layer is rebuilt.

### Step 4: Decide which sources actually need LLM work

Ingestion is incremental at source-file granularity. The manager compares each file's current SHA-256 with its prior `source` row before calling the LLM.

Each source falls into one of three groups:

- `toIngest`: new file, changed hash, or previous status other than `ingested`;
- `skipped`: same hash and previous status `ingested`;
- `deleted`: still recorded in `source`, but no longer present on disk.

For the first example ingest, all three files are `toIngest`. If only `ops-pricing-timeout.md` changes next week, the other two skip LLM extraction.

Source deletion is a metadata-driven cleanup, not an LLM rewrite. Consider these two generated pages before deleting `ops-pricing-timeout.md`:

```yaml
# wiki/sources/ops-pricing-timeout.md
sources: [ops-pricing-timeout.md]

# wiki/entities/pricing-service.md
sources: [design-edge-gateway.md, ops-pricing-timeout.md]
```

The cleanup works as follows:

1. Delete the raw file. The normal raw-delete API performs cleanup immediately. If the file disappeared outside that API but its `source` row remains, the next ingest classifies it as `deleted` and performs the same cleanup.
2. Scan every generated page's frontmatter `sources` list.
3. Delete a page when the removed file was its only source. In this example, `wiki/sources/ops-pricing-timeout.md` is deleted.
4. Keep a page when it still has another source, but remove the deleted filename from its `sources` list. In this example, `wiki/entities/pricing-service.md` remains with `sources: [design-edge-gateway.md]`.
5. Rebuild page metadata, the search index, and the graph index so they reflect the remaining pages.

This cleanup does not ask the LLM to remove sentences that originally came from the deleted source. A shared page keeps its existing body unchanged; only its `sources` metadata changes. If that distinction matters, review or regenerate the shared page after deleting the source.

### Step 5: Load the Wiki's purpose, schema, and existing page catalog

The LLM receives the Wiki's local rules and current structure, so it can integrate knowledge rather than emit unrelated summaries. `purpose.md` and `schema.md` are inserted into the prompts as-is when they contain meaningful custom content; otherwise software-engineering defaults apply.

Before processing each source, the engine also scans existing Markdown knowledge pages under `wiki/`. It excludes the structural files `index.md`, `schema.md`, `purpose.md`, `log.md`, and `overview.md`, which organize, configure, or summarize the Wiki itself rather than represent a source, entity, concept, comparison, or synthesis. The engine gives the LLM a compact catalog of the remaining pages containing path, title, type, and description. This catalog tells the model which subjects already have pages and should be updated.

For the first ingest, the catalog is empty. During later sources, it may already contain `Edge Gateway`, `Pricing Service`, and `Timeout Budget`, so the model can reuse them instead of creating near-duplicates.

### Step 6: Analyze each source, then generate page candidates

The default two-stage prompt separates “what knowledge is present?” from “write valid pages.” This costs an extra LLM call but produces a more explicit integration plan before the model has to satisfy the file format.

Stage A asks for:

1. a short source summary;
2. concrete entities;
3. abstract concepts;
4. matches against existing pages;
5. suggested cross-references.

Stage B asks the LLM to turn that plan into one or more `FILE` blocks. Every source must produce a source-summary page, and notable entities or concepts may produce additional pages. The body uses title-based wikilinks such as `[[Pricing Service]]`, not paths or filenames.

An illustrative plan for `design-edge-gateway.md` is:

```text
Source summary: Edge Gateway coordinates checkout pricing within a three-second budget.
Entities: Edge Gateway, Checkout API, Pricing Service
Concepts: Timeout Budget
Existing-page action: update Pricing Service if it already exists
Cross-references: Edge Gateway -> Checkout API, Pricing Service, Timeout Budget
```

Stage B turns that plan into `FILE` blocks. One representative candidate is:

```markdown
<<<FILE path="wiki/entities/edge-gateway.md">>>
---
type: entity
title: Edge Gateway
description: Entry service that coordinates checkout pricing requests.
sources:
  - design-edge-gateway.md
---

# Edge Gateway

The Edge Gateway calls [[Checkout API]] and [[Pricing Service]]. These calls
must complete before the three-second [[Timeout Budget]] expires.
<<<END>>>
```

If a source exceeds the input budget, the engine splits it at Markdown headings first, then paragraphs, with overlap between chunks. Each chunk goes through the same analysis/generation protocol, and same-path candidates from later chunks replace earlier candidates before the merge phase.

### Step 7: Parse and normalize the LLM output

LLM output is treated as untrusted data. The model cannot write files directly; it emits bounded blocks like the Stage B candidate above, which the application parses and validates.

The parser discards truncated blocks, empty blocks, absolute paths, traversal paths, and anything outside `wiki/`. The application then derives the final path again from frontmatter `type + title`, for example `entity + Edge Gateway` becomes `wiki/entities/edge-gateway.md`. Structural files such as `index.md`, `schema.md`, `purpose.md`, `log.md`, and `overview.md` cannot be overwritten by generated candidates.

The service also guarantees that the current raw filename appears in frontmatter `sources`, even if the LLM omitted it. This metadata is the provenance used when a raw source is deleted; source hashes in `index.db` drive incremental updates.

### Step 8: Create or merge persistent Wiki pages

The canonical page path is the deduplication key. A new path is written directly; an existing path goes through merge rules so knowledge accumulates instead of producing parallel copies.

The merge order is:

1. If the existing page has `locked: true`, skip it. Manual page writes inject this flag so a later ingest cannot overwrite a human-owned page.
2. If the new body is already contained in the old body, keep the old body and only union the `sources` lists.
3. If the existing body is at most 4,000 characters, ask the LLM to rewrite one merged page while preserving old facts and noting conflicts.
4. If it is larger, ask only for an incremental fragment and append it, reducing output tokens and the risk of losing old facts.

The second rule is a no-LLM fast path. Suppose the existing page is:

```markdown
---
type: entity
title: Pricing Service
sources:
  - design-edge-gateway.md
---

Pricing Service provides prices to Edge Gateway.
```

A later source produces a candidate with the same body but different provenance:

```markdown
---
type: entity
title: Pricing Service
sources:
  - ops-pricing-timeout.md
---

Pricing Service provides prices to Edge Gateway.
```

The service keeps the existing body without calling the LLM and writes the union of both `sources` lists:

```markdown
---
type: entity
title: Pricing Service
sources:
  - design-edge-gateway.md
  - ops-pricing-timeout.md
---

Pricing Service provides prices to Edge Gateway.
```

This check is textual rather than semantic: it collapses whitespace and tests whether the complete new body is a substring of the old body. Two differently worded sentences with the same meaning do not take this fast path; they continue to the size-based LLM merge rules.

After all three example sources, the generated layer may look like:

```text
wiki/
├── sources/
│   ├── product-checkout.md
│   ├── design-edge-gateway.md
│   └── ops-pricing-timeout.md
├── entities/
│   ├── edge-gateway.md
│   ├── checkout-api.md
│   └── pricing-service.md
└── concepts/
    ├── timeout-budget.md
    └── stale-quote-fallback.md
```

The exact wording and number of pages are LLM-dependent, but the page format, allowed paths, provenance injection, canonical naming, and merge behavior are application-enforced.

### Step 9: Maintain navigation, history, and overview files

Every successful page write updates machine-maintained navigation around the generated pages. These files make the Wiki useful even before a search query is issued.

- `wiki/index.md` is rebuilt deterministically from page frontmatter. It groups pages by type and links each title to its Markdown file.
- `wiki/log.md` receives a dated ingest entry with source name and page count.
- `wiki/overview.md` is regenerated by the LLM after at least one source succeeds and at least two pages exist. It summarizes the whole Wiki and uses wikilinks to connect the narrative to detailed pages.

In the example, the index exposes Sources, Entities, and Concepts, while the overview can explain that `[[Edge Gateway]]` enforces a `[[Timeout Budget]]` and activates `[[Stale Quote Fallback]]` when `[[Pricing Service]]` is unavailable.

### Step 10: Build BM25 and link-graph indexes atomically

The graph is not a second LLM product. It is deterministically derived from the saved pages, in the same database transaction that rebuilds search metadata and records source ingest results. Page files are written before this SQLite transaction, so the Markdown and database are not one cross-filesystem atomic commit; a failed build remains retryable because uncommitted source status is not marked `ingested`.

The Wiki has a graph data model, but it does not use a dedicated graph database such as Neo4j. Markdown files are the canonical page content: frontmatter `type` organizes pages into directories such as `wiki/entities/` and `wiki/concepts/`, while the normalized title gives each page its stable ID and filename. Each Wiki then stores its persistent search and graph indexes in its own SQLite `index.db`. On the read path, the service loads the stored nodes and edges into a temporary in-memory Graphology graph for traversal and visualization.

The service scans every Markdown page and writes four logical datasets in the per-Wiki `index.db`:

| Table | Derived data |
| --- | --- |
| `wiki_fts` | Tokenized title and content for BM25 full-text search. |
| `page_meta` | Page ID, title, type, relative path, and static snippet. |
| `graph_edge` | Directed page-to-page edges resolved from valid `[[wikilink]]` targets. |
| `source` | Source hash, lifecycle status, timestamps, and the latest ingest result. |

For the example page above, the scanner reads three wikilinks and resolves their titles or normalized slugs to existing page IDs:

```text
entities/edge-gateway -> entities/checkout-api
entities/edge-gateway -> entities/pricing-service
entities/edge-gateway -> concepts/timeout-budget
```

These are generic, unlabelled `links-to` edges. The graph records only `source_id -> target_id`; relationship meanings such as “calls” or “must complete before the timeout expires” remain natural-language statements in the Markdown body. Therefore, the example does not create a `calls` edge, a `governed-by` edge, or a hierarchy in which the service pages are contained inside `Timeout Budget`.

Unresolved links, self-links, and duplicate source-target pairs do not become graph edges. Search indexes all page types, while the public graph excludes hidden `query` pages. The graph API presents a deduplicated undirected view for visualization; search results still describe whether a related page is an inbound, outbound, or bidirectional neighbor.

### Step 11: Publish `ready` only after pages and indexes agree

The Wiki becomes readable as a finished asset only after extraction and the transactional index rebuild complete. Partial source failure is tolerated when at least one attempted source succeeds; if every attempted source fails, the build fails.

On success, the service records `ready`, page count, and last-sync time. It then tries to generate a short asset summary and sends a status callback to the Panel. Summary or callback failure does not roll back the already committed Wiki. On build failure, status becomes `failed` and a bounded error message is stored.

For the example, the UI's polling loop stops when `wiki/get` reports `ready`; only then does the page and graph view represent a completed build.

### Step 12: Search, traverse, and read the compiled knowledge

The read path exposes progressive disclosure: find a small set of relevant pages, inspect their relationships, and read full Markdown only when needed. Raw documents remain available for source verification.

People use the Panel's page list, full-text search, page reader, raw-source reader, and graph view. Agents discover the same Wiki through `POST /v3/tools/list`, then call read-only tools such as `search`, `list_pages`, `read_page`, `get_graph`, `list_raw`, and `read_raw` through `POST /v3/tools/call`.

For the query `pricing timeout`, BM25 may seed `Pricing Service` and `Timeout Budget`. The direct Wiki search API can optionally expand those seeds through the graph for up to five hops, applying score decay at each hop. That can surface `Edge Gateway` or `Stale Quote Fallback` even when those pages do not contain the exact query terms.

The Agent-facing `search` tool currently uses the default BM25-only path; graph expansion parameters are available on the direct Wiki search API.

## What happens on the next ingest

The second ingest reuses the same Wiki rather than starting over. Unchanged sources skip LLM extraction, changed sources propose updates to canonical pages, and the final scan rebuilds search and graph data from the current Markdown truth.

Suppose `ops-pricing-timeout.md` is changed to add: “Page the checkout on-call after five minutes.” Its hash changes from `ingested` to work-needed, while the product and design files remain skipped. The LLM can update the existing operational source page and merge an `On-call Escalation` concept into the graph. The source table, page files, BM25 rows, and graph edges then move forward together in one completed build.

This is why Wiki is cumulative rather than a one-shot document converter: source identity, canonical page paths, provenance lists, merge rules, and full index rebuilds make each successful ingest a new coherent version of the same knowledge artifact.

## Important boundaries

The implementation enforces the storage and indexing mechanics, but generated knowledge still inherits LLM judgment. Operators should distinguish guaranteed behavior from model-dependent content.

- The application guarantees source hashing, allowed paths, page format handling, canonical paths, locked-page protection, source provenance injection, transactional index replacement, and status transitions.
- The LLM decides which entities and concepts deserve pages, the prose it writes, and which wikilinks it proposes.
- Raw upload and ingest are separate operations. Upload success does not mean generated pages exist.
- HTTP 202 means the build was queued. `ready` is the completion signal.
- The graph contains only resolved wikilinks between Wiki pages. It is not a factual inference engine.
- Search is BM25 over generated page text. Graph expansion is optional on the direct search API and disabled by default.
- A human-edited page is protected only after it is written through the page API, which injects `locked: true`.

## Implementation map

The behavior above is split between the Panel control plane and the Knowledge Service data plane. These files are the best starting points for source-level tracing.

| Concern | Source |
| --- | --- |
| Panel create, upload, ingest, polling, and page/graph UI | [`MemoryPanel/web/src/pages/wiki/WikiPage/components/WikiSourcesPanel.tsx`](../../MemoryPanel/web/src/pages/wiki/WikiPage/components/WikiSourcesPanel.tsx) |
| Panel authorization and forwarding routes | [`MemoryPanel/src/panel/http/routes/knowledge/wiki-routes.ts`](../../MemoryPanel/src/panel/http/routes/knowledge/wiki-routes.ts) |
| Knowledge Service API routes | [`MemoryKnowledge/src/routes/wiki.ts`](../../MemoryKnowledge/src/routes/wiki.ts) |
| Async status machine and build worker | [`MemoryKnowledge/src/store/wiki-service.ts`](../../MemoryKnowledge/src/store/wiki-service.ts) and [`MemoryKnowledge/src/module.ts`](../../MemoryKnowledge/src/module.ts) |
| Incremental source classification and index transaction | [`MemoryKnowledge/src/engines/wiki/manager.ts`](../../MemoryKnowledge/src/engines/wiki/manager.ts) |
| Two-stage extraction and page writing | [`MemoryKnowledge/src/engines/wiki/ingest-v2/index.ts`](../../MemoryKnowledge/src/engines/wiki/ingest-v2/index.ts) |
| Prompt contract and wikilink rules | [`MemoryKnowledge/src/engines/wiki/ingest-v2/prompts.ts`](../../MemoryKnowledge/src/engines/wiki/ingest-v2/prompts.ts) |
| Page merge and locked-page behavior | [`MemoryKnowledge/src/engines/wiki/ingest-v2/merge.ts`](../../MemoryKnowledge/src/engines/wiki/ingest-v2/merge.ts) |
| SQLite schema and source lifecycle | [`MemoryKnowledge/src/engines/wiki/index-db.ts`](../../MemoryKnowledge/src/engines/wiki/index-db.ts) |
| Agent-facing read-only tools | [`MemoryKnowledge/src/routes/tools.ts`](../../MemoryKnowledge/src/routes/tools.ts) |
