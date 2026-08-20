import CoreML
import Foundation

/// BERT-based NER detection of persons, organisations, and locations.
///
/// Based on `no_anonymizer/layers/bert_ner.py`, using the CoreML conversion
/// of `NbAiLab/nb-bert-base-ner` (see `packaging/convert_bert_ner.py`)
/// instead of a Python/transformers subprocess. Runs fully in-process via
/// CoreML/ANE — no child executable, no sandbox entitlement conflict.
///
/// Entity label mapping:
///     PER, GPE_ORG  → [NAVN] / counted... see below
///     LOC, GPE_LOC  → [STED]
///     ORG           → counted only (not replaced — legal entity, not personal data)
///     everything else (PROD, MISC, EVT, DRV) → ignored
///
/// ⚠️ Deliberate deviation from the upstream Python `_LABEL_MAP`, which only
/// matches the bare literal strings `"PER"`/`"LOC"`/`"GPE"`. The real
/// model's label set (confirmed via `id2label` in the converted model and a
/// real inference test — "Bergen" → `B-GPE_LOC`) never emits a bare `"GPE"`,
/// only the compound tags `GPE_LOC`/`GPE_ORG`. That means the upstream
/// Python code — and a byte-for-byte faithful port of it — silently never
/// redacts real place names (confirmed with a live test: "Bergen" is
/// tagged `GPE_LOC` and would pass through unredacted). Since this is a
/// compliance-sensitive de-identification tool for personal data, this port
/// intentionally maps `GPE_LOC` alongside `LOC` → `[STED]`, closing the gap.
/// `GPE_ORG` (geopolitical entities acting as organizations, e.g. country
/// names) is treated like `ORG` — counted, not redacted, matching the
/// existing "organisations are legal entities, not personal data" rationale.
/// `StederDetector` (place-name gazetteer) remains a separate, independent
/// safety net regardless.
enum BertNERDetector {
    private static let maxTokensPerChunk = 480
    private static let modelInputCeiling = 512

    private static let labelMap: [String: (category: String, replacement: String)] = [
        "PER": ("NAVN", "[NAVN]"),
        "LOC": ("STED", "[STED]"),
        "GPE_LOC": ("STED", "[STED]"),
    ]

    // Treated like ORG: counted for audit purposes, never redacted.
    private static let countOnlyGroups: Set<String> = ["ORG", "GPE_ORG"]

    private static let id2label: [Int: String] = [
        0: "O", 1: "B-PER", 2: "I-PER", 3: "B-ORG", 4: "I-ORG",
        5: "B-GPE_LOC", 6: "I-GPE_LOC", 7: "B-PROD", 8: "I-PROD",
        9: "B-LOC", 10: "I-LOC", 11: "B-GPE_ORG", 12: "I-GPE_ORG",
        13: "B-DRV", 14: "I-DRV", 15: "B-EVT", 16: "I-EVT",
        17: "B-MISC", 18: "I-MISC",
    ]

    private static let tokenizer: BertWordPieceTokenizer? = {
        guard let url = Bundle.main.url(forResource: "vocab", withExtension: "txt", subdirectory: "NBBertNER-tokenizer")
            ?? Bundle.main.url(forResource: "vocab", withExtension: "txt")
        else { return nil }
        return BertWordPieceTokenizer(vocabURL: url)
    }()

    private static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "NBBertNER", withExtension: "mlmodelc") else { return nil }
        return try? MLModel(contentsOf: url)
    }()

    /// True once both the tokenizer and CoreML model have loaded successfully.
    static var isAvailable: Bool { tokenizer != nil && model != nil }

    // MARK: - Chunking (mirrors bert_ner.py's _chunk_text / _force_split)

    private static func chunkText(_ text: String, maxTokens: Int, tokenizer: BertWordPieceTokenizer) -> [(offset: Int, chunk: String)] {
        if tokenizer.countSubwordTokens(text) <= maxTokens {
            return [(0, text)]
        }

        let ns = text as NSString
        var boundaries = [0]
        let fullRange = NSRange(location: 0, length: ns.length)
        for match in TextContext.sentenceBoundaryRegex.matches(in: text, options: [], range: fullRange) {
            boundaries.append(match.range.location + match.range.length)
        }
        if boundaries.last != ns.length {
            boundaries.append(ns.length)
        }

        var chunks: [(Int, String)] = []
        var chunkStart = 0
        var i = 1
        while i < boundaries.count {
            let candidateEnd = boundaries[i]
            let candidate = ns.substring(with: NSRange(location: chunkStart, length: candidateEnd - chunkStart))
            if tokenizer.countSubwordTokens(candidate) <= maxTokens {
                i += 1
                continue
            }
            let prevEnd = boundaries[i - 1]
            if prevEnd > chunkStart {
                chunks.append((chunkStart, ns.substring(with: NSRange(location: chunkStart, length: prevEnd - chunkStart))))
                chunkStart = prevEnd
                continue  // re-evaluate same boundary against new chunkStart
            }
            // Single sentence itself too large — force-split at whitespace.
            chunks.append(contentsOf: forceSplit(ns, start: chunkStart, end: candidateEnd, maxTokens: maxTokens, tokenizer: tokenizer))
            chunkStart = candidateEnd
            i += 1
        }
        if chunkStart < ns.length {
            chunks.append((chunkStart, ns.substring(with: NSRange(location: chunkStart, length: ns.length - chunkStart))))
        }
        return chunks
    }

    private static func forceSplit(_ ns: NSString, start: Int, end: Int, maxTokens: Int, tokenizer: BertWordPieceTokenizer) -> [(Int, String)] {
        var pieces: [(Int, String)] = []
        var pos = start
        while pos < end {
            var lo = pos + 1, hi = end
            var best = pos + 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let candidate = ns.substring(with: NSRange(location: pos, length: mid - pos))
                if tokenizer.countSubwordTokens(candidate) <= maxTokens {
                    best = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            if best < end {
                let searchRange = NSRange(location: pos + 1, length: best - pos)
                let ws = ns.range(of: " ", options: .backwards, range: searchRange)
                if ws.location != NSNotFound && ws.location > pos {
                    best = ws.location
                }
            }
            pieces.append((pos, ns.substring(with: NSRange(location: pos, length: best - pos))))
            pos = best
            while pos < end {
                guard let scalar = Unicode.Scalar(ns.character(at: pos)), CharacterSet.whitespaces.contains(scalar) else { break }
                pos += 1
            }
        }
        return pieces
    }

    // MARK: - Inference

    /// Return NER-detected spans and the count of ORG entities found.
    ///
    /// ORG entities are counted for audit purposes but not replaced with a
    /// token — organisations are legal entities, not personal data under GDPR.
    static func detect(_ text: String) -> (spans: [PIISpan], orgCount: Int) {
        guard let tokenizer = tokenizer, let model = model else {
            return ([], 0)
        }

        var spans: [PIISpan] = []
        var orgCount = 0

        for (offset, chunk) in chunkText(text, maxTokens: maxTokensPerChunk, tokenizer: tokenizer) {
            let (chunkSpans, chunkOrgCount) = runInference(chunk, offset: offset, tokenizer: tokenizer, model: model)
            spans.append(contentsOf: chunkSpans)
            orgCount += chunkOrgCount
        }

        return (spans, orgCount)
    }

    private static func runInference(
        _ chunk: String, offset: Int, tokenizer: BertWordPieceTokenizer, model: MLModel
    ) -> (spans: [PIISpan], orgCount: Int) {
        let tokens = tokenizer.tokenize(chunk, maxTokens: modelInputCeiling)
        let n = tokens.count
        guard n > 0,
            let inputIds = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32),
            let attentionMask = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32),
            let tokenTypeIds = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        else {
            return ([], 0)
        }

        for i in 0..<n {
            inputIds[i] = NSNumber(value: tokens[i].id)
            attentionMask[i] = 1
            tokenTypeIds[i] = 0
        }

        guard
            let provider = try? MLDictionaryFeatureProvider(dictionary: [
                "input_ids": inputIds, "attention_mask": attentionMask, "token_type_ids": tokenTypeIds,
            ]),
            let output = try? model.prediction(from: provider),
            let logits = output.featureValue(for: "logits")?.multiArrayValue
        else {
            return ([], 0)
        }

        let numLabels = logits.shape[2].intValue
        var predictions: [(label: String, score: Double)] = []
        predictions.reserveCapacity(n)

        for i in 0..<n {
            var best = 0
            var bestLogit = -Double.infinity
            var sumExp = 0.0
            var logitVals = [Double](repeating: 0, count: numLabels)
            for c in 0..<numLabels {
                let v = logits[[0, NSNumber(value: i), NSNumber(value: c)]].doubleValue
                logitVals[c] = v
                if v > bestLogit { bestLogit = v; best = c }
            }
            for v in logitVals { sumExp += exp(v - bestLogit) }
            let score = 1.0 / sumExp  // softmax probability of the argmax class
            predictions.append((id2label[best] ?? "O", score))
        }

        return aggregate(tokens: tokens, predictions: predictions, offset: offset)
    }

    /// Aggregates consecutive same-type B-/I- token predictions into entity
    /// groups (HF `aggregation_strategy="simple"` equivalent), then applies
    /// the exact `_LABEL_MAP` used by the Python original.
    private static func aggregate(
        tokens: [BertToken], predictions: [(label: String, score: Double)], offset: Int
    ) -> (spans: [PIISpan], orgCount: Int) {
        var spans: [PIISpan] = []
        var orgCount = 0

        var groupName: String?
        var groupStart: Int?
        var groupEnd: Int?
        var groupScores: [Double] = []

        func closeGroup() {
            defer { groupName = nil; groupStart = nil; groupEnd = nil; groupScores = [] }
            guard let name = groupName, let start = groupStart, let end = groupEnd, end > start else { return }
            if countOnlyGroups.contains(name) {
                orgCount += 1
                return
            }
            guard let mapping = labelMap[name] else { return }
            let avgScore = groupScores.reduce(0, +) / Double(max(1, groupScores.count))
            spans.append(PIISpan(position: offset + start, length: end - start,
                                  category: mapping.category, replacement: mapping.replacement, score: avgScore))
        }

        for (i, token) in tokens.enumerated() {
            guard let start = token.start, let end = token.end else { continue }  // skip [CLS]/[SEP]
            let (label, score) = predictions[i]

            if label == "O" {
                closeGroup()
                continue
            }
            let isBeginning = label.hasPrefix("B-")
            let thisGroupName = String(label.dropFirst(2))  // strip "B-"/"I-"

            if groupName == nil || isBeginning || thisGroupName != groupName {
                closeGroup()
                groupName = thisGroupName
                groupStart = start
                groupEnd = end
                groupScores = [score]
            } else {
                groupEnd = end
                groupScores.append(score)
            }
        }
        closeGroup()

        return (spans, orgCount)
    }
}
