import CoreAudio
import Foundation

/// What decides when a device actually plays a sample.
public struct OutputTiming: Equatable, Sendable {
    public var sampleRate: Double
    /// Processing delay of the output stream (e.g. speaker DSP), in frames.
    public var streamLatencyFrames: UInt32

    public init(sampleRate: Double, streamLatencyFrames: UInt32) {
        self.sampleRate = sampleRate
        self.streamLatencyFrames = streamLatencyFrames
    }

    public var streamLatencyMilliseconds: Double {
        sampleRate > 0 ? Double(streamLatencyFrames) / sampleRate * 1000 : 0
    }

    public static func read(_ id: AudioObjectID) -> OutputTiming {
        let streams = HAL.objectIDs(id, propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
        let streamLatency = streams.compactMap { HAL.value($0, propertyAddress(kAudioStreamPropertyLatency), initial: UInt32(0)) }.max() ?? 0
        let rate = HAL.value(id, propertyAddress(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
        return OutputTiming(sampleRate: rate, streamLatencyFrames: streamLatency)
    }
}

/// Timing alignment between the outputs of a session.
///
/// macOS already aligns the sub-devices of a multi-output device by their reported device latency and
/// safety offset (it feeds slow devices early). It leaves out the stream latency, so that part is evened
/// out here; what a device does not report at all (e.g. extra Bluetooth delay) is up to the user's
/// per-device offset. `latency-out` can only delay, so everything is expressed as a delay >= 0.
public enum SyncDelays {
    public static let manualRange: ClosedRange<Double> = 0...400
    public static let manualStep: Double = 5

    /// Automatic delay per output in milliseconds: everyone waits for the output with the slowest stream.
    public static func automatic(_ timings: [OutputTiming]) -> [Double] {
        let slowest = timings.map(\.streamLatencyMilliseconds).max() ?? 0
        return timings.map { slowest - $0.streamLatencyMilliseconds }
    }

    public static func clampManual(_ milliseconds: Double) -> Double {
        guard milliseconds.isFinite else { return 0 }
        return min(max((milliseconds / manualStep).rounded() * manualStep, manualRange.lowerBound), manualRange.upperBound)
    }

    /// `latency-out` counts frames in the sub-device's own sample rate.
    public static func frames(milliseconds: Double, sampleRate: Double) -> Int {
        guard milliseconds.isFinite, milliseconds > 0, sampleRate > 0 else { return 0 }
        return Int((milliseconds / 1000 * sampleRate).rounded())
    }
}
