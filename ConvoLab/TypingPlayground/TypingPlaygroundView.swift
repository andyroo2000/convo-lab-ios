import PlaygroundEngine
import SwiftUI

struct TypingPlaygroundView: View {
  @State private var model = TypingPlaygroundModel()
  @State private var showingBenchmark = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TypingPlaygroundWebView(model: model)
        .navigationTitle("Typing playground")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
          ToolbarItem(placement: .primaryAction) {
            Button("Benchmark", systemImage: "speedometer") { showingBenchmark = true }
          }
        }
        .task { await model.prepare() }
        .sheet(isPresented: $showingBenchmark) { TypingBenchmarkView(model: model) }
        .onDisappear { model.cancelBenchmark() }
    }
  }
}

private struct TypingBenchmarkView: View {
  @Bindable var model: TypingPlaygroundModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("On-device benchmark") {
          Text(
            "Runs the same 24 phrases three times, then four section-adjustment cases twice each. Keep this screen open until it finishes."
          )
          Text(
            "Only the bundled test phrases appear in the report. Your notebook writing is never included."
          )
          .font(.footnote).foregroundStyle(.secondary)
          #if targetEnvironment(simulator)
            Text("Simulator CPU — these are Mac timings, not iPhone timings.")
          #else
            Text("Native Metal · normal-effort neural model")
          #endif
          Button(model.benchmarking ? "Running…" : "Run benchmark") { model.startBenchmark() }
            .disabled(model.benchmarking || model.state != "ready" || model.activeConversions > 0)
          if model.activeConversions > 0 { Text("Finishing the current conversion…") }
          if model.benchmarking {
            ProgressView(value: Double(model.progress), total: Double(max(1, model.total)))
              .accessibilityLabel("Benchmark conversions completed")
            Text("\(model.progress) of \(model.total) conversions")
            Button("Stop after this conversion", role: .cancel) { model.cancelBenchmark() }
          }
        }
        if let report = model.report, !model.benchmarking {
          Section(report.completed ? "Results" : "Partial results") {
            if let median = report.ordinaryMedian {
              LabeledContent("Typical conversion", value: "\(Int(median.rounded())) ms")
            }
            if let failure = report.failure { Text(failure) }
            if let url = model.reportURL { ShareLink("Share benchmark results", item: url) }
          }
        }
        if let error = model.error { Section("Engine status") { Text(error) } }
        Section {
          NavigationLink("Engine credits and licenses") {
            ScrollView {
              Text(PlaygroundEngine.attributions()).font(.footnote).textSelection(.enabled)
                .padding()
            }
            .navigationTitle("Engine credits")
          }
        }
      }
      .navigationTitle("Typing benchmark")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(model.benchmarking)
        }
      }
      .interactiveDismissDisabled(model.benchmarking)
    }
  }
}
