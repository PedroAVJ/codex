import Foundation
import Testing
@testable import CodexVoiceBridge

@Test func codexAppServerUsesTheStandaloneControlSocket() {
    #expect(CodexAppServer.controlSocketPath(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/Users/tester")
    ) == "/Users/tester/.codex/app-server-control/app-server-control.sock")
    #expect(CodexAppServer.controlSocketPath(
        environment: ["CODEX_HOME": "/tmp/codex-home"],
        homeDirectory: URL(fileURLWithPath: "/Users/tester")
    ) == "/tmp/codex-home/app-server-control/app-server-control.sock")
}

@Test func codexAppServerRequestHasABoundedTimeout() async {
    let server = CodexAppServer(executable: URL(fileURLWithPath: "/usr/bin/true"))
    let timedOut = await withCheckedContinuation { continuation in
        server.sendRequest(method: "thread/start", params: [:], timeout: 0.01) { result in
            let matches: Bool
            if case .failure(let error) = result,
               let serverError = error as? CodexServerError,
               case .requestTimedOut(let method) = serverError {
                matches = method == "thread/start"
            } else {
                matches = false
            }
            continuation.resume(returning: matches)
        }
    }
    #expect(timedOut)
}

@Test func codexAppServerReportsManagedDaemonStartFailure() async {
    let server = CodexAppServer(
        executable: URL(fileURLWithPath: "/usr/bin/false"),
        socketPath: "/tmp/codex-voice-test-unused.sock"
    )
    let status = await withCheckedContinuation { continuation in
        server.start { result in
            if case .failure(let error) = result,
               let serverError = error as? CodexServerError,
               case .daemonStartFailed(let status) = serverError {
                continuation.resume(returning: status)
            } else {
                continuation.resume(returning: -1)
            }
        }
    }
    #expect(status == 1)
}

@Test func codexThreadStartGateSuppressesRetriesAndResetsAfterReconnect() {
    var gate = CodexThreadStartGate()
    #expect(gate.begin() == .start(1))
    #expect(gate.begin() == .suppressInFlight)
    let completed = gate.complete(generation: 1, succeeded: false)
    #expect(completed)
    #expect(gate.begin() == .suppressFailed)

    gate.reset()
    #expect(gate.begin() == .start(3))
}
