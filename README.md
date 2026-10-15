# TokenTrace

**One trace from tap to token: the user's tap, the on-device model, your proxy and the Claude API call, on one clock, with no prompt text in any of it.**

Your AI feature is now four systems. The tap happens in SwiftUI. The first attempt runs on-device. When the model refuses or the device can't run it, the request goes through your backend proxy to a vendor model. On 14 Oct 2026 the Claude Platform launched [OpenTelemetry export in beta](https://platform.claude.com/docs/en/release-notes/overview) for Messages API requests, so the vendor side can now land in the same backend as yours. That only helps if the four halves join into one trace, and on a phone they usually don't. The clock is wrong by seconds. The traces you need (refusals, fallbacks, timeouts) are the ones a 5% head sampler throws away. And the obvious attribute to add while debugging is the prompt.

TokenTrace is a Swift 6 library for the client half of that problem: W3C trace propagation, tail sampling on the device, default-deny redaction, cost attribution per feature, clock-skew correction and a bounded offline export buffer. It has no dependencies and runs on iOS, macOS and Linux.

> **Demo app:** (added after the companion repo is pushed)

---

## Why this matters

Distributed tracing on the server is a solved problem. On a phone, the four assumptions it rests on are all false:

| Server assumption | On a phone | What TokenTrace does |
|---|---|---|
| Clocks are NTP-synced to milliseconds | The device clock is off by seconds and can jump mid-request | Durations use the monotonic clock only. A four-timestamp (NTP-style) estimate from your own proxy's responses, anchored to the monotonic clock, moves exported timestamps into server time |
| A collector does tail sampling | Shipping every span costs battery, data and privacy | The phone is the only place that sees the whole client trace, so it decides there. Notable traces are always kept, healthy ones by a ratio every tier can reproduce from the trace-id |
| Spans are written by engineers who know what's sensitive | The most useful debug value is the user's prompt | Default-deny attribute policy. Span names are `StaticString`, so a name can't contain interpolated user text. Prompts are a `SensitiveText` type whose only exports are a length bucket and a keyed digest |
| The network is there | It isn't, and the app is killed while offline | Bounded buffer of whole traces, priority eviction, retry with the same batch id, `Codable` snapshot for backgrounding |

The AI angle changes what counts as "notable". A refusal or a fallback throws no error. The request "worked", and the user still didn't get what they asked for. If your sampler only keeps errors, you can't see your AI feature failing.

## Architecture

```
SwiftUI tap
   │
   ▼
TracePipeline (actor)  ── the only isolation domain for span bookkeeping; a trace is processed synchronously when its last span ends
   │
   ├─ TraceAssembly     bounded span bookkeeping (value type, tested synchronously)
   ├─ CostAttributor    tokens × price per feature, from EVERY trace (before sampling)
   ├─ TailSampler       keep: error · refusal · fallback · abandoned · slow · expensive · ratio
   ├─ Redactor          AttributePolicy: allow · scan · hash · drop (default)
   ├─ ClockSkewEstimator → one offset per trace, so internal ordering is preserved
   ▼
ExportBuffer (actor)   whole traces, priority eviction, retry by batch id, snapshot/restore
   ▼
SpanExporter (protocol) ── your OTLP/HTTP client
```

Propagation: `traceparent(for:)` gives the W3C header for an outbound request (`sampled` and Level-2 `random` flags set). `tracestate(for:)` adds `tokentrace=k` when the trace has already gone wrong before the request leaves (the on-device model refused), so your proxy keeps its half too.

## Using it

```swift
let tracing = TracePipeline(configuration: TracingConfiguration(
    sampling: SamplingPolicy(latencySLONanos: 2_500_000_000, healthyKeepRatio: 0.05),
    policy: .standard,                // default-deny; add your own keys explicitly
    prices: myPriceTable,             // the app owns prices
    hashKey: installSecret,           // per-install, from the keychain
    installID: installID))

let root = await tracing.startTrace("note.summarize.tap",
                                    attributes: [AttributeKey.feature: .string("note.summarize")])
await tracing.recordPrompt(SensitiveText(prompt), on: root)   // length bucket + digest only

let local = await tracing.startSpan("ai.ondevice.generate", parent: root)
// ... Foundation Models call ...
await tracing.end(local, status: .refused)

let req = await tracing.startSpan("ai.cloud.request", kind: .client, parent: root)
request.setValue(await tracing.traceparent(for: req), forHTTPHeaderField: "traceparent")
if let state = await tracing.tracestate(for: req) { request.setValue(state, forHTTPHeaderField: "tracestate") }
// ... response: record usage, and a ClockSample if your proxy returns its receive/send times ...
await tracing.setAttribute(AttributeKey.inputTokens, .int(usage.input), on: req)
await tracing.end(req)
await tracing.end(root)                       // trace completes → cost, sample, redact, buffer

_ = await tracing.flush(to: myOTLPExporter)   // on reachability, a timer, and backgrounding
```

## Design decisions and rejected alternatives

**Tail sampling on the device, consistent across tiers.** *Rejected: head sampling.* At 5% it discards 95% of refusals and timeouts, which are the traces you need. *Rejected: send everything, sample in the collector.* It is accurate, but every user pays for 95% of traces nobody looks at. The device keeps every notable trace. For healthy ones it applies the OpenTelemetry consistent-probability rule: keep when the trace-id's 56 random bits R are at least the rejection threshold T = (1 − ratio) × 2⁵⁶. A proxy (or a non-parent-based OTel consistent-probability sampler) applying the same ratio keeps exactly the same healthy traces with no coordination. Two caveats: `traceparent` always sets `sampled`, so OTel's default *ParentBased* sampler simply keeps everything, and this library does not emit the newer `ot=th:` tracestate threshold. Configure the server-side ratio explicitly. (An earlier version kept R < ratio × 2⁵⁶. That nests and is consistent with itself, but it keeps the *opposite* band from an OTel sampler. The review caught it.) A test checks that kept sets nest as the ratio grows. It also runs a broken coin-flip sampler and a mis-scaled threshold through the same check and asserts the check fails for both.

**Known gap: slow traces can be half-kept.** The proxy finishes before the client knows the end-to-end latency. A trace that is slow only because of the client keeps its client half, and the proxy's half survives only by ratio. `tracestate` closes this gap for refusals and fallbacks, because those are known before the request leaves. It cannot close it for latency. The alternative is a second "keep" call to the backend after the fact. That is a real option, and it is deliberately not built here.

**Cost is computed before sampling.** Sampling decides what you can debug. It must never decide what you think a feature costs. If you estimate cost from exported traces, "keep all errors + 5% of the rest" overweights failures by an order of magnitude. A test sets the ratio to 0 and asserts all 10 traces are still costed. Money is integer pico-dollars: tokens × (µ$ per million tokens) is exact pico-dollars, with no division and no floating-point drift. A model missing from the price table is counted as `unpriced`, never silently priced at $0.

**Default-deny redaction.** The failure being designed against is not malice. It is a well-meaning `setAttribute("debug.prompt", text)`. With an allowlist, an unclassified key is dropped and *named* in `RedactionCounters.unclassifiedKeys`, so the mistake shows up as a metric, not in a vendor's trace store. `.hash` is HMAC-SHA256 with a per-install key. You can correlate values within an install, but you can't reverse them or join them across installs. *Rejected: a deny-list of "sensitive keys".* It fails open on the first key nobody thought of.

**Clock-skew correction from your own proxy, anchored to the monotonic clock.** The NTP four-timestamp method: your proxy reports when it received and sent the response. The estimate is stored as *server time minus device monotonic time*, never as an offset from the device wall clock. So when NTP or the user changes the wall clock between the sample and a later trace, the correction for that trace is still right. This only holds if the monotonic clock **keeps counting while the phone sleeps**. `DispatchTime` and `mach_absolute_time` stop during sleep, so after a 30-minute screen lock every exported span would land 30 minutes in the past. `SystemClock` therefore reads Darwin `CLOCK_MONOTONIC` (which includes sleep) or Linux `CLOCK_BOOTTIME`. The third review round caught the original `DispatchTime` choice. A test pins the clock source, but CI machines never sleep, so it cannot prove the behaviour across a real suspend. An earlier version stored a wall-clock offset, and the independent review caught that a single clock change left every trace for the next 10 minutes wrong. Two tests now pin the fix: a wall jump between sample and trace, and four runs at different skews through one lab. The estimator trusts the **lowest-delay** recent sample, because asymmetric queuing adds up to δ/2 of error. On ties it trusts the newest. It rejects inconsistent or absurd samples (server time longer than the round trip; more than a day of skew). One offset is applied per trace, so spans inside a trace never reorder. *Rejected: trusting `Date()`.* The demo shows what that does: with the device 2.4 s fast, the proxy's span starts 2.3 s before the request that caused it.

**Whole traces in the buffer, sampled evicted first.** Half a trace renders as a broken waterfall that looks like an app bug. A sampled trace never displaces a forced one. The batch in flight is held outside the queue, so eviction during the `await` can't touch it. A retry resends **the same batch with the same id** (`installID-sequence`), so the collector can dedupe at-least-once delivery. A test stores a batch, "loses" the ack, and checks that the retry carries the same id and is stored once. The sequence continues across `snapshot()`/restore, so ids are never reused. When a batch exhausts `maxAttempts`, the flush stops (`.gaveUp`) instead of sending the next batch straight to an endpoint that just failed. A restored in-flight batch that no longer fits smaller limits is dropped and counted.

**Actor reentrancy.** `ExportBuffer.flush` awaits the exporter, and actors are reentrant. A second `flush` (from a reachability callback during a timer flush) returns `.alreadyFlushing` instead of interleaving. A test parks an exporter mid-request, then calls `flush` and `enqueue` concurrently and checks that the in-flight batch is unchanged. `TracePipeline` keeps sampling, redaction and cost synchronous inside one actor, so no suspension point sits between "this trace completed" and "this trace was decided".

**Bounded everything.** Open traces, spans per trace, attributes, events, string length, feature cardinality (overflow to `(other)`), latency window, clock samples, decision log, buffer spans and bytes. When a limit is hit, the handle becomes non-recording: it still propagates the trace-id, every operation on it is a harmless no-op, and the drop is counted. Arithmetic on remote values (timestamps, token counts) saturates instead of trapping.

**`StaticString` span names, and a `SensitiveText` that can't be printed.** `startSpan("summarize \(note)")` doesn't compile. Names are the one field redaction never sees, so the type system guards it. `SensitiveText` renders as `<redacted>` under interpolation, `print`, `dump` and `String(reflecting:)`, so `.string("\(prompt)")` can't leak it either.

**Propagation keeps other vendors' state.** A trace continued from an incoming header keeps that request's other `tracestate` members unchanged, with this library's member placed first when it adds one, as W3C requires.

**Propagation never invents randomness.** `traceparent` sets the Level-2 `random` flag only for ids minted on the device, or when the incoming header had it. A trace continued from a header without it is propagated without it, because consistent ratio sampling is only consistent if the bits really are random.

## What it is not

It is not an OTLP encoder or an OpenTelemetry SDK replacement. `SpanExporter` is the seam where your OTLP/HTTP client, or the official SDK's exporter, plugs in. Attribute names follow the OTel GenAI semantic conventions (`gen_ai.usage.input_tokens`, …) so vendor spans and yours line up. Prices in the lab are illustrative config, not a pricing source. It also does not govern what a vendor's own span export contains: some backends can show full prompt and response content from the vendor side, which is a setting you choose there, not something this library can redact.

## Verification

- **Local (Linux, Swift 6.0.3):** after `rm -rf .build`, `swift build -Xswiftc -warnings-as-errors` succeeds and `swift test` runs **83 tests, 0 failures**.
- **Mutation checks:** 15 deliberate breaks of load-bearing mechanisms were each applied alone, and every one made at least one test fail. The breaks: refusals not forced; skew offset ignored; cost computed after sampling; a new batch id per retry; sampled evicting forced; the root ending a trace with open children; no flush guard; no `tracestate` force-keep; the highest-delay clock sample trusted; the oldest sample winning ties; Luhn check skipped; Retry-After ignored; `SensitiveText` printing its value; the `random` flag invented for continued traces; lab runs not serialized.
- **CI:** see the Actions tab (results are written into this section only after the runs report).
- **Simulator:** the demo app was not yet run at the time of this commit; see the demo repo for what actually happened.

## Installation

```swift
.package(url: "https://github.com/rajatslakhina/token-trace-kit.git", from: "1.0.0")
```

Add `TokenTrace` to your target (and `TokenTraceUI` only if you want the lab screen). To run the tests: `swift test` (macOS or Linux).

## Requirements

Swift 6.0 · iOS 17 / macOS 14 (Linux for the core module). `TokenTraceUI` (the SwiftUI lab screen used by the demo) needs SwiftUI and Observation.

## License

MIT
