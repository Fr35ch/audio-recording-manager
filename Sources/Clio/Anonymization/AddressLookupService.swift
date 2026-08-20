import Foundation

/// Kartverket address verification layer.
///
/// Direct port of `no_anonymizer/layers/address_lookup.py`. Takes
/// NER-detected STED spans and verifies them against Kartverket's official
/// address register (matrikkelen) via the Adresser API. Only candidates
/// that contain at least one digit (husnummer) are looked up — pure place
/// names are already handled by `StederDetector`/BERT NER.
///
/// API: GET https://ws.geonorge.no/adresser/v1/sok?sok={text}&treffPerSide=1
/// (no API key required).
///
/// Any network or parsing error is logged and the layer returns an empty
/// list with `networkAvailable = false` — it never throws.
enum AddressLookupService {
    private static let apiURL = "https://ws.geonorge.no/adresser/v1/sok"
    private static let timeout: TimeInterval = 3
    private static let addressCategories: Set<String> = ["STED"]

    /// Process-lifetime cache: normalized candidate text → is_address.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Synchronously queries the Kartverket API. Runs on a background queue
    /// via the caller (`NativeAnonymizer` already dispatches off the main
    /// thread), so a blocking network call here is acceptable — matches the
    /// synchronous `urllib.request` call in the Python original.
    private static func lookup(_ candidate: String) -> (isAddress: Bool, networkAvailable: Bool) {
        let key = normalize(candidate)

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return (cached, true)
        }
        cacheLock.unlock()

        guard var components = URLComponents(string: apiURL) else {
            return (false, false)
        }
        components.queryItems = [
            URLQueryItem(name: "sok", value: candidate),
            URLQueryItem(name: "treffPerSide", value: "1"),
        ]
        guard let url = components.url else { return (false, false) }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)

        guard resultError == nil, let data = resultData,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, false)
        }

        let addresses = json["adresser"] as? [Any] ?? []
        let confirmed = !addresses.isEmpty

        cacheLock.lock()
        cache[key] = confirmed
        cacheLock.unlock()

        return (confirmed, true)
    }

    /// Verify NER STED spans against Kartverket and return confirmed addresses.
    ///
    /// Returns `(addressSpans, networkAvailable)` — `networkAvailable` is
    /// `false` if any API call failed.
    static func detect(_ text: String, nerSpans: [PIISpan]) -> (spans: [PIISpan], networkAvailable: Bool) {
        let ns = text as NSString
        var addressSpans: [PIISpan] = []
        var networkAvailable = true

        for span in nerSpans {
            guard addressCategories.contains(span.category) else { continue }
            let candidate = ns.substring(with: NSRange(location: span.position, length: span.length))
            guard candidate.rangeOfCharacter(from: .decimalDigits) != nil else { continue }

            let (confirmed, netOK) = lookup(candidate)
            if !netOK {
                networkAvailable = false
                continue
            }
            if confirmed {
                addressSpans.append(PIISpan(position: span.position, length: span.length,
                                             category: "ADRESSE", replacement: "[ADRESSE]"))
            }
        }

        return (addressSpans, networkAvailable)
    }
}
