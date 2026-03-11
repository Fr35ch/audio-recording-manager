// AudioRecordingManagerLib.swift
// Testable library components for Audio Recording Manager
//
// This module contains testable business logic separated from the main app.
// As the project grows, refactor code from main.swift into this module.

import Foundation

/// Library version information
public struct AudioRecordingManagerLib {
    public static let version = "1.0.0"
    public static let name = "Audio Recording Manager"

    /// Returns true if the library is properly initialized
    public static func isInitialized() -> Bool {
        return true
    }
}

/// Audio file utilities
public struct AudioFileUtils {
    /// Validates that a file path has a supported audio extension
    /// - Parameter path: File path to validate
    /// - Returns: true if the extension is supported
    public static func isValidAudioExtension(_ path: String) -> Bool {
        let supportedExtensions = ["wav", "mp3", "m4a", "aac", "flac", "aiff"]
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// Formats a duration in seconds to a human-readable string
    /// - Parameter seconds: Duration in seconds
    /// - Returns: Formatted string (e.g., "1:23" or "1:05:30")
    public static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Formats a file size in bytes to a human-readable string
    /// - Parameter bytes: Size in bytes
    /// - Returns: Formatted string (e.g., "1.5 MB")
    public static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
