import AVFoundation
import Foundation
import os.log

private let transcriptionLog = OSLog(subsystem: BuildInfo.defaultBundleIdentifier, category: "Transcription")

enum TranscriptionModel: String, CaseIterable, Identifiable, Codable {
    case whisperLargeV3 = "whisper-large-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperLargeV3:
            return "Whisper Large V3"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        }
    }

    var settingsDescription: String {
        switch self {
        case .whisperLargeV3:
            return "Best for accuracy. Slightly slower and more expensive."
        case .whisperLargeV3Turbo:
            return "Best for speed and cost. Slightly less accurate."
        }
    }
}

class TranscriptionService {
    private let apiKey: String
    private let baseURL: String
    private let forceHTTP2: Bool
    private let transcriptionModel: TranscriptionModel
    private let transcriptionTimeoutSeconds: TimeInterval = 20
    private let uploadSampleRate = 16_000.0
    private let uploadChannelCount: AVAudioChannelCount = 1

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        transcriptionModel: TranscriptionModel = .whisperLargeV3,
        forceHTTP2: Bool = false
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transcriptionModel = transcriptionModel
        self.forceHTTP2 = forceHTTP2
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw TranscriptionError.submissionFailed("Service deallocated")
                }
                return try await self.transcribeAudio(fileURL: fileURL)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.transcriptionTimeoutSeconds * 1_000_000_000))
                throw TranscriptionError.transcriptionTimedOut(self.transcriptionTimeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw TranscriptionError.submissionFailed("No transcription result")
            }
            group.cancelAll()
            return result
        }
    }

    // Send audio file for transcription and return text
    private func transcribeAudio(fileURL: URL) async throws -> String {
        if forceHTTP2 {
            return try await transcribeAudioWithCurl(fileURL: fileURL)
        }
        return try await transcribeAudioWithURLSession(fileURL: fileURL)
    }

    private func transcribeAudioWithURLSession(fileURL: URL) async throws -> String {
        let preparedAudio = try prepareAudioForUpload(from: fileURL)
        defer { preparedAudio.cleanup() }

        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: preparedAudio.fileURL)
        let body = makeMultipartBody(
            audioData: audioData,
            fileName: preparedAudio.fileURL.lastPathComponent,
            model: transcriptionModel.rawValue,
            boundary: boundary
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            let nsError = error as NSError
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload failed for %{public}@ (transport=%{public}@, bytes=%{public}lld): domain=%{public}@ code=%ld desc=%{public}@",
                fileURL.lastPathComponent,
                "urlsession-default",
                fileSizeBytes(for: fileURL),
                nsError.domain,
                nsError.code,
                error.localizedDescription
            )
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload returned HTTP %ld for %{public}@ (transport=%{public}@, bytes=%{public}lld)",
                httpResponse.statusCode,
                fileURL.lastPathComponent,
                "urlsession-default",
                fileSizeBytes(for: fileURL)
            )
            throw TranscriptionError.submissionFailed("Status \(httpResponse.statusCode): \(responseBody)")
        }

        return try parseTranscript(from: data)
    }

    private func transcribeAudioWithCurl(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [apiKey, transcriptionModel] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent",
                "--show-error",
                "--fail",
                "--http2",
                "--max-time", String(Int(self.transcriptionTimeoutSeconds)),
                "\(self.baseURL)/audio/transcriptions",
                "-H", "Authorization: Bearer \(apiKey)",
                "-F", "model=\(transcriptionModel.rawValue)",
                "-F", "file=@\(fileURL.path);type=\(self.audioContentType(for: fileURL.lastPathComponent))"
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
                os_log(
                    .error,
                    log: transcriptionLog,
                    "curl upload failed for %{public}@ (transport=%{public}@, bytes=%{public}lld): exit=%d%{public}@",
                    fileURL.lastPathComponent,
                    "http2-curl",
                    self.fileSizeBytes(for: fileURL),
                    process.terminationStatus,
                    errorText.isEmpty ? "" : " stderr=\(errorText)"
                )
                throw TranscriptionError.submissionFailed(
                    "curl transport failed with exit \(process.terminationStatus): \(errorText)"
                )
            }

            return try self.parseTranscript(from: outputData)
        }.value
    }

    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/mp4"
    }

    private func fileSizeBytes(for fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func makeMultipartBody(audioData: Data, fileName: String, model: String, boundary: String) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioContentType(for: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    private func prepareAudioForUpload(from fileURL: URL) throws -> PreparedUploadAudio {
        let inputFile = try AVAudioFile(forReading: fileURL)
        if isPreferredUploadFormat(file: inputFile, fileURL: fileURL) {
            return PreparedUploadAudio(fileURL: fileURL, deleteOnCleanup: false)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try normalizeAudioForUpload(inputFile: inputFile, outputURL: outputURL)
        return PreparedUploadAudio(fileURL: outputURL, deleteOnCleanup: true)
    }

    private func isPreferredUploadFormat(file: AVAudioFile, fileURL: URL) -> Bool {
        let format = file.fileFormat
        return fileURL.pathExtension.lowercased() == "wav"
            && abs(format.sampleRate - uploadSampleRate) < 0.5
            && format.channelCount == uploadChannelCount
            && format.commonFormat == .pcmFormatInt16
    }

    private func normalizeAudioForUpload(inputFile: AVAudioFile, outputURL: URL) throws {
        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: uploadSampleRate,
            channels: uploadChannelCount,
            interleaved: false
        ) else {
            throw TranscriptionError.audioPreparationFailed("Could not create normalized output format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionError.audioPreparationFailed("Could not create audio converter")
        }

        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: uploadSampleRate,
            AVNumberOfChannelsKey: Int(uploadChannelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )

        let inputFrameCapacity: AVAudioFrameCount = 4096
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputFrameCapacity) * outputFormat.sampleRate / inputFormat.sampleRate)
        ) + 32

        var reachedEndOfInput = false
        var readError: Error?
        var conversionError: NSError?

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputFrameCapacity
            ) else {
                throw TranscriptionError.audioPreparationFailed("Could not allocate normalized audio buffer")
            }

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEndOfInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = inputFile.length - inputFile.framePosition
                guard remainingFrames > 0 else {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let framesToRead = AVAudioFrameCount(min(Int64(inputFrameCapacity), remainingFrames))
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: framesToRead
                ) else {
                    readError = TranscriptionError.audioPreparationFailed("Could not allocate source audio buffer")
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try inputFile.read(into: inputBuffer, frameCount: framesToRead)
                } catch {
                    readError = error
                    outStatus.pointee = .noDataNow
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let readError {
                throw TranscriptionError.audioPreparationFailed(readError.localizedDescription)
            }
            if let conversionError {
                throw TranscriptionError.audioPreparationFailed(conversionError.localizedDescription)
            }

            switch status {
            case .haveData:
                try outputFile.write(from: outputBuffer)
            case .inputRanDry:
                continue
            case .endOfStream:
                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                }
                return
            case .error:
                throw TranscriptionError.audioPreparationFailed("Audio conversion failed")
            @unknown default:
                throw TranscriptionError.audioPreparationFailed("Unknown audio conversion status")
            }
        }
    }

    private func parseTranscript(from data: Data) throws -> String {
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.pollFailed("Invalid response")
        }

        return text
    }
}

enum TranscriptionError: LocalizedError {
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        case .audioPreparationFailed(let msg): return "Audio preparation failed: \(msg)"
        }
    }
}

private struct PreparedUploadAudio {
    let fileURL: URL
    let deleteOnCleanup: Bool

    func cleanup() {
        guard deleteOnCleanup else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
