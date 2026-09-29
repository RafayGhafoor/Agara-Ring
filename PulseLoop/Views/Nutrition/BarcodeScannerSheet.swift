import SwiftUI
#if AGARA_CAMERA
import Vision
import VisionKit
#endif

#if AGARA_CAMERA
/// Barcode scanner for packaged-food lookup, wrapping VisionKit's `DataScannerViewController`
/// (EAN/UPC symbologies — what Open Food Facts is keyed on). Calls `onScan` once with the
/// first recognized code. Falls back to a message when scanning isn't supported (Simulator,
/// no camera permission).
struct BarcodeScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var scanningAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanningAvailable {
                    BarcodeScannerRepresentable(onScan: onScan)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "barcode.viewfinder")
                            .font(AgaraFont.largeTitle.weight(.regular))
                            .foregroundStyle(AgaraColors.textMuted)
                        Text("Scanning unavailable")
                            .font(AgaraFont.bodyEmphasis)
                            .foregroundStyle(AgaraColors.textPrimary)
                        Text("Barcode scanning needs a device camera and camera access. Search by name instead.")
                            .font(AgaraFont.caption.weight(.regular))
                            .foregroundStyle(AgaraColors.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AgaraColors.background)
                }
            }
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}

private struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .fast,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue, !payload.isEmpty {
                    delivered = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
#else
/// Camera compiled out (see `CameraSupport`): the scan button is hidden, so this is never presented.
struct BarcodeScannerSheet: View {
    let onScan: (String) -> Void
    var body: some View { EmptyView() }
}
#endif
