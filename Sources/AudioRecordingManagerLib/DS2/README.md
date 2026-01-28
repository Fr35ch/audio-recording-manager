# DS2 Module

DS2 (DSS Pro) audio file support for Audio Recording Manager.

## Quick Start

```swift
import AudioRecordingManagerLib

// Main coordinator
let manager = DS2Manager.shared

// Scan for DS2 files
await manager.scanForDS2Files(in: directoryURL)

// Decode a file
try await manager.decodeFile(
    at: ds2FileURL,
    to: wavOutputURL,
    outputFormat: .wav,
    promptForPassword: { url in
        await showPasswordDialog()
    }
)

// Get metadata
let metadata = try manager.getMetadata(for: ds2FileURL)
print("Duration: \(metadata.formattedDuration)")
print("Author: \(metadata.authorName ?? "Unknown")")
```

## Status

⚠️ **Stub Implementation**: Architecture complete, SDK integration pending.

## Features

### ✅ Implemented

- Protocol-based architecture
- Comprehensive error handling
- Secure password storage (macOS Keychain)
- File format validation
- Basic metadata extraction
- Full test suite
- SwiftUI integration ready

### 🔄 TODO (Requires OM System Audio SDK)

- Actual DS2 decoding
- Encryption/decryption
- Full metadata extraction
- Key derivation from password

## Architecture

```
DS2Manager          # Main coordinator
    ├── DS2Decoder           # Decoding operations (stub)
    ├── DS2PasswordManager   # Keychain storage (complete)
    └── DS2MetadataExtractor # Metadata parsing (basic)
```

## Files

| File | Purpose | Status |
|------|---------|--------|
| `DS2Manager.swift` | Main API | ✅ Complete |
| `DS2Decoder.swift` | Decoding logic | ⚠️ Stub |
| `DS2PasswordManager.swift` | Password storage | ✅ Complete |
| `DS2MetadataExtractor.swift` | Metadata parsing | ⚠️ Basic only |
| `DS2Models.swift` | Data structures | ✅ Complete |
| `DS2Protocols.swift` | Interfaces | ✅ Complete |
| `DS2Error.swift` | Error types | ✅ Complete |

## Testing

```bash
# Run all DS2 tests
swift test --filter DS2

# Run specific test class
swift test --filter DS2PasswordManagerTests
```

## Next Steps

1. **Obtain OM System Audio SDK**
   - Apply at https://audiodeveloper.omsystem.com
   - Sign NDA
   - Receive SDK package

2. **Integrate SDK**
   - See `docs/DS2_INTEGRATION_GUIDE.md` for detailed instructions
   - Search codebase for `// TODO: Implement` comments
   - Replace stub implementations with SDK calls

3. **Test with Real Files**
   - Add sample DS2 files to `Tests/Resources/`
   - Test encrypted and unencrypted files
   - Verify metadata extraction

## Documentation

See `docs/DS2_INTEGRATION_GUIDE.md` for complete documentation including:

- Architecture details
- Data models
- Error handling
- Security considerations
- SDK integration guide
- UI integration examples

## Security

Passwords are stored securely in macOS Keychain:

```swift
let passwordManager = DS2PasswordManager.shared

// Store
try passwordManager.storePassword("secret", for: fileURL)

// Retrieve
let password = try passwordManager.retrievePassword(for: fileURL)

// Delete
try passwordManager.deletePassword(for: fileURL)
```

**Features**:
- Encrypted at rest
- Per-file isolation
- Access restricted to app
- No plaintext storage

## Error Handling

```swift
do {
    let audioData = try await decoder.decode(fileAt: url, password: password, outputFormat: .wav)
} catch DS2Error.encryptionKeyRequired {
    // Prompt for password
} catch DS2Error.invalidPassword {
    // Show error to user
} catch DS2Error.sdkNotAvailable {
    // SDK not integrated yet
} catch {
    // Other errors
}
```

## Protocol Conformance

Implement custom decoders:

```swift
final class MyDS2Decoder: DS2DecoderProtocol {
    func isValidDS2File(at url: URL) -> Bool { ... }
    func isEncrypted(at url: URL) throws -> Bool { ... }
    func extractMetadata(from url: URL) throws -> DS2Metadata { ... }
    func decode(fileAt url: URL, password: String?, outputFormat: DS2OutputFormat) async throws -> DS2AudioData { ... }
    func decodeAndSave(from sourceURL: URL, to destinationURL: URL, password: String?, outputFormat: DS2OutputFormat) async throws { ... }
}

// Use custom decoder
let manager = DS2Manager(decoder: MyDS2Decoder())
```

## Questions?

- 📖 Read `docs/DS2_INTEGRATION_GUIDE.md`
- 🧪 Check test files for usage examples
- 🔍 Search for `TODO` comments in code
- 🌐 Visit https://audiodeveloper.omsystem.com

---

**Version**: 1.0.0
**Last Updated**: 2025-01-28
**Status**: Stub Implementation - SDK Integration Required
