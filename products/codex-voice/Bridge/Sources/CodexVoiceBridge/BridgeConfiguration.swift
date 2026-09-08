import Foundation

struct BridgeConfiguration {
    var cwd: String
    var supportDirectory: URL
    var serviceName: String
    var defaultVoice: String
    var model: String
    var voiceModel: String
    var codexExecutable: URL
    var relayURL: URL

    static func parse(arguments: [String]) throws -> BridgeConfiguration {
        var cwd = FileManager.default.currentDirectoryPath
        var supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexVoice", isDirectory: true)
        var serviceName = "Pedro Voice Agent on \(Host.current().localizedName ?? "Mac")"
        var defaultVoice = "alloy"
        var model = ProcessInfo.processInfo.environment["CODEX_VOICE_MODEL"] ?? "gpt-5.6-luna"
        var voiceModel = ProcessInfo.processInfo.environment["CODEX_VOICE_OPENROUTER_AUDIO_MODEL"]
            ?? "openai/gpt-audio-mini"
        var codexExecutable = defaultCodexExecutable()
        var relayURL: URL?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--cwd":
                index += 1
                cwd = try value(at: index, in: arguments, for: argument)
            case "--port":
                index += 1
                let raw = try value(at: index, in: arguments, for: argument)
                guard UInt16(raw) != nil else { throw ConfigurationError.invalidPort(raw) }
            case "--support-dir":
                index += 1
                supportDirectory = URL(
                    fileURLWithPath: try value(at: index, in: arguments, for: argument),
                    isDirectory: true
                )
            case "--service-name":
                index += 1
                serviceName = try value(at: index, in: arguments, for: argument)
            case "--voice":
                index += 1
                defaultVoice = try value(at: index, in: arguments, for: argument)
            case "--model":
                index += 1
                model = try value(at: index, in: arguments, for: argument)
            case "--voice-model", "--realtime-model":
                index += 1
                voiceModel = try value(at: index, in: arguments, for: argument)
            case "--codex-binary":
                index += 1
                codexExecutable = URL(fileURLWithPath: try value(at: index, in: arguments, for: argument))
            case "--relay-url":
                index += 1
                let raw = try value(at: index, in: arguments, for: argument)
                relayURL = URL(string: raw)
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw ConfigurationError.unknownArgument(argument)
            }
            index += 1
        }

        let standardizedCWD = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedCWD, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationError.invalidWorkingDirectory(standardizedCWD)
        }
        guard let relayURL,
              relayURL.scheme?.lowercased() == "wss",
              relayURL.host != nil else {
            throw ConfigurationError.invalidRelayURL
        }

        return BridgeConfiguration(
            cwd: standardizedCWD,
            supportDirectory: supportDirectory.standardizedFileURL,
            serviceName: serviceName,
            defaultVoice: defaultVoice,
            model: model,
            voiceModel: voiceModel,
            codexExecutable: codexExecutable,
            relayURL: relayURL
        )
    }

    private static func value(at index: Int, in arguments: [String], for flag: String) throws -> String {
        guard arguments.indices.contains(index) else { throw ConfigurationError.missingValue(flag) }
        return arguments[index]
    }

    private static func defaultCodexExecutable() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let chatGPTBundled = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        if FileManager.default.isExecutableFile(atPath: chatGPTBundled.path) {
            return chatGPTBundled
        }
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex")
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return local
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private static func printUsage() {
        print("""
        Usage: codex-voice-bridge [options]

          --cwd PATH            Folder Codex may work in (default: current directory)
          --port PORT           Deprecated compatibility option; ignored
          --support-dir PATH    Private keys and paired devices
          --service-name NAME   Mac display name shown to paired devices
          --voice NAME          OpenRouter audio voice (default: alloy)
          --model NAME          Codex model (default: gpt-5.6-luna)
          --voice-model NAME    OpenRouter audio model (default: openai/gpt-audio-mini)
          --realtime-model NAME Deprecated alias for --voice-model
          --codex-binary PATH   Codex CLI executable
          --relay-url WSS_URL   Secure Codex Voice relay endpoint
        """)
    }
}

enum ConfigurationError: LocalizedError {
    case missingValue(String)
    case invalidPort(String)
    case invalidWorkingDirectory(String)
    case invalidRelayURL
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): "Missing value for \(flag)"
        case .invalidPort(let value): "Invalid port: \(value)"
        case .invalidWorkingDirectory(let path): "Working directory does not exist: \(path)"
        case .invalidRelayURL: "A secure wss:// Codex Voice relay URL is required."
        case .unknownArgument(let argument): "Unknown argument: \(argument)"
        }
    }
}
