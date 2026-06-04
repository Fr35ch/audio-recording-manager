// RTFExporter.swift
// Clio
//
// Produces a Word-compatible RTF document for an anonymized transcript.
// RTF is native to Foundation via `NSAttributedString.data(from:
// documentAttributes:)` — no external dependencies, no Python helper,
// and Word opens RTF identically to DOCX for the formatting we use
// here (heading, subtitle, italic stats line, paragraphs).
//
// Two layers:
//   - `buildRTF(document:)` is a pure function returning `Data`.
//     Unit-testable in isolation.
//   - `save(document:defaultFilename:)` orchestrates `NSSavePanel`
//     on the main actor and writes the result to disk on confirm.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum RTFExporter {

    /// Inputs the exporter needs to build the document.
    struct Document {
        /// Top heading — typically the recording's display name.
        var title: String
        /// Optional second line under the heading (e.g.
        /// "Avidentifisert · 12. mai 2026").
        var subtitle: String?
        /// Optional italic line summarising redaction counts.
        var statsLine: String?
        /// The anonymized transcript text, exactly as it sits on disk.
        /// Paragraph breaks (`\n\n`) become RTF paragraph breaks; single
        /// newlines are coerced to spaces so Word doesn't render the
        /// body as a jagged poem.
        var body: String
    }

    // MARK: - Pure: build RTF

    static func buildRTF(document: Document) throws -> Data {
        let attr = NSMutableAttributedString()

        // Title
        attr.append(NSAttributedString(
            string: document.title + "\n",
            attributes: titleAttrs
        ))

        if let subtitle = document.subtitle, !subtitle.isEmpty {
            attr.append(NSAttributedString(
                string: subtitle + "\n",
                attributes: subtitleAttrs
            ))
        }

        if let statsLine = document.statsLine, !statsLine.isEmpty {
            attr.append(NSAttributedString(
                string: statsLine + "\n",
                attributes: statsAttrs
            ))
        }

        // Compliance reminder. Norwegian — the researcher's audience
        // (study leads, qualitative analysts) reads in Norwegian.
        attr.append(NSAttributedString(
            string: complianceText + "\n",
            attributes: complianceAttrs
        ))

        // Body paragraphs. Split on blank lines so each turn becomes
        // its own paragraph; coalesce single line breaks within a
        // paragraph to spaces.
        let paragraphs = document.body
            .components(separatedBy: "\n\n")
            .map { para -> String in
                para
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs {
            attr.append(NSAttributedString(
                string: paragraph + "\n",
                attributes: bodyAttrs
            ))
        }

        return try attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf,
            ]
        )
    }

    // MARK: - Side-effectful: NSSavePanel

    /// Presents a native save panel and writes the RTF on confirm.
    /// Returns the chosen URL on success, nil if the user cancelled
    /// or the write failed.
    @MainActor
    static func save(document: Document, defaultFilename: String) -> URL? {
        let data: Data
        do {
            data = try buildRTF(document: document)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = defaultFilename
        panel.canCreateDirectories = true
        panel.title = "Eksporter avidentifisert transkripsjon"
        panel.message =
            "Velg hvor du vil lagre RTF-filen. Bruk OneDrive- eller Teams-mappen din om filen skal deles med studieleder."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    // MARK: - Filename hygiene

    /// Strips characters that are invalid or awkward in macOS file
    /// names so a recording titled `"intervju #3 / Anne"` produces
    /// `"intervju_3_Anne_avidentifisert.rtf"`, not garbage.
    static func sanitisedFilename(from rawTitle: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let stripped = rawTitle.components(separatedBy: invalid).joined()
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return collapsed.isEmpty ? "avidentifisert" : collapsed
    }

    // MARK: - Style tokens

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .paragraphStyle: paragraph(spacingAfter: 6),
    ]

    private static let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph(spacingAfter: 4),
    ]

    private static let statsAttrs: [NSAttributedString.Key: Any] = {
        let italic = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 12),
            toHaveTrait: .italicFontMask
        )
        return [
            .font: italic,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph(spacingAfter: 12),
        ]
    }()

    private static let complianceAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .paragraphStyle: paragraph(spacingAfter: 16),
    ]

    private static let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .paragraphStyle: paragraph(spacingAfter: 8, lineHeightMultiple: 1.25),
    ]

    private static let complianceText = """
    Denne teksten er klargjort for sikker deling i Teams/SharePoint. Lydopptaket og originaltranskripsjonen er ikke inkludert.
    """

    private static func paragraph(
        spacingAfter: CGFloat = 0,
        lineHeightMultiple: CGFloat = 1.0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }
}
