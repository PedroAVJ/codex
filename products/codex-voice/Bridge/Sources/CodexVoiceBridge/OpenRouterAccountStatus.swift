import Foundation

enum OpenRouterAccountStatus {
    static func fetch(apiKey: String) throws -> [String: Any] {
        let keyResponse = try get(
            url: URL(string: "https://openrouter.ai/api/v1/key")!,
            apiKey: apiKey
        )
        guard (200..<300).contains(keyResponse.statusCode),
              let keyObject = try? JSONSerialization.jsonObject(with: keyResponse.data) as? [String: Any],
              let key = keyObject["data"] as? [String: Any] else {
            throw OpenRouterAccountStatusError.api(message(from: keyResponse.data) ?? "The OpenRouter key was rejected.")
        }

        var result: [String: Any] = [
            "authenticated": true,
            "accountCreditsChecked": false,
            "isFreeTier": key["is_free_tier"] as? Bool ?? false,
            "keyLabel": key["label"] as? String ?? "",
            "keyUsage": key["usage"] as? NSNumber ?? 0,
        ]
        result["keyLimit"] = key["limit"] is NSNull ? NSNull() : key["limit"] ?? NSNull()
        result["keyLimitRemaining"] = key["limit_remaining"] is NSNull
            ? NSNull()
            : key["limit_remaining"] ?? NSNull()
        result["keyExpiresAt"] = key["expires_at"] is NSNull ? NSNull() : key["expires_at"] ?? NSNull()

        let creditsResponse = try get(
            url: URL(string: "https://openrouter.ai/api/v1/credits")!,
            apiKey: apiKey
        )
        if (200..<300).contains(creditsResponse.statusCode),
           let object = try? JSONSerialization.jsonObject(with: creditsResponse.data) as? [String: Any],
           let credits = object["data"] as? [String: Any],
           let total = credits["total_credits"] as? NSNumber,
           let usage = credits["total_usage"] as? NSNumber {
            result["accountCreditsChecked"] = true
            result["accountTotalCredits"] = total
            result["accountTotalUsage"] = usage
            result["accountCreditBalance"] = total.doubleValue - usage.doubleValue
        } else {
            result["accountCreditsNote"] = "Account-wide balance requires an OpenRouter management key or the signed-in dashboard."
        }
        return result
    }

    private static func get(url: URL, apiKey: String) throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Pedro Voice Agent", forHTTPHeaderField: "X-OpenRouter-Title")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        var statusCode = 0
        var responseError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data ?? Data()
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 35) == .success else {
            task.cancel()
            throw OpenRouterAccountStatusError.timeout
        }
        if let responseError { throw OpenRouterAccountStatusError.transport(responseError.localizedDescription) }
        return (statusCode, responseData)
    }

    private static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

enum OpenRouterAccountStatusError: LocalizedError {
    case api(String)
    case timeout
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .api(let message): "OpenRouter: \(message)"
        case .timeout: "OpenRouter account check timed out."
        case .transport(let message): "OpenRouter account check failed: \(message)"
        }
    }
}
