#if canImport(SwiftUI) && canImport(Observation)
import SwiftUI
import TokenTrace

/// One screen that shows a hybrid AI request as a single trace: the tap, the
/// on-device model, the proxy and the vendor call, on one corrected clock.
public struct TraceLabView: View {
    @State private var model: TraceLabModel

    public init(configuration: TracingConfiguration, scenario: LabScenario = LabScenario()) {
        _model = State(initialValue: TraceLabModel(configuration: configuration, scenario: scenario))
    }

    public var body: some View {
        NavigationStack {
            Form {
                scenarioSection
                Section {
                    Button {
                        Task { await model.run() }
                    } label: {
                        Label("Tap “Summarize note”", systemImage: "hand.tap")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("runButton")
                } footer: {
                    Text("Simulated tiers in virtual time. The tracing pipeline is the real library.")
                }
                if let run = model.lastRun {
                    decisionSection(run)
                    waterfallSection
                    redactionSection(run)
                }
                exportSection
                costSection
            }
            .navigationTitle("Tap → Token")
        }
    }

    // MARK: Sections

    private var scenarioSection: some View {
        Section("Scenario") {
            Picker("On-device model", selection: $model.scenario.onDevice) {
                Text("answers").tag(LabScenario.OnDevice.answers)
                Text("unavailable").tag(LabScenario.OnDevice.unavailable)
                Text("refuses").tag(LabScenario.OnDevice.refuses)
                Text("low confidence").tag(LabScenario.OnDevice.lowConfidence)
            }
            Picker("Cloud tier", selection: $model.scenario.cloud) {
                Text("healthy").tag(LabScenario.Cloud.healthy)
                Text("slow").tag(LabScenario.Cloud.slow)
                Text("429 then OK").tag(LabScenario.Cloud.rateLimitedOnce)
                Text("fails").tag(LabScenario.Cloud.fails)
            }
            .disabled(model.scenario.onDevice == .answers)
            VStack(alignment: .leading) {
                Text("Device clock ahead by \(model.scenario.deviceClockAheadMillis) ms")
                Slider(value: $model.skewMillis, in: -5_000...5_000, step: 100)
            }
        }
    }

    private func decisionSection(_ run: LabRun) -> some View {
        Section("Tail-sampling decision") {
            if let o = run.outcome {
                LabeledContent("Device trace", value: decisionText(o.decision))
                    .accessibilityIdentifier("decision")
                LabeledContent("Server trace", value: run.serverSpans.isEmpty && !run.scenario.needsCloud
                               ? "no cloud call" : (run.serverKept ? "kept" : "dropped"))
                LabeledContent("Duration", value: "\(o.rootDurationNanos / 1_000_000) ms")
                LabeledContent("Cost", value: Money.format(picoDollars: o.costPicoDollars))
                LabeledContent("Clock offset applied", value: "\(o.appliedOffsetNanos / 1_000_000) ms")
                LabeledContent("In export buffer", value: o.decision.isKept ? (o.bufferAccepted ? "yes" : "refused") : "—")
            } else {
                Text("The trace is still open.")
            }
            ForEach(Array(run.traceparentSent.enumerated()), id: \.offset) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Request \(item.offset + 1): traceparent").font(.caption).foregroundStyle(.secondary)
                    Text(item.element).font(.caption2.monospaced()).textSelection(.enabled)
                    if item.offset < run.tracestateSent.count, let state = run.tracestateSent[item.offset] {
                        Text("tracestate: \(state)").font(.caption2.monospaced())
                    }
                }
            }
        }
    }

    private var waterfallSection: some View {
        Section {
            Toggle("Show without skew correction", isOn: $model.showUncorrected)
            WaterfallView(spans: model.displayedSpans)
                .frame(minHeight: CGFloat(max(1, model.displayedSpans.count)) * 30)
            LabeledContent("Child-before-parent violations", value: "\(model.displayedViolations)")
                .foregroundStyle(model.displayedViolations == 0 ? Color.primary : Color.red)
                .accessibilityIdentifier("violations")
        } header: {
            Text("Collector waterfall")
        } footer: {
            Text(model.lastRun?.outcome?.exported.isEmpty ?? true
                 ? "The device trace was dropped by sampling; only server spans (if kept) reach the collector."
                 : "Device spans in blue, proxy in green, vendor in orange. All timestamps in the server's timebase.")
        }
    }

    private func redactionSection(_ run: LabRun) -> some View {
        Section("Attributes: recorded → exported") {
            if let o = run.outcome {
                ForEach(o.recorded.spans.filter { !$0.attributes.isEmpty }, id: \.spanID) { rec in
                    let exported = o.exported.first { $0.spanID == rec.spanID }?.attributes ?? [:]
                    Text(rec.name).font(.subheadline.weight(.semibold))
                    ForEach(rec.attributes.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.caption.monospaced())
                            HStack(alignment: .top) {
                                Text(display(rec.attributes[key])).font(.caption2)
                                    .foregroundStyle(.secondary).lineLimit(2)
                                Spacer()
                                Image(systemName: "arrow.right").font(.caption2)
                                Text(exported[key].map { display($0) } ?? (o.decision.isKept ? "dropped" : "not exported"))
                                    .font(.caption2)
                                    .foregroundStyle(exported[key] == nil ? Color.red : Color.primary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func display(_ v: AttributeValue?) -> String {
        guard let v else { return "" }
        if case .string(let s) = v { return s }
        return v.description
    }

    private var exportSection: some View {
        Section("Offline export buffer") {
            Toggle("Network online", isOn: $model.networkOnline)
            Toggle("Collector loses acks (at-least-once test)", isOn: $model.collectorLosesAcks)
            Button("Flush to collector") { Task { await model.flush() } }
                .disabled(model.isBusy)
            LabeledContent("Last flush", value: model.lastFlush)
            LabeledContent("Buffered", value: "\(model.bufferedTraces) traces, \(model.bufferedSpans) spans"
                           + (model.pendingRetry ? " (+ batch awaiting retry)" : ""))
            LabeledContent("Collector holds", value: "\(model.collectorSpans) spans")
            LabeledContent("Last batch id", value: model.lastBatchID ?? "—")
            LabeledContent("Export attempts / duplicates deduped",
                           value: "\(model.exportAttempts) / \(model.duplicateBatches)")
            if let m = model.metrics {
                LabeledContent("Kept / dropped / refused by buffer",
                               value: "\(m.tracesKept) / \(m.tracesDropped) / \(m.tracesRefusedByBuffer)")
                LabeledContent("Unclassified keys dropped",
                               value: m.redaction.unclassifiedKeys.sorted().joined(separator: ", ").isEmpty
                               ? "none" : m.redaction.unclassifiedKeys.sorted().joined(separator: ", "))
            }
        }
    }

    private var costSection: some View {
        Section {
            if model.costs.isEmpty {
                Text("Run a scenario to see cost per feature.").foregroundStyle(.secondary)
            }
            ForEach(model.costs, id: \.feature) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.feature).font(.headline)
                    Text("\(c.traces) traces · \(c.llmCalls) LLM calls · \(c.fallbackTraces) fallbacks")
                        .font(.caption)
                    Text("total \(Money.format(picoDollars: c.picoDollars)) · per trace \(Money.format(picoDollars: c.costPerTracePicoDollars))")
                        .font(.caption)
                    Text("p50 \(c.p50Nanos / 1_000_000) ms · p95 \(c.p95Nanos / 1_000_000) ms")
                        .font(.caption)
                }
            }
        } header: {
            Text("Cost per feature (every trace, before sampling)")
        } footer: {
            Text("Prices are the app's illustrative config, not a pricing source.")
        }
    }

    private func decisionText(_ d: SamplingDecision) -> String {
        switch d {
        case .drop: return "dropped (healthy, outside ratio)"
        case .keep(let reasons): return "kept: " + reasons.map(\.description).joined(separator: ", ")
        }
    }
}

/// A minimal trace waterfall. Bars are positioned on the span's timestamps
/// relative to the earliest span, so a skewed clock is visible as a bar
/// starting before its parent.
struct WaterfallView: View {
    let spans: [ExportedSpan]

    var body: some View {
        let start = spans.map(\.startUnixNanos).min() ?? 0
        let end = spans.map(\.endUnixNanos).max() ?? 0
        let total = max(1, Saturating.subtract(end, start))
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(spans, id: \.spanID) { s in
                    let x = CGFloat(Double(Saturating.subtract(s.startUnixNanos, start)) / Double(total))
                    let w = CGFloat(Double(Saturating.subtract(s.endUnixNanos, s.startUnixNanos)) / Double(total))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(for: s).opacity(0.85))
                            .frame(width: max(2, w * geo.size.width), height: 22)
                            .offset(x: x * geo.size.width)
                        Text("\(statusGlyph(s.status)) \(s.name)  \(Saturating.subtract(s.endUnixNanos, s.startUnixNanos) / 1_000_000) ms")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .padding(.leading, 4)
                    }
                    .frame(height: 22)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func color(for s: ExportedSpan) -> Color {
        switch s.source {
        case "edge-proxy": return .green
        case "vendor": return .orange
        default: return .blue
        }
    }

    private func statusGlyph(_ st: SpanStatus) -> String {
        switch st {
        case .ok, .unset: return "✓"
        case .error: return "✕"
        case .refused: return "⊘"
        case .fallback: return "↪"
        case .abandoned: return "…"
        }
    }
}
#endif
