import Foundation
import ApplicationServices
import AppKit
import os.log

private let contextLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Context")

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextPrompt: String?
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?

    var contextSummary: String {
        currentActivity
    }
}

final class AppContextService {
    static let defaultContextPrompt = """
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata and an optional screenshot, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
"""
    static let defaultContextPromptDate = "2026-02-24"

    private let apiKey: String
    private let baseURL: String
    private let customContextPrompt: String
    private let forceHTTP2: Bool
    private let fallbackTextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let visionModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let contextRequestTimeoutSeconds: TimeInterval = 10
    private let serverErrorRetryCount = 1
    private let serverErrorRetryDelayNanoseconds: UInt64 = 250_000_000
    private let maxScreenshotDataURILength = 500_000
    private let screenshotCompressionPrimary = 0.5
    private let screenshotMaxDimension: CGFloat = 1024

    private func elapsedMilliseconds(since startTime: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        customContextPrompt: String = "",
        forceHTTP2: Bool = false
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.customContextPrompt = customContextPrompt
        self.forceHTTP2 = forceHTTP2
    }

    func collectContext() async -> AppContext {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: "You are dictating in an unrecognized context.",
                contextPrompt: nil,
                screenshotDataURL: nil,
                screenshotMimeType: nil,
                screenshotError: "No frontmost application"
            )
        }

        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        let metadataT0 = CFAbsoluteTimeGetCurrent()
        let windowTitleT0 = CFAbsoluteTimeGetCurrent()
        let windowTitle = focusedWindowTitle(from: appElement) ?? appName
        os_log(.info, log: contextLog, "collectContext(): window title resolved in %.3fms", elapsedMilliseconds(since: windowTitleT0))
        let selectedTextT0 = CFAbsoluteTimeGetCurrent()
        let selectedText = selectedText(from: appElement)
        os_log(.info, log: contextLog, "collectContext(): selected text resolved in %.3fms", elapsedMilliseconds(since: selectedTextT0))
        os_log(.info, log: contextLog, "collectContext(): metadata resolved in %.3fms", elapsedMilliseconds(since: metadataT0))

        let screenshotT0 = CFAbsoluteTimeGetCurrent()
        let screenshot = captureActiveWindowScreenshot(
            processIdentifier: frontmostApp.processIdentifier,
            appElement: appElement,
            focusedWindowTitle: windowTitle
        )
        os_log(
            .info,
            log: contextLog,
            "collectContext(): screenshot resolved in %.3fms (available=%{public}d bytes=%{public}d error=%{public}@)",
            elapsedMilliseconds(since: screenshotT0),
            screenshot.dataURL != nil,
            screenshot.dataURL?.utf8.count ?? 0,
            screenshot.error ?? "none"
        )
        let currentActivity: String
        let contextPrompt: String?
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inferenceT0 = CFAbsoluteTimeGetCurrent()
            if let result = await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshot.dataURL
            ) {
                os_log(.info, log: contextLog, "collectContext(): llm inference succeeded in %.3fms", (CFAbsoluteTimeGetCurrent() - inferenceT0) * 1000)
                currentActivity = result.activity
                contextPrompt = result.prompt
            } else {
                os_log(.info, log: contextLog, "collectContext(): llm inference failed in %.3fms, using fallback", (CFAbsoluteTimeGetCurrent() - inferenceT0) * 1000)
                currentActivity = fallbackCurrentActivity(
                    appName: appName,
                    bundleIdentifier: bundleIdentifier,
                    selectedText: selectedText,
                    windowTitle: windowTitle,
                    screenshotAvailable: screenshot.dataURL != nil
                )
                contextPrompt = nil
            }
        } else {
            currentActivity = fallbackCurrentActivity(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                selectedText: selectedText,
                windowTitle: windowTitle,
                screenshotAvailable: screenshot.dataURL != nil
            )
            contextPrompt = nil
        }

        os_log(.info, log: contextLog, "collectContext(): finished in %.3fms", elapsedMilliseconds(since: t0))

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            currentActivity: currentActivity,
            contextPrompt: contextPrompt,
            screenshotDataURL: screenshot.dataURL,
            screenshotMimeType: screenshot.mimeType,
            screenshotError: screenshot.error
        )
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?
    ) async -> (activity: String, prompt: String)? {
        let modelsToTry = [
            screenshotDataURL != nil ? visionModel : fallbackTextModel,
            fallbackTextModel
        ]

        for model in modelsToTry {
            let screenshotPayload = model == visionModel ? screenshotDataURL : nil
            os_log(.info, log: contextLog, "inferActivityWithLLM(): trying model=%{public}@ screenshot=%{public}d", model, screenshotPayload != nil)
            if let inferred = await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshotPayload,
                model: model
            ) {
                return inferred
            }
        }

        return nil
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?,
        model: String
    ) async -> (activity: String, prompt: String)? {
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let requestBuildT0 = CFAbsoluteTimeGetCurrent()
            var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = contextRequestTimeoutSeconds

            let metadata = """
App: \(appName ?? "Unknown")
Bundle ID: \(bundleIdentifier ?? "Unknown")
Window: \(windowTitle ?? "Unknown")
Selected text: \(selectedText ?? "None")
"""

            let systemPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultContextPrompt
                : customContextPrompt

            let textOnlyPrompt = "Analyze the context and infer the user's current activity in exactly two sentences.\n\n\(metadata)"
            var userMessageDescription: String
            var userMessage: Any = textOnlyPrompt

            if let screenshotDataURL {
                userMessageDescription = "[screenshot attached]\nAnalyze the screenshot plus metadata to infer current activity.\n\(metadata)"
                userMessage = [
                    [
                        "type": "text",
                        "text": "Analyze the screenshot plus metadata to infer current activity."
                    ],
                    [
                        "type": "text",
                        "text": metadata
                    ],
                    [
                        "type": "image_url",
                        "image_url": ["url": screenshotDataURL]
                    ]
                ]
            } else {
                userMessageDescription = textOnlyPrompt
            }

            let fullPrompt = "Model: \(model)\n\n[System]\n\(systemPrompt)\n[User]\n\(userMessageDescription)"

            let payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            os_log(
                .info,
                log: contextLog,
                "inferActivityWithLLM(): request built in %.3fms for model=%{public}@ screenshot=%{public}d payloadBytes=%{public}d",
                elapsedMilliseconds(since: requestBuildT0),
                model,
                screenshotDataURL != nil,
                request.httpBody?.count ?? 0
            )
            let requestT0 = CFAbsoluteTimeGetCurrent()
            let result = try await performJSONRequestWithServerErrorRetry(
                request: request,
                timeout: contextRequestTimeoutSeconds,
                retryCount: serverErrorRetryCount,
                retryLabel: "inferActivityWithLLM()",
                model: model,
                screenshotAttached: screenshotDataURL != nil
            )
            os_log(
                .info,
                log: contextLog,
                "inferActivityWithLLM(): request finished in %.3fms for model=%{public}@ screenshot=%{public}d status=%ld responseBytes=%{public}d",
                elapsedMilliseconds(since: requestT0),
                model,
                screenshotDataURL != nil,
                result.statusCode,
                result.data.count
            )
            guard result.statusCode == 200 else {
                return nil
            }
            let decodeT0 = CFAbsoluteTimeGetCurrent()
            guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            os_log(.info, log: contextLog, "inferActivityWithLLM(): response decoded in %.3fms", elapsedMilliseconds(since: decodeT0))

            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            os_log(.info, log: contextLog, "inferActivityWithLLM(): finished in %.3fms total for model=%{public}@", elapsedMilliseconds(since: t0), model)
            return (activity: normalizedActivitySummary(cleaned), prompt: fullPrompt)
        } catch {
            return nil
        }
    }

    private func performJSONRequestWithServerErrorRetry(
        request: URLRequest,
        timeout: TimeInterval,
        retryCount: Int,
        retryLabel: StaticString,
        model: String,
        screenshotAttached: Bool
    ) async throws -> (data: Data, statusCode: Int) {
        var attempt = 0
        while true {
            attempt += 1
            let result = try forceHTTP2
                ? await performCurlJSONRequest(request: request, timeout: timeout)
                : await performURLSessionJSONRequest(request: request)

            if (500...599).contains(result.statusCode), attempt <= retryCount + 1 {
                if attempt <= retryCount {
                    os_log(
                        .error,
                        log: contextLog,
                        "%{public}s: retrying after HTTP %ld (attempt %d/%d) for model=%{public}@ screenshot=%{public}d",
                        retryLabel.utf8Start,
                        result.statusCode,
                        attempt + 1,
                        retryCount + 1,
                        model,
                        screenshotAttached
                    )
                    try? await Task.sleep(nanoseconds: serverErrorRetryDelayNanoseconds)
                    continue
                }
            }

            return result
        }
    }

    private func performURLSessionJSONRequest(request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        os_log(.info, log: contextLog, "performURLSessionJSONRequest(): finished in %.3fms status=%ld bytes=%{public}d", elapsedMilliseconds(since: t0), httpResponse.statusCode, data.count)
        return (data, httpResponse.statusCode)
    }

    private func performCurlJSONRequest(request: URLRequest, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        try await Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let tempDirectory = FileManager.default.temporaryDirectory
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".json")
            let outputURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".out")
            defer {
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.removeItem(at: outputURL)
            }

            try (request.httpBody ?? Data()).write(to: tempURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent",
                "--show-error",
                "--http2",
                "--max-time", String(Int(timeout)),
                "--output", outputURL.path,
                "--write-out", "%{http_code}",
                request.url!.absoluteString,
                "-H", "Authorization: Bearer \(self.apiKey)",
                "-H", "Content-Type: application/json",
                "--data-binary", "@\(tempURL.path)"
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let launchT0 = CFAbsoluteTimeGetCurrent()
            try process.run()
            process.waitUntilExit()
            os_log(.info, log: contextLog, "performCurlJSONRequest(): curl process finished in %.3fms", self.elapsedMilliseconds(since: launchT0))

            let statusData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let statusText = String(data: statusData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let statusCode = Int(statusText) ?? 0
            let outputData = (try? Data(contentsOf: outputURL)) ?? Data()

            guard process.terminationStatus == 0 else {
                os_log(.error, log: contextLog, "curl context request failed: exit=%d%{public}@", process.terminationStatus, errorText.isEmpty ? "" : " stderr=\(errorText)")
                throw URLError(.networkConnectionLost)
            }

            os_log(.info, log: contextLog, "performCurlJSONRequest(): finished in %.3fms status=%ld bytes=%{public}d", self.elapsedMilliseconds(since: t0), statusCode, outputData.count)
            return (outputData, statusCode)
        }.value
    }

    private func normalizedActivitySummary(_ value: String) -> String {
        let sentences = value
            .split(whereSeparator: { $0 == "." || $0 == "。" || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count <= 2 {
            return value
        }

        let firstTwo = sentences.prefix(2)
        return firstTwo.joined(separator: ". ") + "."
    }

    private func fallbackCurrentActivity(
        appName: String?,
        bundleIdentifier: String?,
        selectedText: String?,
        windowTitle: String?,
        screenshotAvailable: Bool
    ) -> String {
        let activeApp = appName ?? "the active application"
        if screenshotAvailable {
            return "Could not reliably infer a two-sentence summary for \(activeApp) from the screenshot and metadata."
        }
        return "Could not reliably infer a two-sentence summary for \(activeApp) from the visible metadata."
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        if let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) {
            return trimmedText(windowTitle)
        }

        return nil
    }

    private func selectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        if let selectedText = accessibilityString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        return nil
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return trimmedText(stringValue)
    }

    private func accessibilityPoint(from element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func accessibilitySize(from element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func captureActiveWindowScreenshot(
        processIdentifier: pid_t,
        appElement: AXUIElement,
        focusedWindowTitle: String?
    ) -> (dataURL: String?, mimeType: String?, error: String?) {
        let t0 = CFAbsoluteTimeGetCurrent()
        if !CGPreflightScreenCaptureAccess() {
            return (
                nil,
                nil,
                "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            )
        }

        let windowListT0 = CFAbsoluteTimeGetCurrent()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): window list fetched in %.3fms", elapsedMilliseconds(since: windowListT0))

        guard let windows else {
            return (nil, nil, "Unable to read window list")
        }

        let ownerPIDKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let onScreenKey = kCGWindowIsOnscreen as String
        let windowIDKey = kCGWindowNumber as String
        let boundsKey = kCGWindowBounds as String
        let nameKey = kCGWindowName as String

        struct CandidateWindow {
            let id: CGWindowID
            let layer: Int
            let area: Int
            let bounds: CGRect?
            let name: String?
        }

        let candidateBuildT0 = CFAbsoluteTimeGetCurrent()
        let candidateWindows = windows.compactMap { windowInfo -> CandidateWindow? in
            guard let ownerPID = windowInfo[ownerPIDKey] as? Int,
                  ownerPID == processIdentifier else {
                return nil
            }
            guard let isOnScreen = windowInfo[onScreenKey] as? Bool, isOnScreen else { return nil }
            guard let windowIDValue = windowInfo[windowIDKey] as? Int else { return nil }
            let layer = (windowInfo[layerKey] as? Int) ?? 0
            let bounds = boundsRect(windowInfo[boundsKey])
            let width = bounds?.width ?? 1
            let height = bounds?.height ?? 1
            let area = Int(width * height)
            let name = trimmedText(windowInfo[nameKey] as? String)

            return CandidateWindow(
                id: CGWindowID(windowIDValue),
                layer: layer,
                area: area,
                bounds: bounds,
                name: name
            )
        }
        os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): %d candidate windows built in %.3fms", candidateWindows.count, elapsedMilliseconds(since: candidateBuildT0))

        let focusedBoundsT0 = CFAbsoluteTimeGetCurrent()
        if let focusedWindowBounds = focusedWindowBounds(from: appElement), !focusedWindowBounds.isNull {
            os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): focused bounds resolved in %.3fms", elapsedMilliseconds(since: focusedBoundsT0))
            let overlapMatchT0 = CFAbsoluteTimeGetCurrent()
            if let activeWindow = candidateWindows
                .compactMap({ candidate -> (CandidateWindow, CGFloat)? in
                    guard let candidateBounds = candidate.bounds else { return nil }
                    let intersection = candidateBounds.intersection(focusedWindowBounds)
                    guard !intersection.isNull else { return nil }
                    let overlap = intersection.width * intersection.height
                    return (candidate, overlap)
                })
                .sorted(by: { lhs, rhs in
                    if lhs.0.layer == rhs.0.layer {
                        return lhs.1 > rhs.1
                    }
                    return lhs.0.layer < rhs.0.layer
                })
                    .first?.0 {
                os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): overlap match found in %.3fms", elapsedMilliseconds(since: overlapMatchT0))
                if let dataURL = captureWindowImage(
                    windowID: activeWindow.id,
                    fileType: .jpeg,
                    mimeType: "image/jpeg",
                    compression: screenshotCompressionPrimary,
                    maxDimension: screenshotMaxDimension
                ) {
                    os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): overlap window capture succeeded in %.3fms", elapsedMilliseconds(since: t0))
                    return (dataURL, "image/jpeg", nil)
                }
            }

            if let focusedWindowTitle {
                let titleMatchT0 = CFAbsoluteTimeGetCurrent()
                if let activeWindow = candidateWindows
                    .filter({ candidate in
                        let normalizedName = candidate.name?
                            .lowercased()
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedTarget = focusedWindowTitle
                            .lowercased()
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let normalizedName, !normalizedName.isEmpty,
                              !normalizedTarget.isEmpty else {
                            return false
                        }

                        return normalizedName == normalizedTarget || normalizedName.contains(normalizedTarget)
                    })
                    .sorted(by: { lhs, rhs in
                        if lhs.layer == rhs.layer {
                            return lhs.area > rhs.area
                        }
                        return lhs.layer < rhs.layer
                    })
                    .first {
                    os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): title match found in %.3fms", elapsedMilliseconds(since: titleMatchT0))
                    if let dataURL = captureWindowImage(
                        windowID: activeWindow.id,
                        fileType: .jpeg,
                        mimeType: "image/jpeg",
                        compression: screenshotCompressionPrimary,
                        maxDimension: screenshotMaxDimension
                    ) {
                        os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): title window capture succeeded in %.3fms", elapsedMilliseconds(since: t0))
                        return (dataURL, "image/jpeg", nil)
                    }
                }
            }
        } else {
            os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): focused bounds unavailable after %.3fms", elapsedMilliseconds(since: focusedBoundsT0))
        }

        let fullScreenCaptureT0 = CFAbsoluteTimeGetCurrent()
        guard let fullScreenImage = CGWindowListCreateImage(
            CGRect.infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return (nil, nil, "Could not capture screenshot (screen recording permission or window access issue)")
        }
        os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): full screen capture finished in %.3fms", elapsedMilliseconds(since: fullScreenCaptureT0))

        let cropEncodeT0 = CFAbsoluteTimeGetCurrent()
        if let croppedImage = croppedWhitespaceImage(from: fullScreenImage),
           let dataURL = convertImageToDataURL(
            croppedImage,
            mimeType: "image/jpeg",
            fileType: .jpeg,
            compression: screenshotCompressionPrimary,
            maxDimension: screenshotMaxDimension
        ) {
            os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): fullscreen crop+encode finished in %.3fms", elapsedMilliseconds(since: cropEncodeT0))
            os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): succeeded in %.3fms total", elapsedMilliseconds(since: t0))
            return (dataURL, "image/jpeg", nil)
        }

        os_log(.info, log: contextLog, "captureActiveWindowScreenshot(): failed in %.3fms total", elapsedMilliseconds(since: t0))
        return (nil, nil, "Could not capture screenshot within size limits")
    }

    private func captureWindowImage(
        windowID: CGWindowID,
        fileType: NSBitmapImageRep.FileType,
        mimeType: String,
        compression: Double? = nil,
        maxDimension: CGFloat? = nil
    ) -> String? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution]
        ) else {
            return nil
        }
        os_log(.info, log: contextLog, "captureWindowImage(): CGWindowListCreateImage finished in %.3fms for window=%u", elapsedMilliseconds(since: t0), windowID)

        let encodeT0 = CFAbsoluteTimeGetCurrent()
        if let dataURL = convertImageToDataURL(
            image,
            mimeType: mimeType,
            fileType: fileType,
            compression: compression,
            maxDimension: maxDimension
        ) {
            os_log(.info, log: contextLog, "captureWindowImage(): encode finished in %.3fms for window=%u bytes=%{public}d", elapsedMilliseconds(since: encodeT0), windowID, dataURL.utf8.count)
            os_log(.info, log: contextLog, "captureWindowImage(): succeeded in %.3fms total for window=%u", elapsedMilliseconds(since: t0), windowID)
            return dataURL
        }

        os_log(.info, log: contextLog, "captureWindowImage(): encode failed in %.3fms total for window=%u", elapsedMilliseconds(since: t0), windowID)
        return nil
    }

    private func boundsValue(_ value: Any?) -> CGSize? {
        guard let bounds = value as? [String: Any],
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func boundsRect(_ value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func focusedWindowBounds(from appElement: AXUIElement) -> CGRect? {
        guard let focusedWindow = accessibilityElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ),
              let point = accessibilityPoint(from: focusedWindow, attribute: kAXPositionAttribute as CFString),
              let size = accessibilitySize(from: focusedWindow, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func convertImageToDataURL(
        _ image: CGImage,
        mimeType: String,
        fileType: NSBitmapImageRep.FileType,
        compression: Double?,
        maxDimension: CGFloat?
    ) -> String? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let compressionSteps: [Double] = if let compression {
            [compression, compression * 0.5, compression * 0.25]
        } else {
            [1.0]
        }
        let dimensionSteps: [CGFloat?] = if let maxDimension {
            [maxDimension, maxDimension * 0.75, maxDimension * 0.5]
        } else {
            [nil]
        }

        for dim in dimensionSteps {
            let dimensionT0 = CFAbsoluteTimeGetCurrent()
            let imageToEncode = dim.flatMap { resizedImage(for: image, maxDimension: $0) } ?? image
            let rep = NSBitmapImageRep(cgImage: imageToEncode)

            for comp in compressionSteps {
                let encodeT0 = CFAbsoluteTimeGetCurrent()
                guard let imageData = rep.representation(
                    using: fileType,
                    properties: [.compressionFactor: comp]
                ) else { continue }

                let base64 = imageData.base64EncodedString()
                if base64.count <= maxScreenshotDataURILength {
                    os_log(.info, log: contextLog, "convertImageToDataURL(): succeeded in %.3fms total (dim=%{public}.0f comp=%.2f bytes=%{public}d, step=%.3fms)", elapsedMilliseconds(since: t0), dim ?? CGFloat(image.width), comp, base64.count, elapsedMilliseconds(since: encodeT0))
                    return "data:\(mimeType);base64,\(base64)"
                }
                os_log(.info, log: contextLog, "convertImageToDataURL(): rejected candidate in %.3fms (dim=%{public}.0f comp=%.2f bytes=%{public}d)", elapsedMilliseconds(since: encodeT0), dim ?? CGFloat(image.width), comp, base64.count)
            }
            os_log(.info, log: contextLog, "convertImageToDataURL(): dimension step finished in %.3fms", elapsedMilliseconds(since: dimensionT0))
        }

        os_log(.info, log: contextLog, "convertImageToDataURL(): failed in %.3fms total", elapsedMilliseconds(since: t0))
        return nil
    }

    private func croppedWhitespaceImage(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        var pixelData = Array(repeating: UInt8(0), count: byteCount)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        let drawRect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        context.draw(image, in: drawRect)

        let whiteThreshold: UInt8 = 245
        let alphaThreshold: UInt8 = 5
        var minX = width
        var minY = height
        var maxX: Int = -1
        var maxY: Int = -1
        var hasContent = false

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let offset = rowOffset + x * bytesPerPixel
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                let a = pixelData[offset + 3]

                if a <= alphaThreshold { continue }
                if r >= whiteThreshold && g >= whiteThreshold && b >= whiteThreshold {
                    continue
                }

                hasContent = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard hasContent else { return image }

        let cropRect = CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )

        return image.cropping(to: cropRect) ?? image
    }

    private func resizedImage(for image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        guard width > maxDimension || height > maxDimension else {
            return image
        }

        let scale = min(maxDimension / width, maxDimension / height, 1.0)
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage()
    }

    private func trimmedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }
}
