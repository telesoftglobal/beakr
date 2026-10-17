#if os(iOS)
import SwiftUI
import Vision
import VisionKit
import BeakrNetAuthority

struct InvitationScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onRecognized: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                if DataScannerViewController.isSupported,
                   DataScannerViewController.isAvailable {
                    InvitationScannerView(onRecognized: onRecognized)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "camera.fill",
                        description: Text("Camera scanning is unavailable or camera access is restricted.")
                    )
                }
            }
            .navigationTitle("Scan Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct InvitationScannerView: UIViewControllerRepresentable {
    let onRecognized: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(
        _ scanner: DataScannerViewController,
        coordinator: Coordinator
    ) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onRecognized: (String) -> Void
        private var completed = false

        init(onRecognized: @escaping (String) -> Void) {
            self.onRecognized = onRecognized
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !completed else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue else {
                    continue
                }
                let invitation = InvitationLink.invitation(from: payload)
                guard
                      let data = invitation.data(using: .utf8),
                      (try? NetworkInvitationWireCodec.decode(data)) != nil else {
                    continue
                }
                completed = true
                dataScanner.stopScanning()
                onRecognized(invitation)
                return
            }
        }
    }
}
#endif
