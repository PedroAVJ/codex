import PhotosUI
import SwiftUI

struct CompanionContentView: View {
    @ObservedObject var model: CompanionModel
    @State private var selectedQRImage: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ZStack {
                RelayTheme.paper.ignoresSafeArea()
                VStack(spacing: 18) {
                    Spacer()
                    RelayMark(size: 74)
                    VStack(spacing: 9) {
                        Text("Voice mode, from your wrist")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(RelayTheme.ink)
                        Text("Pedro Voice Agent securely connects Apple Watch to the coding agent on your Mac. Designed and built by Pedro Villanueva.")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(RelayTheme.secondaryInk)
                            .multilineTextAlignment(.center)
                    }

                    statusCard

                    if model.phase == .paired {
                        if !model.watchSyncState.isSynced {
                            Button(action: model.resendToWatch) {
                                Label("Send to Apple Watch", systemImage: "applewatch.and.arrow.forward")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(RelayTheme.ink)
                            .controlSize(.large)
                        }
                        Button("Pair a different Mac") { model.scan() }
                            .buttonStyle(.bordered)
                            .tint(RelayTheme.ink)
                            .controlSize(.large)
                        Button("Forget this Mac", role: .destructive) { model.forgetMac() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(action: model.scan) {
                            Label("Scan Mac QR", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RelayTheme.ink)
                        .controlSize(.large)
                        .disabled(model.phase == .connecting)

                        PhotosPicker(selection: $selectedQRImage, matching: .images) {
                            Label("Choose QR Image", systemImage: "photo.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(RelayTheme.ink)
                        .controlSize(.large)
                        .disabled(model.phase == .connecting)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .sheet(isPresented: $model.isShowingScanner, onDismiss: model.scannerDismissed) {
                QRScannerView { url in model.open(url) }
                    .ignoresSafeArea()
            }
            .onChange(of: selectedQRImage) { _, item in
                guard let item else { return }
                Task {
                    defer { selectedQRImage = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw PairingQRCodeError.unreadableImage
                        }
                        model.importPairingImage(data)
                    } catch {
                        model.failImageImport(with: error)
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                    .foregroundStyle(RelayTheme.ink)
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(statusIsError ? RelayTheme.danger : RelayTheme.secondaryInk)
            }
            Spacer()
            if model.phase == .connecting {
                ProgressView().tint(RelayTheme.ink)
            }
        }
        .padding(16)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RelayTheme.separator, lineWidth: 1)
        }
    }

    private var statusIcon: String {
        if model.phase == .paired {
            return model.watchSyncState.isSynced ? "applewatch.radiowaves.left.and.right" : "applewatch.and.arrow.forward"
        }
        switch model.phase {
        case .paired: return "applewatch.and.arrow.forward"
        case .connecting: return "lock.rotation"
        case .scanning: return "qrcode.viewfinder"
        case .unpaired: return "desktopcomputer"
        }
    }

    private var statusColor: Color {
        model.phase == .paired && model.watchSyncState.isSynced ? RelayTheme.live : RelayTheme.ink
    }

    private var statusTitle: String {
        guard model.phase == .paired else { return "Mac pairing" }
        return model.watchSyncState.isSynced ? "Ready on Apple Watch" : "Mac paired · Watch pending"
    }

    private var statusMessage: String {
        if let errorText = model.errorText { return errorText }
        guard model.phase == .paired else { return model.status }
        return model.watchSyncState.message
    }

    private var statusIsError: Bool {
        if model.errorText != nil { return true }
        if case .failed = model.watchSyncState { return true }
        return false
    }
}
