import CoreAudio
import Foundation
import SwiftUI

// MARK: - Record Button with NAV Styling
struct RecordButton: View {
    let isRecording: Bool
    let isVerified: Bool
    let action: () -> Void
    @State private var isHovering = false
    @State private var showAudioSourceMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Main Record/Stop Button
            Button(action: action) {
                if isRecording {
                    // Stop button with Liquid Glass styling
                    VStack(spacing: AppSpacing.sm) {
                        Rectangle()
                            .fill(AppColors.destructive)
                            .frame(width: 56, height: 56)
                            .cornerRadius(AppRadius.small)
                        Text("Stopp")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColors.destructive)
                            .textCase(.uppercase)
                            .tracking(1)
                    }
                } else if isVerified {
                    // Start Recording button with glass effect
                    Text("Start Opptak")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .tracking(0.5)
                        .padding(.horizontal, AppSpacing.xxl + AppSpacing.sm)
                        .padding(.vertical, AppSpacing.lg + 2)
                        .background(isHovering ? AppColors.destructive.opacity(0.85) : AppColors.destructive)
                        .cornerRadius(AppRadius.large)
                        .animation(.easeInOut(duration: 0.15), value: isHovering)
                } else {
                    // Verifying state - grey/disabled
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .colorScheme(.dark)
                        Text("Verifiserer mikrofon")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal, AppSpacing.xxl + AppSpacing.sm)
                    .padding(.vertical, AppSpacing.lg + 2)
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(AppRadius.large)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isVerified && !isRecording)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if isVerified || isRecording {
                        isHovering = true
                        DispatchQueue.main.async { NSCursor.pointingHand.set() }
                    }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }

            // Audio Source Settings Button (only show when not recording)
            if !isRecording {
                Button(action: {
                    showAudioSourceMenu.toggle()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(AppRadius.medium)
                }
                .buttonStyle(.plain)
                .help("Lydinnstillinger")
                .popover(isPresented: $showAudioSourceMenu, arrowEdge: .bottom) {
                    AudioSourceSelector()
                }
            }
        }
    }
}

// MARK: - Audio Source Selector

private struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
}

/// Only physical/hardware input devices. Excludes virtual, aggregate, AirPlay,
/// network, and Continuity Camera (AVB) sources.
private let physicalTransportTypes: Set<UInt32> = [
    kAudioDeviceTransportTypeBuiltIn,
    kAudioDeviceTransportTypeUSB,
    kAudioDeviceTransportTypeFireWire,
    kAudioDeviceTransportTypeBluetooth,
    kAudioDeviceTransportTypeBluetoothLE,
    kAudioDeviceTransportTypeThunderbolt,
    kAudioDeviceTransportTypePCI,
    kAudioDeviceTransportTypeHDMI,
    kAudioDeviceTransportTypeDisplayPort,
]

struct AudioSourceSelector: View {
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lydkilde")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                let devices = audioDevices.isEmpty ? [AudioDevice(id: 0, name: "Innebygd mikrofon")] : audioDevices
                ForEach(devices) { device in
                    AudioDeviceRow(device: device, recorder: AudioRecorder.shared)
                }
            }

            Divider()

            Text("Kun fysiske lydinngangsenheter vises")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: 250)
        .onAppear { loadAudioDevices() }
    }
}

private struct AudioDeviceRow: View {
    let device: AudioDevice
    @ObservedObject var recorder: AudioRecorder  // holds for re-render only

    var body: some View {
        let isSelected = AudioRecorder.shared.selectedInputDeviceID == device.id
        Button(action: { AudioRecorder.shared.setInputDevice(device.id) }) {
            HStack {
                Text(device.name)
                    .font(.system(size: 13))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
}

// Methods below belong to AudioSourceSelector (extracted here to avoid
// compiler type-check timeout on the body expression).
extension AudioSourceSelector {
    func loadAudioDevices() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else { return }

        var result: [AudioDevice] = []
        for id in ids {
            guard hasInputStream(id), isPhysicalDevice(id), let name = deviceName(id) else { continue }
            result.append(AudioDevice(id: id, name: name))
        }
        audioDevices = result
    }

    private func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func isPhysicalDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return physicalTransportTypes.contains(transport)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameRef: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &nameRef) == noErr else { return nil }
        return nameRef as String
    }
}

// MARK: - Recording Name Dialog
struct RecordingNameDialog: View {
    @Binding var recordingName: String
    let duration: TimeInterval
    let onSave: () -> Void
    let onDiscard: () -> Void
    @FocusState private var isTextFieldFocused: Bool
    @State private var showNameWarningAlert = false

    private var nameDetected: Bool {
        NameDetector.shared.containsName(in: recordingName)
    }

    var body: some View {
        VStack(spacing: 22) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.accent)

                Text("Gi opptaket et navn")
                    .font(.system(size: 18, weight: .semibold))

                Text("Varighet: \(formatDuration(duration))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Filename input
            VStack(alignment: .leading, spacing: 6) {
                Text("Navn på opptak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("f.eks. intervju-deltaker-01", text: $recordingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($isTextFieldFocused)
                    .onSubmit { trySave() }

                if nameDetected {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                            .font(.system(size: 11))
                        Text("Vi kan ha oppdaget et personnavn i filnavnet.")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.warning)
                    }
                } else {
                    Text("Tidsstempel legges til automatisk")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }

            // Preview
            if !recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 6) {
                    Text("Forhåndsvisning:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(recordingName.trimmingCharacters(in: .whitespacesAndNewlines))_\(previewTimestamp()).m4a")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onDiscard) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                        Text(AppCopy.Common.discard)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: trySave) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                        Text(AppCopy.Common.save)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear {
            isTextFieldFocused = true
        }
        .alert("Mulig personopplysning i filnavn", isPresented: $showNameWarningAlert) {
            Button(AppCopy.Common.continueAction, role: .none) { onSave() }
            Button(AppCopy.Common.renameFile, role: .cancel) {}
        } message: {
            Text("Vi tror filnavnet kan inneholde et personnavn. Vil du fortsette, eller endre filnavnet?")
        }
    }

    private func trySave() {
        if nameDetected {
            showNameWarningAlert = true
        } else {
            onSave()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func previewTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Silence Warning Dialog
struct SilenceWarningDialog: View {
    let onContinue: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.warning)
                Text("Ingen lyd registrert")
                    .font(.system(size: 18, weight: .semibold))
                Text("Vi har ikke registrert stemmer eller lyd på en stund. Vil du pause eller stoppe opptaket?")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                Button(action: onContinue) {
                    Text("Fortsett opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(action: onPause) {
                    Text("Pause opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button(action: onStop) {
                    Text("Stopp opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(28)
        .frame(width: 400)
    }
}

// MARK: - Recording View
struct RecordingView: View {
    @ObservedObject var recorder: AudioRecorder
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared
    @StateObject private var soundCheck = RodeSoundCheckService()
    @Binding var isShowing: Bool
    @State private var microphoneVerified = false
    @State private var verificationTimer: Timer?
    @State private var recordingName = ""  // User-entered filename
    @State private var glowRadius: CGFloat = 10
    @State private var glowOpacity: Double = 0.2

    // MARK: - Computed verification state

    /// True when recording can start. RØDE path requires both channels in green zone.
    private var isVerified: Bool {
        if recorder.rodeMonitor.isConnected {
            return soundCheck.leftPassed && soundCheck.rightPassed
        }
        return microphoneVerified
    }

    var body: some View {
        // Main recording area (sidebar is now global in MainView)
        mainRecordingView
            .sheet(isPresented: $recorder.showNamingDialog) {
                RecordingNameDialog(
                    recordingName: $recordingName,
                    duration: recorder.recordingDuration,
                    onSave: {
                        recorder.saveRecordingWithName(recordingName)
                        recordingName = ""  // Reset for next recording
                    },
                    onDiscard: {
                        recorder.cancelPendingRecording()
                        recordingName = ""
                    }
                )
            }
            .sheet(isPresented: $recorder.showSilenceWarning) {
                SilenceWarningDialog(
                    onContinue: {
                        recorder.dismissSilenceWarning()
                    },
                    onPause: {
                        recorder.showSilenceWarning = false
                        recorder.pauseRecording()
                    },
                    onStop: {
                        recorder.showSilenceWarning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            recorder.stopRecording()
                        }
                    }
                )
            }
            .onAppear {
                // Audio monitoring only — recordings list stays in sync via
                // RecordingsManager's didChangeNotification subscription.
                recorder.startMonitoring()
                // Reset verification status
                microphoneVerified = false

                // Auto-verify after timeout (fallback if no audio detected)
                verificationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) {
                    _ in
                    if !microphoneVerified {
                        microphoneVerified = true
                    }
                }

                // Start RØDE metering if device is already connected on appear
                if recorder.rodeMonitor.isConnected {
                    soundCheck.resetPassState()
                    soundCheck.startMetering()
                }
            }
            .onDisappear {
                // Stop monitoring when leaving the recording view
                recorder.stopMonitoring()
                // Stop RØDE metering
                soundCheck.stopMetering()
                // Stop playback if active
                audioPlayer.stop()
                // Cancel verification timer
                verificationTimer?.invalidate()
            }

            .onChange(of: recorder.rodeMonitor.isConnected) { _, connected in
                if connected {
                    soundCheck.resetPassState()
                    soundCheck.startMetering()
                } else {
                    soundCheck.stopMetering()
                }
            }

            .onChange(of: recorder.frequencyBands) { _, bands in
                // Update glow state with a smooth animation so it plays through between frames
                // rather than restarting every 23 ms (which caused jitter with inline animation).
                let avg = bands.isEmpty ? 0 : bands.reduce(0, +) / Float(bands.count)
                let amplified = min(Double(avg) * 3.0, 1.0)
                withAnimation(.easeInOut(duration: 0.2)) {
                    glowRadius = CGFloat(amplified) * 30 + 10   // 10–40 pt
                    glowOpacity = amplified * 0.8 + 0.2          // 0.2–1.0
                }
                // Auto-verify when audio is detected (only in non-RØDE path)
                if !recorder.rodeMonitor.isConnected, !microphoneVerified, avg > 0.15 {
                    microphoneVerified = true
                    verificationTimer?.invalidate()
                }
            }
    }

    var mainRecordingView: some View {
        // GeometryReader + ScrollView clamp the content to the viewport height so
        // inserting the RØDE sound-check panel can never grow the detail column
        // past the window (which would push the sidebar icons off-screen and clip
        // the panel). minHeight: geo.size.height keeps the mic centered when the
        // content fits, and lets it scroll when it doesn't.
        GeometryReader { geo in
            ScrollView {
                // Recording Interface
                ZStack {
                    // Main Content
                    VStack(spacing: 40) {
                    Spacer()

                    // Save Confirmation
                    if recorder.showSaveConfirmation {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 64, weight: .ultraLight))
                                .foregroundStyle(.green)
                            Text("Recording Saved")
                                .font(.system(size: 24, weight: .light))
                            if let filename = recorder.lastSavedFile {
                                Text(filename)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(48)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(2)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Microphone Icon with pulsing glow
                        VStack(spacing: 24) {
                            Image(
                                systemName: recorder.isRecording && !recorder.isPaused
                                    ? "mic.fill" : "mic"
                            )
                            .font(.system(size: 72, weight: .ultraLight))
                            .foregroundStyle(
                                recorder.isRecording && !recorder.isPaused ? .red : .primary
                            )
                            .shadow(
                                color: (recorder.isRecording && !recorder.isPaused
                                    ? Color.red : Color.blue)
                                    .opacity(glowOpacity),
                                radius: glowRadius,
                                x: 0,
                                y: 0
                            )
                            .shadow(
                                color: (recorder.isRecording && !recorder.isPaused
                                    ? Color.red : Color.blue)
                                    .opacity(0.3),
                                radius: 15,
                                x: 0,
                                y: 0
                            )

                            // Recording Duration
                            if recorder.isRecording || recorder.recordingDuration > 0 {
                                Text(formatDuration(recorder.recordingDuration))
                                    .font(.system(size: 64, weight: .thin, design: .default))
                                    .foregroundStyle(recorder.isPaused ? .orange : .primary)
                                    .tracking(2)
                                    .monospacedDigit()
                            }

                            // Status Text - minimal
                            if recorder.isPaused {
                                Text("Paused")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundStyle(.orange)
                                    .textCase(.uppercase)
                                    .tracking(2)
                            } else if recorder.isRecording {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 6, height: 6)
                                    Text("Recording")
                                        .font(.system(size: 14, weight: .light))
                                        .foregroundStyle(.red)
                                        .textCase(.uppercase)
                                        .tracking(2)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Scrolling Waveform Timeline - Only visible when recording
                    if recorder.isRecording {
                        ScrollingWaveformView(
                            waveformHistory: recorder.waveformHistory,
                            isRecording: recorder.isRecording
                        )
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }

                    // Control Buttons - Minimalist
                    if !recorder.showSaveConfirmation {
                        VStack(spacing: AppSpacing.xl) {
                            // RØDE Sound Check Panel (pre-recording only)
                            if recorder.rodeMonitor.isConnected && !recorder.isRecording {
                                RodeSoundCheckView(
                                    deviceName: recorder.rodeMonitor.deviceName,
                                    meterService: soundCheck
                                )
                                .frame(maxWidth: 520)
                                .padding(.horizontal, 40)
                            }

                            HStack(spacing: 32) {
                                // Delete Button (always show during recording)
                                if recorder.isRecording {
                                    Button(action: {
                                        recorder.deleteCurrentRecording()
                                        isShowing = false
                                    }) {
                                        VStack(spacing: 10) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 24, weight: .ultraLight))
                                                .foregroundStyle(.red.opacity(0.8))
                                                .frame(width: 56, height: 56)
                                                .background(Color.red.opacity(0.08))
                                                .cornerRadius(2)
                                            Text("Delete")
                                                .font(.system(size: 11, weight: .light))
                                                .foregroundStyle(.red.opacity(0.8))
                                                .textCase(.uppercase)
                                                .tracking(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Main Record/Stop Button
                                RecordButton(
                                    isRecording: recorder.isRecording,
                                    isVerified: isVerified,
                                    action: {
                                        if recorder.isRecording {
                                            recorder.stopRecording()
                                        } else {
                                            // End the RØDE sound check once recording begins
                                            soundCheck.stopMetering()
                                            recorder.startRecording()
                                        }
                                    }
                                )

                                // Pause/Resume Button (always show during recording)
                                if recorder.isRecording {
                                    Button(action: {
                                        if recorder.isPaused {
                                            recorder.resumeRecording()
                                        } else {
                                            recorder.pauseRecording()
                                        }
                                    }) {
                                        VStack(spacing: 10) {
                                            Image(systemName: recorder.isPaused ? "play" : "pause")
                                                .font(.system(size: 24, weight: .ultraLight))
                                                .foregroundStyle(.orange.opacity(0.8))
                                                .frame(width: 56, height: 56)
                                                .background(Color.orange.opacity(0.08))
                                                .cornerRadius(2)
                                            Text(recorder.isPaused ? "Resume" : "Pause")
                                                .font(.system(size: 11, weight: .light))
                                                .foregroundStyle(.orange.opacity(0.8))
                                                .textCase(.uppercase)
                                                .tracking(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.bottom, 60)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }

}
