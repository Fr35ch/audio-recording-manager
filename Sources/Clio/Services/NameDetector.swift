// NameDetector.swift
// Clio
//
// Lightweight name detection using SSB (Statistics Norway) name lists.
// Bundled from no-anonymizer/data/ssb_fornavn.txt and ssb_etternavn.txt.
// Used to warn researchers when a recording filename may contain a personal name.

import Foundation

final class NameDetector {
    static let shared = NameDetector()

    private let names: Set<String>

    private init() {
        var combined = Set<String>()
        for resource in ["ssb_fornavn", "ssb_etternavn"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                combined.insert(trimmed.lowercased())
            }
        }
        names = combined
    }

    /// Returns true if any token in `text` matches a known Norwegian name.
    /// Tokens are split on spaces, hyphens, and underscores.
    func containsName(in text: String) -> Bool {
        let tokens = text
            .components(separatedBy: CharacterSet(charactersIn: " -_"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }
        return tokens.contains { names.contains($0) }
    }
}
