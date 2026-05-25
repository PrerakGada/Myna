// SineBuffer.swift — test helper. Generates AVAudioPCMBuffer of a given
// duration filled with a low-amplitude sine wave so the engine has real
// content to render. No disk I/O.
import AVFoundation
import Foundation

enum SineBuffer {
    /// 22050 Hz mono float buffer carrying a 440 Hz sine wave at the
    /// given duration in seconds.
    static func make(duration: TimeInterval, sampleRate: Double = 22_050, frequency: Double = 440) -> AVAudioPCMBuffer {
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(duration * sampleRate)
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let twoPi = 2.0 * Double.pi
        let channel = buffer.floatChannelData?[0]
        for frame in 0..<Int(frames) {
            let value = Float(0.1 * sin(twoPi * frequency * Double(frame) / sampleRate))
            channel?[frame] = value
        }
        return buffer
    }
}
