#if os(macOS)
import SwiftUI

/// Shows observed transfer size/speed without reading credential-bearing CLI logs.
struct MacIPAToolProgressView: View {
    let progress: MacIPAToolFallback.ProgressUpdate

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text(progress.stage.title)
                Spacer()
                if let fraction = progress.estimatedFraction {
                    Text("~\(Int(fraction * 100))%")
                        .monospacedDigit()
                }
            }

            if let fraction = progress.estimatedFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }

            HStack {
                if progress.bytesReceived > 0 {
                    Text("\(bytes(progress.bytesReceived)) downloaded")
                } else {
                    Text("Waiting for IPA transfer…")
                }
                Spacer()
                if progress.bytesPerSecond > 0 {
                    Text("\(bytes(progress.bytesPerSecond))/s")
                }
            }
            .foregroundStyle(.secondary)

            if progress.estimatedFraction != nil {
                Text("Approximate progress based on App Store size; actual IPA may differ.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .padding(.vertical, 4)
    }
}
#endif
