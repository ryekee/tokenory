// [INPUT]: Drum tooth crossings and user-controlled mute/volume.
// [OUTPUT]: Short synthesized mechanical clicks, released when idle or hidden.
// [POS]: Local audio only; no assets, microphone access or external service.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AVFoundation
import Observation

@MainActor @Observable
final class HUDSound {
    static let shared = HUDSound()
    private(set) var error: String?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var buffer: AVAudioPCMBuffer?
    @ObservationIgnored private var lastClick: TimeInterval = 0

    func update(preferences: HUDPreferences) {
        player?.volume = Float(preferences.volume)
        if !preferences.soundEnabled || preferences.volume == 0 { stop() }
    }

    func tick(preferences: HUDPreferences) {
        guard preferences.soundEnabled, preferences.volume > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClick >= 0.04 else { return }
        do {
            if engine == nil {
                let engine = AVAudioEngine(), player = AVAudioPlayerNode()
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
                let count: AVAudioFrameCount = 1544
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
                buffer.frameLength = count
                let samples = buffer.floatChannelData![0]
                for index in 0..<Int(count) {
                    let t = Double(index) / format.sampleRate
                    let noise = Double.random(in: -1...1) * 0.48 * exp(-t * 270)
                    let upper = 0.3 * sin(t * 2 * .pi * 1250) * exp(-t * 190)
                    let lower = 0.2 * sin(t * 2 * .pi * 360) * exp(-t * 130)
                    samples[index] = Float(noise + upper + lower)
                }
                engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
                self.engine = engine; self.player = player; self.buffer = buffer
            }
            guard let engine, let player, let buffer else { return }
            if !engine.isRunning { try engine.start() }
            player.volume = Float(preferences.volume)
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(buffer)
            lastClick = now; error = nil
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        player?.stop(); engine?.stop()
    }
}
