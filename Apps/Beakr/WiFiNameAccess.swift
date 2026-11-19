#if os(iOS)
import CoreLocation
import NetworkExtension
import Observation
import SwiftUI
import UIKit

/// Optional access to the current SSID. Never requests or stores location coordinates.
@MainActor
@Observable
final class WiFiNameAccess: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiNameAccess()

    // Enable only with an iOS provisioning profile supporting Access Wi-Fi
    // Information, Beakr-iOS.entitlements, and this iOS-only Swift condition.
#if BEAKR_WIFI_NAME_CAPABILITY
    static let isSupported = true
#else
    static let isSupported = false
#endif
    private static let preferenceKey = "net.beakr.settings.showWiFiName"

    private(set) var isEnabled: Bool
    private(set) var authorization: CLAuthorizationStatus
    private(set) var accuracy: CLAccuracyAuthorization
    private(set) var revision = 0
    @ObservationIgnored private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        isEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        authorization = manager.authorizationStatus
        accuracy = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
    }

    var canReadName: Bool {
        Self.isSupported && isEnabled
            && (authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
            && accuracy == .fullAccuracy
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || Self.isSupported else { return }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        revision += 1
        refreshAuthorization()
        if enabled { requestPermissionIfNeeded() }
    }

    func requestPermissionIfNeeded() {
        guard Self.isSupported, isEnabled, manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func refreshAuthorization() {
        let newAuthorization = manager.authorizationStatus
        let newAccuracy = manager.accuracyAuthorization
        guard authorization != newAuthorization || accuracy != newAccuracy else { return }
        authorization = newAuthorization
        accuracy = newAccuracy
        revision += 1
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.refreshAuthorization()
        }
    }

    func currentName() async -> String? {
        refreshAuthorization()
        guard canReadName else { return nil }
        let name: String? = await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        // Permission or the preference may change while the request is in flight.
        refreshAuthorization()
        guard canReadName, let name, !name.isEmpty else { return nil }
        return name
    }
}

struct WiFiNamePermissionSection: View {
    @Environment(\.openURL) private var openURL
    private let access = WiFiNameAccess.shared

    var body: some View {
        Section {
            Toggle("Show Wi-Fi Name", isOn: Binding(
                get: { access.isEnabled },
                set: { access.setEnabled($0) }
            ))
            .disabled(!WiFiNameAccess.isSupported)
            if !WiFiNameAccess.isSupported {
                Text("Wi-Fi names aren’t available in this build. This Device IP is shown instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if access.isEnabled {
                Text(permissionExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if access.authorization == .notDetermined {
                    Button("Allow Location Access") {
                        access.requestPermissionIfNeeded()
                    }
                } else if access.authorization != .restricted && !access.canReadName {
                    Button("Open iOS Settings", systemImage: "gear") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("Wi-Fi Name")
        } footer: {
            Text("Apple requires Precise Location permission to read the Wi-Fi name. Beakr uses this permission only to identify your Wi-Fi network; it does not request or store your location coordinates. This Device IP remains the fallback. A Wi-Fi name may be shared by multiple network segments.")
        }
    }

    private var permissionExplanation: LocalizedStringResource {
        switch access.authorization {
        case .notDetermined:
            return "Choose Allow While Using App and leave Precise Location enabled in the permission prompt."
        case .denied:
            return "Location access is off. In iOS Settings, allow location access While Using the App and turn on Precise Location."
        case .restricted:
            return "Location access is restricted on this device. This Device IP will be shown instead."
        case .authorizedAlways, .authorizedWhenInUse:
            if access.accuracy != .fullAccuracy {
                return "Turn on Precise Location for Beakr in iOS Settings to show the Wi-Fi name."
            }
            return "Permission is ready. The Wi-Fi name appears when iOS makes it available."
        @unknown default:
            return "Location permission is unavailable. This Device IP will be shown instead."
        }
    }
}
#endif
