#if os(iOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision
import VisionKit

struct EnrollmentSection: View {
    @Bindable var model: RelayDemoModel
    @AppStorage("nodeDisplayName") private var displayName = "My Device"
    @State private var isShowingScanner = false
    @State private var isShowingConfirmation = false
    @State private var isShowingScanError = false
    @State private var pendingEnrollment: NodeEnrollmentPayload?
    @State private var pendingEnrollmentString = ""

    private var enrollmentString: String {
        (try? NodeEnrollmentPayload(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            nodeID: model.nodeID,
            publicKeyBase64: model.publicKeyBase64
        ).encodedString()) ?? ""
    }

    var body: some View {
        Section("Enrollment") {
            TextField("This Device Name", text: $displayName)

            DisclosureGroup("My Node QR Code") {
                NodeQRCodeImage(payload: enrollmentString)
                    .frame(maxWidth: .infinity)
                Text("Contains only this device’s name, Node ID, and public enrollment key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Scan Peer QR Code", systemImage: "qrcode.viewfinder") {
                isShowingScanner = true
            }
            .disabled(!DataScannerViewController.isSupported)
        }
        .sheet(isPresented: $isShowingScanner) {
            NavigationStack {
                NodeQRCodeScanner { scannedString in
                    isShowingScanner = false
                    handleScannedString(scannedString)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Peer")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isShowingScanner = false
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Add this peer?",
            isPresented: $isShowingConfirmation,
            presenting: pendingEnrollment
        ) { enrollment in
            Button("Add \(enrollment.displayName)") {
                try? model.importPeer(from: pendingEnrollmentString)
            }
            Button("Cancel", role: .cancel) {}
        } message: { enrollment in
            Text(enrollment.nodeID)
        }
        .alert("Invalid BeakrNet QR Code", isPresented: $isShowingScanError) {
            Button("OK") {}
        } message: {
            Text("The code is not a valid, cryptographically consistent node enrollment.")
        }
    }

    private func handleScannedString(_ string: String) {
        do {
            pendingEnrollment = try NodeEnrollmentPayload.decodeAndValidate(string)
            pendingEnrollmentString = string
            isShowingConfirmation = true
        } catch {
            isShowingScanError = true
        }
    }
}

private struct NodeQRCodeImage: View {
    let payload: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Node enrollment QR code")
            } else {
                ProgressView()
            }
        }
        .frame(minHeight: 220)
        .task(id: payload) {
            image = QRCodeGenerator.image(for: payload)
        }
    }
}

private enum QRCodeGenerator {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        ), let cgImage = CIContext().createCGImage(
            outputImage,
            from: outputImage.extent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private struct NodeQRCodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        Task { @MainActor in
            try? scanner.startScanning()
        }
        return scanner
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue else {
                    continue
                }
                hasScanned = true
                dataScanner.stopScanning()
                onScan(payload)
                return
            }
        }
    }
}
#endif
