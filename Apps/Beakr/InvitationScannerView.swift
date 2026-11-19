#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import Vision
import VisionKit
import BeakrNetEnrollment
import BeakrNetAuthority

// Permission changes can terminate the app while Settings is foregrounded.
// Persist only the return destination, never invitation contents or credentials.
struct InvitationScannerReturnRoute: Codable, Identifiable {
    let id: UUID
    let initialNetworkID: UUID?
    let repairProfileID: UUID?
    let repairNetworkID: UUID?
    let createdAt: Date

    private static let storageKey = "net.beakr.scanner.settingsReturn"

    init(initialNetworkID: UUID?, repairProfileID: UUID?, repairNetworkID: UUID?) {
        id = UUID()
        self.initialNetworkID = initialNetworkID
        self.repairProfileID = repairProfileID
        self.repairNetworkID = repairNetworkID
        createdAt = Date()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func take(from defaults: UserDefaults = .standard) -> Self? {
        defer { clear(in: defaults) }
        guard let data = defaults.data(forKey: storageKey),
              let route = try? JSONDecoder().decode(Self.self, from: data),
              Date().timeIntervalSince(route.createdAt) >= 0,
              Date().timeIntervalSince(route.createdAt) < 900 else { return nil }
        return route
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

struct InvitationScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    var initialNetworkID: UUID? = nil
    var repairProfileID: UUID? = nil
    var repairNetworkID: UUID? = nil
    let onRecognized: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "camera.fill",
                        description: Text("This device does not support camera scanning. You can paste an invitation instead.")
                    )
                } else if authorizationStatus == .denied {
                    ContentUnavailableView {
                        Label("Camera Access Required", systemImage: "camera.fill")
                    } description: {
                        Text("Allow Camera access for Beakr in Settings to scan an invitation.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                InvitationScannerReturnRoute(
                                    initialNetworkID: initialNetworkID,
                                    repairProfileID: repairProfileID,
                                    repairNetworkID: repairNetworkID
                                ).save()
                                openURL(url) { accepted in
                                    if !accepted { InvitationScannerReturnRoute.clear() }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if authorizationStatus == .restricted {
                    ContentUnavailableView(
                        "Camera Access Restricted",
                        systemImage: "camera.fill",
                        description: Text("Camera access is restricted on this device, for example by Screen Time or device management. You can paste an invitation instead.")
                    )
                } else if authorizationStatus == .notDetermined || scenePhase != .active {
                    ProgressView("Waiting for camera access…")
                } else if authorizationStatus == .authorized,
                          DataScannerViewController.isAvailable {
                    InvitationScannerView(onRecognized: onRecognized)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "camera.fill",
                        description: Text("Camera scanning is currently unavailable. Close the scanner and try again, or paste an invitation.")
                    )
                }
            }
            .task {
                guard DataScannerViewController.isSupported else { return }
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                guard !Task.isCancelled else { return }
                authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
            .onChange(of: scenePhase) { _, phase in
                // Settings changes do not update SwiftUI state by themselves.
                // Recheck on return so granting access restores the scanner.
                if phase == .active {
                    InvitationScannerReturnRoute.clear()
                    authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
            .navigationTitle("Scan Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        InvitationScannerReturnRoute.clear()
                        dismiss()
                    }
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
                      (try? NetworkInvitationWireCodec.decode(data)) != nil
                        || (try? EnrollmentWireCodec.decode(EnrollmentInvitation.self, from: data)) != nil else {
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
