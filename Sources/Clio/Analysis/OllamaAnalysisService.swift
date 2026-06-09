// OllamaAnalysisService.swift
// Clio
//
// Direct HTTP analysis path: takes a fully-rendered prompt + model, calls
// Ollama at `localhost:11434/api/generate` in streaming mode, and parses
// the accumulated response into an `AnalysisResult`. Bypasses `navt.py`
// for analysis — the prompt now lives in ARM (see `PromptTemplateLibrary`).
//
// Streaming mode is used (stream: true) so that Ollama sends one JSON line
// per token. This keeps the connection alive throughout inference, avoiding
// the URLRequest per-packet timeout that fired when large transcripts took
// more than 10 minutes in non-streaming mode.
//
// The diarization + transcription pipeline continues to use `navt.py`;
// only the analyze step has been brought in-process.

import Foundation

// MARK: - Errors

enum OllamaAnalysisError: LocalizedError {
    case notInstalled
    case failedToStart
    case httpFailure(status: Int, body: String)
    case decodeFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama er ikke installert. Last ned fra ollama.com og prøv igjen."
        case .failedToStart:
            return "Ollama startet ikke innen tidsfristen. Start Ollama manuelt og prøv igjen."
        case .httpFailure(let status, let body):
            return "Ollama svarte HTTP \(status): \(body.prefix(300))"
        case .decodeFailure(let msg):
            return "Kunne ikke tolke svaret fra Ollama: \(msg)"
        case .cancelled:
            return "Analysen ble avbrutt."
        }
    }
}

// MARK: - HTTP wire types

/// Ollama `/api/generate` request payload.
private struct GenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    /// Disables Qwen3's extended thinking chain (`<think>…</think>`).
    /// Ollama ≥ 0.6 honours this for thinking-capable models; other models
    /// ignore it. Setting it to false for all models is safe.
    let think: Bool
}

/// One streaming chunk from Ollama `/api/generate` (stream: true).
/// Each line is a separate JSON object; `done` is true on the final line.
private struct StreamChunk: Decodable {
    let response: String
    let done: Bool
}

// MARK: - Service

final class OllamaAnalysisService {

    static let shared = OllamaAnalysisService()
    private init() {}

    /// Run an analysis end-to-end: ensure Ollama is up, POST the prompt via
    /// streaming, accumulate tokens, then parse the markdown into an
    /// `AnalysisResult`. The `onProgress` closure is called on every chunk
    /// with the running token count so callers can update their UI.
    func analyse(
        prompt: String,
        model: String,
        onProgress: @Sendable @escaping (Int) -> Void = { _ in }
    ) async throws -> AnalysisResult {
        guard OllamaManager.shared.isInstalled else {
            throw OllamaAnalysisError.notInstalled
        }
        if !OllamaManager.shared.isRunning() {
            OllamaManager.shared.startServer()
            if !OllamaManager.shared.waitUntilReady(timeout: 20) {
                throw OllamaAnalysisError.failedToStart
            }
        }

        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No timeoutInterval override — streaming keeps the connection alive
        // through the entire inference, so the default per-packet timeout
        // (which only fires on *silence*) is never hit.
        let body = GenerateRequest(model: model, prompt: prompt, stream: true, think: false)
        request.httpBody = try JSONEncoder().encode(body)

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            if Task.isCancelled { throw OllamaAnalysisError.cancelled }
            throw OllamaAnalysisError.decodeFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaAnalysisError.decodeFailure("Manglet HTTP-respons")
        }
        guard http.statusCode == 200 else {
            // Drain what we can for the error body.
            var errData = Data()
            for try await byte in asyncBytes { errData.append(byte) }
            let bodyStr = String(data: errData, encoding: .utf8) ?? "(uleselig)"
            throw OllamaAnalysisError.httpFailure(status: http.statusCode, body: bodyStr)
        }

        var accumulated = ""
        var tokenCount = 0
        let decoder = JSONDecoder()

        for try await line in asyncBytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            let chunk: StreamChunk
            do {
                chunk = try decoder.decode(StreamChunk.self, from: lineData)
            } catch {
                throw OllamaAnalysisError.decodeFailure("Ugyldig chunk: \(error.localizedDescription)")
            }
            accumulated += chunk.response
            tokenCount += 1
            onProgress(tokenCount)
            if chunk.done { break }
        }

        if accumulated.isEmpty {
            throw OllamaAnalysisError.decodeFailure("Tomt svar fra Ollama.")
        }

        // Safety net: strip any Qwen3 thinking chain the model emitted
        // despite `think: false`. The chain is wrapped in <think>…</think>
        // and must be removed before the section parser runs.
        let cleaned = stripThinkingBlock(accumulated)

        return AnalysisResultParser.parse(markdown: cleaned, model: model)
    }

    /// Removes a leading `<think>…</think>` block (Qwen3 extended thinking)
    /// from the raw LLM response. Case-insensitive, handles multi-line blocks.
    private func stripThinkingBlock(_ text: String) -> String {
        var result = text
        let open = "<think>"
        let close = "</think>"
        let ciOptions: String.CompareOptions = [.caseInsensitive]
        while let openRange = result.range(of: open, options: ciOptions),
              let closeRange = result.range(of: close, options: ciOptions,
                                            range: openRange.upperBound..<result.endIndex)
        {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
