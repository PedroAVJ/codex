import Dispatch
import Foundation

do {
    if try BridgeCommand.runIfRequested(arguments: CommandLine.arguments) {
        exit(0)
    }
    let configuration = try BridgeConfiguration.parse(arguments: CommandLine.arguments)
    BridgeTelemetry.start()
    let server = try BridgeServer(configuration: configuration)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalQueue = DispatchQueue(label: "com.pedro.codexvoice.signals")
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    let shutdown = {
        server.stop()
        BridgeTelemetry.flush()
        exit(0)
    }
    interrupt.setEventHandler(handler: shutdown)
    terminate.setEventHandler(handler: shutdown)
    interrupt.resume()
    terminate.resume()

    server.start()
    dispatchMain()
} catch {
    BridgeTelemetry.failure("bridge_process", error: error)
    BridgeTelemetry.flush()
    fputs("Codex Voice bridge: \(error.localizedDescription)\n", stderr)
    exit(2)
}
