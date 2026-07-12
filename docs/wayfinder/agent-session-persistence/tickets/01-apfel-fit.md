---
title: Does apfel fit as the step-note summarizer?
type: research
status: closed
assignee: claude
blocked_by: []
---

## Question

Investigate apfel (https://github.com/Arthur-Ficial/apfel): what it actually is (CLI, library, or service), how it's invoked, its input/output shape, license, whether it's actively maintained, and whether it needs an LLM API key or has a meaningful cost/latency profile per call.

Judge whether it's the right fit for "summarize a hook event into a `(title, description)` step note" — versus a simpler home-grown summarizer (e.g. truncate/template the hook's existing `summary` field) or just persisting the raw hook summary unsummarized for v1.

Produce a recommendation: adopt apfel / use a lighter alternative / skip summarization entirely for v1 — with the reasoning that leads there.

## Answer

**Adopt apfel** — specifically via **`ApfelCore`**, the Swift Package it ships (`docs/swift-library.md`), linked directly into Srota rather than shelled out to as a CLI subprocess. Since Srota is already a Swift app, this avoids process-spawn overhead entirely and gives in-process guided generation.

Confirmed facts (2026-07-12, via `gh api repos/Arthur-Ficial/apfel`):
- 6,105 stars, MIT license, actively maintained (commits from 2026-07-09, three days before this research), 12 open issues — no adoption-risk red flags.
- Runs Apple's on-device FoundationModels LLM (`apple-foundationmodel`, ~3B params). No API key, no network call, no per-call cost.
- Requires **macOS 26 Tahoe+, Apple Silicon only, Apple Intelligence enabled**. Not configurable to a different/larger model.
- Supports **guided JSON-schema generation** (`response_format: json_schema` in the OpenAI-compatible surface, `DynamicGenerationSchema` in `ApfelCore`) — output is *guaranteed* to conform to a given schema. This is a direct fit for producing a `{title, description}` step-note struct without free-text parsing.
- **4096-token context window, input + output combined.** Hook summaries/transcript excerpts must be truncated/chunked before being passed in — cannot dump large tool outputs or full transcripts.
- **A few seconds per response** (on-device inference, not cloud-scale). Too slow to run synchronously inside `notify.sh`'s hook invocation without adding real latency to the hook's return. **Resolves the map's open "sync vs async" question: step-note generation must happen asynchronously**, off the hook's execution path (e.g. the daemon calls into `ApfelCore` after receiving the `agent_event`, not `notify.sh` itself).
- Model has no clock/date awareness and is unreliable about self-reported facts (e.g. its own training cutoff) — irrelevant to summarizing hook text we hand it, but reinforces treating it strictly as "phrase this given text," not "reason about facts it wasn't given."

**Design implication for downstream tickets:** [[04-sessions-schema]] should assume step notes are generated asynchronously by the daemon (not `notify.sh`), with a fallback path — when apfel/Apple Intelligence is unavailable (older macOS, Intel Mac, Apple Intelligence disabled) — that stores the raw hook `summary` unsummarized rather than blocking on it. That fallback needs its own status field or nullable "summarized" flag in the schema design.

### Correction, found during implementation (2026-07-12)

**`ApfelCore` alone does not run inference** — its own docs (`docs/swift-library.md`) state it's "FoundationModels-free by design": it supplies OpenAI-shaped wire types, retry logic, and context-trimming helpers for building an OpenAI-compatible *server*, not the model call itself. The `apfel` executable composes `ApfelCore` + Apple's `FoundationModels` framework + Hummingbird; the library alone has nothing to call.

Separately, confirmed (via a standalone `swiftc -typecheck` probe, no Xcode needed — `FoundationModels` is a first-party system framework already in the macOS 26 SDK) that `FoundationModels`' own native API already does exactly what this ticket needs, directly:

```swift
import FoundationModels

@Generable
struct StepNote {
    @Guide(description: "...") var title: String
    @Guide(description: "...") var description: String
}

let session = LanguageModelSession()
let response = try await session.respond(to: prompt, generating: StepNote.self)
```

**Revised decision: skip `ApfelCore`/apfel entirely.** Call `FoundationModels` directly — same on-device, no-API-key, no-cloud properties as before, zero new external dependencies (vs. adding an SPM package dependency), and one less thing to track for updates. Everything else in this ticket's answer still holds (4096-token-equivalent context limits, async-off-the-hook-path requirement, raw-summary fallback) — only the specific library changed, not the architecture.
