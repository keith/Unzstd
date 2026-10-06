import SwiftUI

struct ContentView: View {
  @ObservedObject var model: ExtractionModel
  @State private var isDropTarget = false

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      Image(systemName: model.error == nil ? "archivebox.fill" : "exclamationmark.triangle.fill")
        .font(.system(size: 44, weight: .regular))
        .foregroundStyle(model.error == nil ? Color.accentColor : .orange)
        .frame(width: 56, height: 62)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 10) {
        Text(model.title)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(model.title)

        if model.isBusy {
          ProgressView(value: model.progress)
            .accessibilityLabel("Extraction progress")
          HStack {
            Text(model.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer()
            Text(model.progress, format: .percent.precision(.fractionLength(0)))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        } else {
          Text(model.error ?? model.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
        }

        HStack {
          if model.pendingCount > 0 {
            Text("\(model.pendingCount) waiting")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if model.isBusy {
            Button("Cancel") { model.cancelAll() }
              .keyboardShortcut(.cancelAction)
              .disabled(model.isCancelling)
          } else {
            if let output = model.lastOutput {
              Button("Show in Finder") { model.reveal(output) }
            }
            Button("Open…") { model.chooseFiles() }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
    }
    .padding(24)
    .frame(width: 480, height: 184)
    .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
    .dropDestination(for: URL.self) { urls, _ in
      model.open(urls)
      return !urls.isEmpty
    } isTargeted: {
      isDropTarget = $0
    }
  }
}
