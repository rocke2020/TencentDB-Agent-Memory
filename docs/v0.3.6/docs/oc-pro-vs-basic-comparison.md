# OpenClaw Pro Clould vs Basic — memory-tencentdb comparison

**Date**: 2026-06-08
**Hosts inspected**: `43.142.89.34` (Pro), `43.155.107.41` (basic)
**Method**: read-only SSH probes — config (`openclaw.json`), installed plugin source (`dist/` SHAs), on-disk memory + offload state.

---

## TL;DR

Same plugin, same code, same version on both hosts. `sha256(dist/index.mjs)` is byte-for-byte identical (`0c74e7e9…d21e2a5e`), both running `@tencentdb-agent-memory/memory-tencentdb@0.3.6` on `openclaw@2026.5.7`. **"Pro" is not a fork, not a different SKU** — it is the same code with `storeBackend: tcvdb`, a populated remote `tcvdb` block, an `offload.backendUrl` pointing at Tencent Cloud, plus a separately-installed `clawpro-diagnostics-metrics-cls` plugin shipping CLS + Prometheus metrics. Both backends (`sqlite` and `tcvdb`) are compiled into the single shipped bundle and selected purely by config.

---

## 1. Config side-by-side

```
field                       host A — Pro (.34)                                host B — basic (.41)
oc version                  openclaw@2026.5.7                                 openclaw@2026.5.7
plugin                      memory-tencentdb@0.3.6                            memory-tencentdb@0.3.6   (same SHA)
gateway port                33411                                             17827
storeBackend                tcvdb                                             unset -> sqlite (default)
embedding.provider          unset (TCVDB does it server-side, bge-large-zh-v1.5)   unset -> "none" (no vector path)
tcvdb.url                   http://10.0.0.27:80 (VPC)                         n/a
tcvdb.username              mempro_space_itbr9my5                             n/a
tcvdb.apiKey                <REDACTED len=32>                                 n/a
tcvdb.database              space-itbr9my5                                    n/a
bm25.enabled                unset -> true (default)                           unset -> true (default)
bm25.language               unset -> zh (default)                             unset -> zh (default)
offload.enabled             true                                              true (just enabled this session)
offload.backendUrl          https://memory.tdai.tencentyun.com                unset -> local-only
offload.userId              100045091668                                      unset
slots.contextEngine         memory-tencentdb                                  memory-tencentdb
llm.enabled                 false -> host model                               false -> host model
host LLM                    hatchery-gpt-5.4 @ fcru0wpg.tcaisite.com          hatchery-gpt-5.4 @ d1m129vf.tcaisite.com
plugins.allow               clawpro-diagnostics-metrics-cls, browser, memory-tencentdb   memory-tencentdb, browser
extra plugin                clawpro-diagnostics-metrics-cls (CLS+Prometheus)  none
memory-tdai/ on disk        dirs present, empty (state lives in TCVDB)        L0/L1/L2/L3 populated + vectors.db 168K
context-offload/ on disk    1.1M (actively backed to cloud)                   108K (fresh, local)
```

---

## 2. Source-code findings

Bundle is one code path; backend choice is config-driven.

- `sha256(dist/index.mjs)` matches across hosts → no fork, no patch.
- Single `dist/index.mjs` (~750 KB) references `tcvdb` ×60, `sqlite-vec` ×9, `embedding` ×429. Both backends first-class peers in the same bundle.
- No `memory-tencentdb-pro` package, no `enterprise` markers in either bundle. "Pro" is a commercial naming, not a code variant.
- Host A additionally installs `clawpro-diagnostics-metrics-cls`:
  - CLS topic `clawpro-metric-topic-ap-shanghai-1387422814`
  - Prometheus push every 30 s
  - CVM-role auth `CVM_QCSLinkedRoleInClawProAgent` (instance `ins-mub2tah5`, name `oc-2026.5.7`)
- Host B has no diagnostics plugin installed.

---

## 3. What "Pro" actually means

Same plugin code + remote infra wired in via config + a separately-installed Tencent CLS diagnostics plugin. Three knobs flip a basic install to Pro:

1. `config.tcvdb.{url, username, apiKey, database}` populated → vector store moves remote, server-side `bge-large-zh-v1.5` embedding takes over.
2. `config.offload.backendUrl + userId` → L1/L1.5/L2/L4 compaction runs on Tencent's hosted backend, persistent across devices.
3. Install `clawpro-diagnostics-metrics-cls` → ops observability.

---

## 4. Recall path — precise difference

BM25 is the **same** on both sides (defaults: enabled, `zh`/jieba tokenizer). The only delta is the vector half.

```
                       Pro (.34)                            basic (.41)
BM25 keyword recall    on (zh, default)                     on (zh, default)        <- same
vector recall          on (bge-large-zh-v1.5 server-side)   off (embedding.provider="none")
effective strategy     hybrid (BM25 + bge, RRF-fused)       BM25-only (hybrid degrades)
semantic / paraphrase  hit                                  miss
typo / wording drift   hit (BM25 stems)                     hit (BM25 stems)        <- same
cross-language         hit (bge bridges)                    miss
```

> Schema note: `bm25` block description says "mainly for tcvdb backend" — that refers to BM25 *sparse-vector encoding* sent to TCVDB. The same tokenizer setting also governs the local sqlite/sqlite-vec keyword path. Tokenizer language is `zh` for both regardless of backend, unless overridden.

---

## 5. Operational deltas a user feels

- **Cross-host recall** — Pro only. Any OC pointing at the same TCVDB sees the same memories. Basic's `vectors.db` is single-host and dies with the disk.
- **Semantic recall** — Pro only. Basic's `recall.strategy: hybrid` silently degrades to keyword-only because `embedding.provider` is `none`. No synonym, no paraphrase, no cross-language match.
- **Offload persistence** — Pro replicates offloaded `refs/*.md` + summaries to the cloud backend; basic keeps them local. The 1.1M vs 108K size delta reflects this, not a configuration error.
- **Cost** — Pro pays for: TCVDB instance, bge embeddings (per write + recall), offload backend traffic, CLS metric ingestion. Basic is $0 infra (host LLM `gpt-5.4` via hatchery still costs the same on both sides).
- **Observability** — Pro streams metrics to CLS + Prometheus every 30 s; basic is invisible to any central dashboard.

---

## 6. Caveats

- Neither host runs OC as a systemd unit on the cmdline path checked, so a journalctl log snapshot was skipped to stay read-only — config + on-disk state was sufficient for the comparison.
- TCVDB-side `database.json` cache file isn't on Host A's disk; the plugin keeps that state server-side, which is expected for `tcvdb` mode.
- Host B's `offload.enabled: true` + `slots.contextEngine: memory-tencentdb` were set during this session (2026-06-08). The `after-tool-call` patch was applied to OC's `dist`. Prior to that, basic was running long-term memory only.
