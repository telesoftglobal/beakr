import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import BeakrNetAuthority
import BeakrNetEnrollment

struct InvitationMetadata: Equatable, Sendable {
    let issuedAt: Date
    let expiresAt: Date

    init?(invitation: String) {
        if let decoded = try? EnrollmentWireCodec.decode(
            EnrollmentInvitation.self,
            from: Data(invitation.utf8)
        ) {
            issuedAt = Date(timeIntervalSince1970: Double(decoded.issuedAtMilliseconds) / 1_000)
            expiresAt = Date(timeIntervalSince1970: Double(decoded.expiresAtMilliseconds) / 1_000)
            return
        }
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
    var regenerate: (() -> Void)?

    @State private var renderedInvitation: String?
    @State private var image: Image?

    init(invitation: String, regenerate: (() -> Void)? = nil) {
        self.invitation = invitation
        self.regenerate = regenerate
    }

    var body: some View {
        if let metadata = InvitationMetadata(invitation: invitation) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 12) {
                    InvitationLifetimeView(
                        metadata: metadata,
                        now: context.date,
                        regenerate: regenerate
                    )

                    if metadata.isExpired(at: context.date) {
                        ContentUnavailableView(
                            "Invitation Expired",
                            systemImage: "timer",
                            description: Text("Generate a new invitation to continue.")
                        )
                    } else if renderedInvitation == invitation, let image {
                        image
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(20)
                            .background(.white)
                            .accessibilityLabel("Network invitation QR code")
                    }

                }
            }
            .onChange(of: invitation, initial: true) { _, newInvitation in
                // The countdown updates every second; only a changed invitation needs rendering.
                image = Self.makeImage(for: newInvitation)
                renderedInvitation = newInvitation
            }
        } else {
            ContentUnavailableView(
                "QR Code Unavailable",
                systemImage: "qrcode",
                description: Text("The invitation is too large to encode.")
            )
        }
    }

    private static func makeImage(for invitation: String) -> Image? {
        guard let invitationURL = InvitationLink.url(for: invitation) else {
            return nil
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invitationURL.absoluteString.utf8)
        filter.correctionLevel = "L"

        // The QR generator supplies a bitmap directly. Creating a CIContext here
        // unnecessarily initializes Metal and its binary-archive usage database.
        guard let cgImage = filter.outputImage?.cgImage else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1)
    }
}

private struct InvitationLifetimeView: View {
    let metadata: InvitationMetadata
    let now: Date
    let regenerate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Time Remaining")
                Spacer()
                if let regenerate {
                    Button("Re-Generate", systemImage: "arrow.clockwise", action: regenerate)
                }
            }

            HStack {
                Label(metadata.isExpired(at: now) ? "Expired" : "Valid for \(countdownText)", systemImage: "timer")
                    .foregroundStyle(metadata.isExpired(at: now) ? Color.red : Color.primary)
                Spacer()
                Text("Expires \(metadata.expiresAt, format: .dateTime.hour().minute().second())")
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.25))
                    Capsule()
                        .fill(metadata.isExpired(at: now) ? Color.red : Color.green)
                        .frame(
                            width: geometry.size.width
                                * metadata.remaining(at: now) / metadata.duration
                        )
                }
            }
            .frame(height: 3)
            .accessibilityLabel("Invitation time remaining")
            .accessibilityValue(Text(countdownText))
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
        if let metadata = InvitationMetadata(invitation: invitation) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ShareLink(item: invitation, label: label)
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
