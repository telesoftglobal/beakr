import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import BeakrNetAuthority

struct InvitationMetadata: Equatable, Sendable {
    let issuedAt: Date
    let expiresAt: Date

    init?(invitation: String) {
        guard let decoded = try? NetworkInvitationWireCodec.decode(Data(invitation.utf8)) else {
            return nil
        }
        issuedAt = Date(timeIntervalSince1970: Double(decoded.issuedAtMilliseconds) / 1_000)
        expiresAt = Date(timeIntervalSince1970: Double(decoded.expiresAtMilliseconds) / 1_000)
    }

    var duration: TimeInterval {
        max(1, expiresAt.timeIntervalSince(issuedAt))
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(date))
    }

    func isExpired(at date: Date) -> Bool {
        remaining(at: date) == 0
    }
}

struct InvitationQRCodeView: View {
    let invitation: String

    var body: some View {
        if let metadata = InvitationMetadata(invitation: invitation) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 12) {
                    if metadata.isExpired(at: context.date) {
                        ContentUnavailableView(
                            "Invitation Expired",
                            systemImage: "timer",
                            description: Text("Generate a new invitation to continue.")
                        )
                    } else if let image {
                        image
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(20)
                            .background(.white)
                            .accessibilityLabel("Network invitation QR code")
                    }

                    InvitationLifetimeView(metadata: metadata, now: context.date)
                }
            }
        } else {
            ContentUnavailableView(
                "QR Code Unavailable",
                systemImage: "qrcode",
                description: Text("The invitation is too large to encode.")
            )
        }
    }

    private var image: Image? {
        guard let invitationURL = InvitationLink.url(for: invitation) else {
            return nil
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invitationURL.absoluteString.utf8)
        filter.correctionLevel = "L"

        let context = CIContext()
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1)
    }
}

private struct InvitationLifetimeView: View {
    let metadata: InvitationMetadata
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            Gauge(value: metadata.remaining(at: now), in: 0...metadata.duration) {
                Image(systemName: "timer")
                    .accessibilityHidden(true)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(metadata.isExpired(at: now) ? .red : .accentColor)
            .frame(width: 36, height: 36)
            .accessibilityLabel("Invitation time remaining")
            .accessibilityValue(Text(countdownText))

            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if metadata.isExpired(at: now) {
                        Text("Expired")
                            .foregroundStyle(.red)
                    } else {
                        Text("Valid for \(Text(countdownText))")
                    }
                }
                .font(.headline)
                Text("Created \(metadata.issuedAt, format: .dateTime.hour().minute().second())")
                Text("Expires \(metadata.expiresAt, format: .dateTime.hour().minute().second())")
                Text("Single use")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countdownText: AttributedString {
        now.formatted(
            .timer(
                countingDownIn: metadata.issuedAt..<metadata.expiresAt,
                showsHours: false,
                maxFieldCount: 2,
                maxPrecision: .seconds(1)
            )
        )
    }
}

struct InvitationShareLink<Label: View>: View {
    let invitation: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let metadata = InvitationMetadata(invitation: invitation),
           let invitationURL = InvitationLink.url(for: invitation) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ShareLink(item: invitationURL, label: label)
                    .disabled(metadata.isExpired(at: context.date))
            }
        }
    }
}

struct InvitationCopyButton: View {
    let invitation: String
    let action: () -> Void

    var body: some View {
        if let metadata = InvitationMetadata(invitation: invitation) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button("Copy", systemImage: "doc.on.doc", action: action)
                    .disabled(metadata.isExpired(at: context.date))
            }
        } else {
            Button("Copy", systemImage: "doc.on.doc", action: action)
                .disabled(true)
        }
    }
}
