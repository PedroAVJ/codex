import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VoiceSessionModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let request = model.pendingApproval {
                ApprovalScreen(request: request) { approved in
                    model.resolveApproval(approved: approved)
                }
                .ignoresSafeArea()
            } else if model.isPaired {
                VoiceScreen(model: model)
                    .ignoresSafeArea()
            } else {
                PairingScreen(model: model)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.errorText)
    }
}

private struct PairingScreen: View {
    @ObservedObject var model: VoiceSessionModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            RelayMark(size: 52)
            Text("Finish setup on iPhone")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Text(model.errorText ?? "Open Pedro Voice Agent and send the secure pairing to this Watch.")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(model.errorText == nil ? .white.opacity(0.52) : RelayTheme.danger)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 4)
                .padding(.horizontal, 5)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 3)
    }
}

private struct VoiceScreen: View {
    @ObservedObject var model: VoiceSessionModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if model.sessionEnded {
                    exceptionalState(
                        title: "Session ended",
                        detail: nil,
                        actionLabel: "Start again",
                        action: model.retry,
                        orbSize: exceptionalOrbSize(in: proxy.size)
                    )
                    .padding(.horizontal, 11)
                    .padding(.top, 12)
                    .padding(.bottom, 7)
                } else if let error = model.errorText {
                    exceptionalState(
                        title: errorTitle,
                        detail: error,
                        actionLabel: "Retry now",
                        action: model.retry,
                        orbSize: exceptionalOrbSize(in: proxy.size)
                    )
                    .padding(.horizontal, 11)
                    .padding(.top, 12)
                    .padding(.bottom, 7)
                } else if model.phase == .connecting {
                    connectionState(orbSize: exceptionalOrbSize(in: proxy.size))
                        .padding(.horizontal, 11)
                        .padding(.top, 12)
                        .padding(.bottom, 7)
                } else {
                    liveState(in: proxy.size)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func liveState(in size: CGSize) -> some View {
        let orbSize = min(size.width * 0.54, 104)
        let controlSize = min(40, max(36, size.width * 0.19))
        let orbCenterY = min(size.height * 0.515, size.height - controlSize - (orbSize / 2) - 12)
        let controlsCenterY = size.height - (controlSize / 2) - 7

        return ZStack {
            RelayPulse(
                size: orbSize,
                isDimmed: model.isMuted
            )
            .position(x: size.width / 2, y: orbCenterY)

            HStack(spacing: 10) {
                VoiceControlButton(
                    systemName: model.isMuted ? "microphone.slash.fill" : "microphone.fill",
                    foreground: .white,
                    background: Color.white.opacity(0.14),
                    size: controlSize,
                    accessibilityLabel: model.isMuted ? "Unmute" : "Mute",
                    action: model.toggleMute
                )
                VoiceControlButton(
                    systemName: "xmark",
                    foreground: .black,
                    background: .white,
                    size: controlSize,
                    accessibilityLabel: "End voice session",
                    action: model.endSession
                )
            }
            .position(x: size.width / 2, y: controlsCenterY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(liveAccessibilityLabel)
    }

    private func connectionState(orbSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 5)
            ZStack {
                RelayPulse(size: orbSize, isDimmed: true)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.82))
                    .controlSize(.small)
            }
            Text(connectionTitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 10)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(connectionTitle)
    }

    private func exceptionalState(
        title: String,
        detail: String?,
        actionLabel: String,
        action: @escaping () -> Void,
        orbSize: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 3)
            RelayPulse(size: orbSize, isDimmed: title != "Session ended")
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(title == "Couldn't connect" ? RelayTheme.danger : .white)
                .multilineTextAlignment(.center)
                .padding(.top, 7)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 5)
            VoiceControlButton(
                systemName: "arrow.clockwise",
                foreground: .black,
                background: .white,
                size: 44,
                accessibilityLabel: actionLabel,
                action: action
            )
        }
    }

    private func exceptionalOrbSize(in size: CGSize) -> CGFloat {
        min(size.width * 0.42, size.height * 0.34)
    }

    private var connectionTitle: String {
        let status = model.status.lowercased()
        return status.contains("retry") || status.contains("unavailable")
            ? "Reconnecting"
            : "Connecting"
    }

    private var errorTitle: String {
        let status = model.status.lowercased()
        return status.contains("microphone") || status.contains("audio")
            ? "Voice unavailable"
            : "Couldn't connect"
    }

    private var liveAccessibilityLabel: String {
        if model.isMuted { return "Voice Relay is muted" }
        switch model.phase {
        case .thinking: return "Your agent is working. You can interrupt at any time."
        case .speaking: return "Your agent is responding. You can interrupt at any time."
        default: return "Voice Relay is listening"
        }
    }
}

private struct RelayPulse: View {
    let size: CGFloat
    var isDimmed = false

    var body: some View {
        Image("RelayPulse")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .saturation(isDimmed ? 0.45 : 1)
            .opacity(isDimmed ? 0.56 : 1)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct VoiceControlButton: View {
    let systemName: String
    let foreground: Color
    let background: Color
    let size: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.37, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ApprovalScreen: View {
    let request: ApprovalRequest
    let resolve: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    RelayPulse(size: 52)
                    Text("Approval needed")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.top, 7)
                    Text(request.message.isEmpty ? request.title : request.message)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                        .padding(.horizontal, 12)
                }
                .frame(width: proxy.size.width)
                .padding(.top, 32)

                HStack(spacing: 7) {
                    approvalButton("Don't allow", approved: false)
                    approvalButton("Allow", approved: true)
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .bottom
                )
            }
        }
    }

    private func approvalButton(_ title: String, approved: Bool) -> some View {
        Button { resolve(approved) } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(approved ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    approved ? Color.white : Color.white.opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
