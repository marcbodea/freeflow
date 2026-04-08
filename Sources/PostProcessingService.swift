import Foundation
import os.log

private let postProcessingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "PostProcessing")

enum PostProcessingError: LocalizedError {
    case requestFailed(Int, String)
    case invalidResponse(String)
    case requestTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let details):
            "Post-processing failed with status \(statusCode): \(details)"
        case .invalidResponse(let details):
            "Invalid post-processing response: \(details)"
        case .requestTimedOut(let seconds):
            "Post-processing timed out after \(Int(seconds))s"
        }
    }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
}

final class PostProcessingService {
    static let defaultSystemPrompt = """
You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

Your job:
- Remove filler words (um, uh, you know, like) unless they carry meaning.
- Fix spelling, grammar, and punctuation errors.
- When the transcript already contains a word that is a close misspelling of a name or term from the context or custom vocabulary, correct the spelling. Never insert names or terms from context that the speaker did not say.
- Preserve the speaker's intent, tone, and meaning exactly.

Output rules:
- Return ONLY the cleaned transcript text, nothing else.
- If the transcription is empty, return exactly: EMPTY
- Do not add words, names, or content that are not in the transcription. The context is only for correcting spelling of words already spoken.
- Do not change the meaning of what was said.
"""
    static let defaultSystemPromptDate = "2026-02-24"

    private let apiKey: String
    private let baseURL: String
    private let forceHTTP2: Bool
    private let defaultModel = "openai/gpt-oss-20b"
    private let postProcessingTimeoutSeconds: TimeInterval = 10

    init(apiKey: String, baseURL: String = "https://api.groq.com/openai/v1", forceHTTP2: Bool = false) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.forceHTTP2 = forceHTTP2
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        customSystemPrompt: String = ""
    ) async throws -> PostProcessingResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: postProcessingLog, "postProcess() started")
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)

        let timeoutSeconds = postProcessingTimeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Post-processing service deallocated")
                }
                return try await self.process(
                    transcript: transcript,
                    contextSummary: context.contextSummary,
                    model: defaultModel,
                    customVocabulary: vocabularyTerms,
                    customSystemPrompt: customSystemPrompt
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No post-processing result")
                }
                group.cancelAll()
                os_log(.info, log: postProcessingLog, "postProcess() finished in %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func process(
        transcript: String,
        contextSummary: String,
        model: String,
        customVocabulary: [String],
        customSystemPrompt: String = ""
    ) async throws -> PostProcessingResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = postProcessingTimeoutSeconds

        let normalizedVocabulary = normalizedVocabularyText(customVocabulary)
        let vocabularyPrompt = if !normalizedVocabulary.isEmpty {
            """
The following vocabulary must be treated as high-priority terms while rewriting.
Use these spellings exactly in the output when relevant:
\(normalizedVocabulary)
"""
        } else {
            ""
        }

        var systemPrompt = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultSystemPrompt
            : customSystemPrompt
        if !vocabularyPrompt.isEmpty {
            systemPrompt += "\n\n" + vocabularyPrompt
        }

        let userMessage = """
Clean and format the following dictation for the destination app described in the context.

CONTEXT:
\(contextSummary)

CUSTOM VOCABULARY (spelling reference only):
\(normalizedVocabulary)

RAW TRANSCRIPT:
\(transcript)

Return only the final text. If the transcript is empty or contains only filler, return exactly: EMPTY
"""

        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let data: Data
        let response: URLResponse
        if forceHTTP2 {
            data = try await performCurlJSONRequest(request: request, timeout: postProcessingTimeoutSeconds)
            response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        os_log(.info, log: postProcessingLog, "chat/completions finished in %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        return PostProcessingResult(
            transcript: sanitizePostProcessedTranscript(content),
            prompt: promptForDisplay
        )
    }

    private func performCurlJSONRequest(request: URLRequest, timeout: TimeInterval) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            try (request.httpBody ?? Data()).write(to: tempURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent",
                "--show-error",
                "--fail",
                "--http2",
                "--max-time", String(Int(timeout)),
                request.url!.absoluteString,
                "-H", "Authorization: Bearer \(self.apiKey)",
                "-H", "Content-Type: application/json",
                "--data-binary", "@\(tempURL.path)"
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                os_log(.error, log: postProcessingLog, "curl post-processing request failed: exit=%d%{public}@", process.terminationStatus, errorText.isEmpty ? "" : " stderr=\(errorText)")
                throw URLError(.networkConnectionLost)
            }

            return outputData
        }.value
    }

    private func sanitizePostProcessedTranscript(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // Strip outer quotes if the LLM wrapped the entire response
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Treat the sentinel value as empty
        if result == "EMPTY" {
            return ""
        }

        return result
    }

    private func mergedVocabularyTerms(rawVocabulary: String) -> [String] {
        let terms = rawVocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private func normalizedVocabularyText(_ vocabularyTerms: [String]) -> String {
        let terms = vocabularyTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }
}
