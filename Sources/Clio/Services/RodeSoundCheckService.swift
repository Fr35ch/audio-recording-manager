import Combine
import Foundation

// MARK: - RØDE Sound Check Service

/// Drives the RØDE pre-recording sound check from per-channel RMS published by
/// `AudioRecorder`.
///
/// This service no longer owns an `AVAudioEngine`. macOS cannot reliably support
/// two `AVAudioEngine` instances tapping the same input device simultaneously —
/// the previous engine here fought `SpeechActivityDetector`'s engine inside
/// `AudioRecorder`, and the cascading reconfiguration when a RØDE device
/// connected corrupted SwiftUI rendering. Instead, it subscribes to
/// `AudioRecorder.shared.channelRMS` (fed by the existing `levelTimer`) and
/// applies its green-zone logic to those values.
///
/// Green zone: RMS in [0.01, 0.25). Once a channel reaches green, its
/// `leftPassed` / `rightPassed` latch stays `true` until `resetPassState()`.
final class RodeSoundCheckService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var leftRMS: Float = 0
    @Published private(set) var rightRMS: Float = 0
    @Published private(set) var leftPassed: Bool = false
    @Published private(set) var rightPassed: Bool = false

    // MARK: - Private

    private var cancellable: AnyCancellable?

    // Green zone constants
    private let greenMin: Float = 0.01
    private let greenMax: Float = 0.25

    // MARK: - Public API

    var isRunning: Bool { cancellable != nil }

    /// Start observing per-channel RMS from `AudioRecorder`. Safe to call
    /// multiple times — cancels the existing subscription first.
    func startMetering() {
        stopMetering()

        cancellable = AudioRecorder.shared.$channelRMS
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rms in
                self?.apply(rms)
            }

        print("🎙️ RodeSoundCheck: observing AudioRecorder.channelRMS")
    }

    /// Stop observing and reset published RMS values to zero.
    func stopMetering() {
        cancellable?.cancel()
        cancellable = nil

        leftRMS = 0
        rightRMS = 0

        print("🎙️ RodeSoundCheck: metering stopped")
    }

    /// Clears the `leftPassed` / `rightPassed` latches without stopping metering.
    func resetPassState() {
        DispatchQueue.main.async { [weak self] in
            self?.leftPassed = false
            self?.rightPassed = false
        }
    }

    // MARK: - Green zone logic

    private func apply(_ rms: [Float]) {
        let lRMS = rms.count > 0 ? rms[0] : 0
        let rRMS = rms.count > 1 ? rms[1] : lRMS

        leftRMS  = lRMS
        rightRMS = rRMS

        if lRMS >= greenMin && lRMS < greenMax { leftPassed  = true }
        if rRMS >= greenMin && rRMS < greenMax { rightPassed = true }
    }
}
