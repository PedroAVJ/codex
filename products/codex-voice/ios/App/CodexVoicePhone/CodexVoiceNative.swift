import Combine
import Foundation
@preconcurrency import React

@MainActor
final class CodexVoiceCoordinator {
    static let shared = CodexVoiceCoordinator()

    let model = CompanionModel()

    private init() {}

    func open(_ url: URL) {
        model.open(url)
    }

    func snapshot() -> [String: Any] {
        [
            "phase": phaseName(model.phase),
            "status": model.status,
            "errorText": model.errorText ?? NSNull(),
            "watchSyncPhase": watchSyncPhaseName(model.watchSyncState),
            "watchSyncStatus": model.watchSyncState.message,
            "watchReady": model.watchSyncState.isSynced,
        ]
    }

    private func phaseName(_ phase: CompanionModel.Phase) -> String {
        switch phase {
        case .unpaired: "unpaired"
        case .scanning: "scanning"
        case .connecting: "connecting"
        case .paired: "paired"
        }
    }

    private func watchSyncPhaseName(_ state: PhonePairingTransfer.State) -> String {
        switch state {
        case .unavailable: "unavailable"
        case .activating: "activating"
        case .watchNotPaired: "watchNotPaired"
        case .watchAppNotInstalled: "watchAppNotInstalled"
        case .sending: "sending"
        case .synced: "synced"
        case .failed: "failed"
        }
    }
}

@objc(CodexVoiceNative)
final class CodexVoiceNative: RCTEventEmitter, @unchecked Sendable {
    private var changeObserver: AnyCancellable?
    private var hasJavaScriptListeners = false

    override init() {
        super.init()
        DispatchQueue.main.async { [weak self] in
            self?.bindToModel()
        }
    }

    @objc
    override static func requiresMainQueueSetup() -> Bool {
        true
    }

    override func supportedEvents() -> [String] {
        ["CodexVoiceStateChanged"]
    }

    override func startObserving() {
        hasJavaScriptListeners = true
        emitSnapshot()
    }

    override func stopObserving() {
        hasJavaScriptListeners = false
    }

    @objc(getState:rejecter:)
    func getState(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {}
    }

    @objc(openPairingURL:resolver:rejecter:)
    func openPairingURL(
        _ value: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            guard let url = URL(string: value) else {
                throw CodexVoiceNativeError.invalidPairingURL
            }
            CodexVoiceCoordinator.shared.open(url)
        }
    }

    @objc(forgetMac:rejecter:)
    func forgetMac(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            CodexVoiceCoordinator.shared.model.forgetMac()
        }
    }

    @objc(resendToWatch:rejecter:)
    func resendToWatch(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            CodexVoiceCoordinator.shared.model.resendToWatch()
        }
    }

    @MainActor
    private func bindToModel() {
        changeObserver = CodexVoiceCoordinator.shared.model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.emitSnapshot()
                }
            }
    }

    private func emitSnapshot() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasJavaScriptListeners else { return }
            self.sendEvent(
                withName: "CodexVoiceStateChanged",
                body: CodexVoiceCoordinator.shared.snapshot()
            )
        }
    }

    private func resolveState(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock,
        action: @escaping @MainActor () throws -> Void
    ) {
        let callbacks = CodexVoicePromiseCallbacks(
            resolve: resolve,
            reject: reject
        )
        DispatchQueue.main.async {
            do {
                try action()
                callbacks.resolve(CodexVoiceCoordinator.shared.snapshot())
            } catch {
                callbacks.reject(
                    "native_action_failed",
                    error.localizedDescription,
                    error
                )
            }
        }
    }
}

private enum CodexVoiceNativeError: LocalizedError {
    case invalidPairingURL

    var errorDescription: String? {
        switch self {
        case .invalidPairingURL:
            "The QR did not contain a valid URL."
        }
    }
}

private final class CodexVoicePromiseCallbacks: @unchecked Sendable {
    let resolve: RCTPromiseResolveBlock
    let reject: RCTPromiseRejectBlock

    init(
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        self.resolve = resolve
        self.reject = reject
    }
}
