# DS2 File Support Integration Guide

## Overview

This guide documents the DS2 (DSS Pro) file support infrastructure for Audio Recording Manager. The DS2 module provides a complete architecture for handling encrypted Olympus DS2 audio files, with security-first password management and extensible decoding capabilities.

## Status: STUB IMPLEMENTATION

⚠️ **Current Status**: The DS2 module is a **stub implementation** providing the complete architecture and interfaces, but **does not yet perform actual DS2 decoding**.

**Next Steps**: Integration with OM System Audio SDK (requires NDA and license) to enable full decoding functionality.

## Architecture

### Module Structure

```
Sources/AudioRecordingManagerLib/DS2/
├── DS2Error.swift              # Error definitions
├── DS2Models.swift             # Domain models and data structures
├── DS2Protocols.swift          # Protocol definitions
├── DS2PasswordManager.swift    # Secure Keychain password storage
├── DS2Decoder.swift            # Decoder stub (SDK integration point)
├── DS2MetadataExtractor.swift  # Metadata parsing
└── DS2Manager.swift            # Main coordinator
```

### Key Components

#### 1. DS2Manager (Main Coordinator)

The `DS2Manager` is the primary entry point for all DS2 operations:

```swift
let manager = DS2Manager.shared

// Scan for DS2 files
await manager.scanForDS2Files(in: directoryURL)

// Validate a file
let validation = manager.validateFile(at: fileURL)

// Decode with password handling
try await manager.decodeFile(
    at: sourceURL,
    to: destinationURL,
    outputFormat: .wav,
    promptForPassword: { url in
        // Present password dialog
        return await showPasswordDialog(for: url)
    }
)

// Get metadata
let metadata = try manager.getMetadata(for: fileURL)
```

#### 2. DS2PasswordManager (Secure Storage)

Implements macOS Keychain-based password storage:

```swift
let passwordManager = DS2PasswordManager.shared

// Store password securely
try passwordManager.storePassword("secret123", for: fileURL)

// Retrieve password
let password = try passwordManager.retrievePassword(for: fileURL)

// Check if stored
if passwordManager.hasPassword(for: fileURL) {
    // Password available
}

// Delete password
try passwordManager.deletePassword(for: fileURL)

// Clear all
try passwordManager.clearAllPasswords()
```

**Security Features**:
- Uses macOS Keychain Services
- Passwords encrypted at rest
- Per-file password isolation
- Automatic cleanup support
- Access control: `kSecAttrAccessibleWhenUnlocked`

#### 3. DS2Decoder (SDK Integration Point)

Protocol-based decoder for extensibility:

```swift
protocol DS2DecoderProtocol {
    func isValidDS2File(at url: URL) -> Bool
    func isEncrypted(at url: URL) throws -> Bool
    func extractMetadata(from url: URL) throws -> DS2Metadata
    func decode(fileAt url: URL, password: String?, outputFormat: DS2OutputFormat) async throws -> DS2AudioData
}
```

**Current Implementation**: Stub that validates file format and structure but throws `DS2Error.sdkNotAvailable` when attempting to decode.

**SDK Integration Point**: Replace stub implementation in `DS2Decoder.swift` with OM System Audio SDK calls.

#### 4. DS2MetadataExtractor

Extracts metadata from DS2 files:

```swift
let extractor = DS2MetadataExtractor()

// Basic metadata (no SDK required)
let basicMetadata = try extractor.extractBasicMetadata(from: fileURL)

// Full metadata (requires SDK and decryption)
let fullMetadata = try extractor.extractFullMetadata(from: fileURL, password: password)
```

**Current Capabilities**:
- File size and modification date
- Duration (from header parsing)
- Basic format validation
- Partial header information

**TODO with SDK**:
- Author ID and name
- Work type and priority
- Device information
- Full workflow metadata
- Custom fields

## Data Models

### DS2File

Represents a DS2 audio file:

```swift
struct DS2File: Identifiable {
    let id: UUID
    let url: URL
    let metadata: DS2Metadata
    let isEncrypted: Bool

    var filename: String
    var fileExtension: String
}
```

### DS2Metadata

Comprehensive metadata structure:

```swift
struct DS2Metadata: Codable {
    // Recording information
    let duration: TimeInterval
    let recordingDate: Date?
    let fileSize: Int64

    // Author information
    let authorID: String?
    let authorName: String?

    // Workflow metadata
    let workType: DS2WorkType?
    let priority: DS2Priority?
    let status: DS2Status?

    // Device information
    let deviceModel: String?
    let deviceSerialNumber: String?
    let firmwareVersion: String?

    // Audio format details
    let sampleRate: Int?
    let bitRate: Int?
    let channels: Int?
    let codec: String?

    // Encryption information
    let encryptionType: DS2EncryptionType?

    // Additional metadata
    let comments: String?
    let customFields: [String: String]?

    // Formatted helpers
    var formattedDuration: String
    var formattedFileSize: String
    var formattedRecordingDate: String?
}
```

### Enumerations

```swift
// Work type classification
enum DS2WorkType: String, Codable {
    case dictation, meeting, interview, lecture, memo, other
}

// Priority levels
enum DS2Priority: Int, Codable, Comparable {
    case low = 0, normal, high, urgent
}

// Recording status
enum DS2Status: String, Codable {
    case new, inProgress, completed, archived
}

// Encryption types
enum DS2EncryptionType: String, Codable {
    case none, aes128, aes256
}

// Output formats
enum DS2OutputFormat {
    case pcm, wav, m4a, mp3
}
```

## Error Handling

Comprehensive error types with localized descriptions:

```swift
enum DS2Error: Error, LocalizedError {
    // File errors
    case fileNotFound(String)
    case invalidFileFormat(String)
    case corruptedFile(String)
    case unsupportedVersion(String)

    // Encryption errors
    case encryptionKeyRequired
    case invalidPassword
    case decryptionFailed(String)
    case keyDerivationFailed(String)

    // Decoding errors
    case codecNotSupported(String)
    case decodingFailed(String)
    case audioStreamInvalid(String)

    // Metadata errors
    case metadataReadFailed(String)
    case metadataCorrupted(String)

    // SDK errors
    case sdkNotAvailable
    case sdkInitializationFailed(String)
    case sdkLicenseInvalid(String)

    // General
    case unknown(Error)
}
```

## Testing Infrastructure

Comprehensive test suite covering all major components:

### Test Files

```
Tests/AudioRecordingManagerTests/DS2Tests/
├── DS2PasswordManagerTests.swift    # Keychain password storage tests
├── DS2DecoderTests.swift            # Decoder validation tests
└── DS2MetadataTests.swift           # Model and metadata tests
```

### Running Tests

```bash
# Run all tests
swift test

# Run only DS2 tests
swift test --filter DS2

# Run specific test class
swift test --filter DS2PasswordManagerTests
```

### Test Coverage

- ✅ Password storage/retrieval (Keychain)
- ✅ Password special characters and Unicode
- ✅ File format validation
- ✅ Metadata model serialization
- ✅ Error handling
- ⚠️ Actual decoding (requires SDK)
- ⚠️ Encryption detection (stub only)

## Integration with Audio Recording Manager

### Import Pipeline Integration

To integrate DS2 files into the existing import workflow:

```swift
// In SDCardImportView or similar
import AudioRecordingManagerLib

class ImportManager {
    let ds2Manager = DS2Manager.shared

    func importFiles(from urls: [URL]) async {
        for url in urls {
            if url.pathExtension.lowercased() == "ds2" {
                await importDS2File(url)
            } else {
                await importStandardFile(url)
            }
        }
    }

    func importDS2File(_ sourceURL: URL) async {
        do {
            // Validate file
            let validation = ds2Manager.validateFile(at: sourceURL)
            guard validation.isValid else {
                print("Invalid DS2 file: \(validation.errors)")
                return
            }

            // Determine output path
            let audioFolder = AudioFileManager.shared.audioFolderPath
            let filename = sourceURL.deletingPathExtension().lastPathComponent
            let outputURL = URL(fileURLWithPath: audioFolder)
                .appendingPathComponent("\(filename).wav")

            // Decode with password handling
            try await ds2Manager.decodeFile(
                at: sourceURL,
                to: outputURL,
                outputFormat: .wav,
                promptForPassword: { [weak self] url in
                    await self?.promptUserForPassword(file: url)
                }
            )

            print("✅ Imported DS2 file: \(filename)")

        } catch {
            print("❌ DS2 import failed: \(error)")
        }
    }

    func promptUserForPassword(file: URL) async -> String? {
        // Present password dialog to user
        // Return password or nil if cancelled
        return await showPasswordDialog(for: file)
    }
}
```

### UI Integration Example

```swift
struct DS2ImportView: View {
    @StateObject private var ds2Manager = DS2Manager.shared
    @State private var showPasswordDialog = false
    @State private var selectedFile: DS2File?

    var body: some View {
        List(ds2Manager.ds2Files) { file in
            DS2FileRow(file: file)
                .onTapGesture {
                    if file.isEncrypted {
                        selectedFile = file
                        showPasswordDialog = true
                    } else {
                        Task {
                            await decodeFile(file)
                        }
                    }
                }
        }
        .sheet(isPresented: $showPasswordDialog) {
            PasswordDialog(file: selectedFile) { password in
                Task {
                    await decodeFile(selectedFile!, password: password)
                }
            }
        }
    }

    func decodeFile(_ file: DS2File, password: String? = nil) async {
        // Decode implementation
    }
}
```

## OM System Audio SDK Integration

### Integration Checklist

When you obtain the OM System Audio SDK:

1. **Add SDK to Project**
   ```bash
   # Copy SDK files to project
   cp -r /path/to/OMAudioSDK Sources/AudioRecordingManagerLib/Vendor/
   ```

2. **Update Package.swift**
   ```swift
   .target(
       name: "AudioRecordingManagerLib",
       dependencies: [],
       path: "Sources/AudioRecordingManagerLib",
       cSettings: [
           .headerSearchPath("Vendor/OMAudioSDK/include")
       ],
       linkerSettings: [
           .linkedLibrary("OMAudioSDK")
       ]
   )
   ```

3. **Implement DS2Decoder**

   Replace stub implementation in `DS2Decoder.swift`:

   ```swift
   import OMAudioSDK  // SDK import

   final class DS2Decoder: DS2DecoderProtocol {
       private var sdkInitialized = false
       private var sdkHandle: OpaquePointer?

       init() {
           // Initialize SDK
           initializeSDK()
       }

       private func initializeSDK() {
           // SDK initialization code
           // Handle license validation
           // Set up error callbacks
       }

       func decode(fileAt url: URL, password: String?, outputFormat: DS2OutputFormat) async throws -> DS2AudioData {
           // 1. Open DS2 file with SDK
           // 2. Check encryption status
           // 3. Derive key from password if encrypted
           // 4. Decrypt if necessary
           // 5. Decode to PCM
           // 6. Convert to requested format
           // 7. Return DS2AudioData
       }
   }
   ```

4. **Implement Key Derivation**

   Add password-to-key conversion based on SDK documentation:

   ```swift
   private func deriveKey(from password: String, for file: URL) throws -> Data {
       // Use SDK's key derivation function
       // This is proprietary and provided by SDK
   }
   ```

5. **Update Tests**

   Add integration tests with real DS2 files:

   ```swift
   func testDecodeRealDS2File() async throws {
       let testFile = URL(fileURLWithPath: "Tests/Resources/sample.ds2")
       let password = "test123"

       let audioData = try await decoder.decode(
           fileAt: testFile,
           password: password,
           outputFormat: .wav
       )

       XCTAssertGreaterThan(audioData.data.count, 0)
       XCTAssertEqual(audioData.format, .wav)
   }
   ```

6. **Update Documentation**

   Document SDK-specific requirements, limitations, and licensing.

### SDK Integration Points

Key areas in code marked with `TODO` comments:

- `DS2Decoder.swift:95` - Main decode implementation
- `DS2Decoder.swift:55` - Encryption detection
- `DS2MetadataExtractor.swift:60` - Full metadata extraction
- `DS2MetadataExtractor.swift:125` - Header parsing details

Search for `// TODO: Implement` comments in the codebase.

## Security Considerations

### Password Storage

- ✅ Passwords stored in macOS Keychain
- ✅ Encrypted at rest by system
- ✅ Access restricted to app sandbox
- ✅ Per-file isolation
- ✅ Automatic cleanup on file deletion

### Memory Security

When implementing SDK integration:

- [ ] Zero memory after password use
- [ ] Use secure memory allocation for keys
- [ ] Avoid logging sensitive data
- [ ] Implement secure cleanup in deinit

### Best Practices

1. **Never log passwords**: Avoid printing passwords to console
2. **Prompt vs Store**: Let user choose whether to remember password
3. **Session management**: Consider clearing passwords on app quit
4. **Audit logging**: Log decryption attempts for security auditing

## Performance Considerations

### Async/Await

All decoding operations use async/await for non-blocking I/O:

```swift
Task {
    do {
        let audioData = try await decoder.decode(fileAt: url, password: password, outputFormat: .wav)
        // Process audio data
    } catch {
        // Handle error
    }
}
```

### Batch Operations

For importing multiple DS2 files:

```swift
let results = await ds2Manager.decodeMultipleFiles(
    files: filePairs,
    outputFormat: .wav,
    promptForPassword: { url in
        // Prompt once per unique password
        return await showPasswordDialog(for: url)
    }
)

// Process results
for (url, result) in results {
    switch result {
    case .success:
        print("✅ Decoded: \(url.lastPathComponent)")
    case .failure(let error):
        print("❌ Failed: \(url.lastPathComponent) - \(error)")
    }
}
```

## Troubleshooting

### Common Issues

#### "DS2 file not found"
- Verify file exists at path
- Check file permissions

#### "Invalid DS2 file format"
- File may be corrupted
- Verify magic bytes (0x03 "ds2")
- Check file size (minimum ~512 bytes)

#### "SDK not available"
- SDK not yet integrated (expected for stub)
- When SDK added, verify initialization

#### "Invalid password"
- Password incorrect for this file
- Password may have been changed on device

### Debug Mode

Enable verbose logging:

```swift
// In DS2Manager or decoder
private let debugMode = true

if debugMode {
    print("🐛 [DS2] Operation: \(operation)")
}
```

## Roadmap

### Phase 1: Stub Implementation ✅
- [x] Architecture and protocols
- [x] Password management (Keychain)
- [x] Basic file validation
- [x] Error handling
- [x] Test infrastructure
- [x] Documentation

### Phase 2: SDK Integration 🔄
- [ ] Obtain OM System Audio SDK
- [ ] Sign NDA and license agreement
- [ ] Integrate SDK libraries
- [ ] Implement actual decoding
- [ ] Implement key derivation
- [ ] Full metadata extraction
- [ ] Integration tests with real files

### Phase 3: UI Integration 📋
- [ ] Import pipeline integration
- [ ] Password dialog UI
- [ ] Progress indicators
- [ ] Error messaging
- [ ] Batch import UX

### Phase 4: Advanced Features 🚀
- [ ] Password caching strategies
- [ ] Background decoding
- [ ] Format conversion options
- [ ] Metadata editing
- [ ] Workflow status tracking

## References

- **OM System Audio SDK**: https://audiodeveloper.omsystem.com
- **DS2 Format Info**: See research notes in project documentation
- **Keychain Services**: Apple Developer Documentation
- **Swift Concurrency**: Swift.org async/await guide

## Support

For questions or issues with DS2 integration:

1. Check this documentation
2. Review test cases for usage examples
3. Search codebase for `TODO` comments marking integration points
4. Consult OM System SDK documentation (when available)

---

**Last Updated**: 2025-01-28
**Version**: 1.0.0 (Stub Implementation)
**Status**: Ready for SDK Integration
