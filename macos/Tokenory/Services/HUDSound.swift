// [INPUT]: Drum tooth crossings and user changes to mute/volume.
// [OUTPUT]: Synthesized mechanical clicks for rolling and independent volume previews.
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
    @ObservationIgnored private var previewPlayer: AVAudioPlayerNode?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var buffer: AVAudioPCMBuffer?
    @ObservationIgnored private var lastClick: TimeInterval = 0

    func update(preferences: HUDPreferences) {
        player?.volume = Float(preferences.volume)
        previewPlayer?.volume = Float(preferences.volume)
        if !preferences.soundEnabled || preferences.volume == 0 {
            stopPreview()
            stop()
        }
    }

    func tick(preferences: HUDPreferences) {
        guard preferences.soundEnabled, preferences.volume > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClick >= 0.04 else { return }
        do {
            try startEngine()
            guard let player, let buffer else { return }
            player.volume = Float(preferences.volume)
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(buffer)
            lastClick = now; error = nil
        } catch {
            reportFailure(error)
        }
    }

    func preview(preferences: HUDPreferences) {
        update(preferences: preferences)
        guard preferences.soundEnabled, preferences.volume > 0 else { return }
        do {
            try startEngine()
            guard let previewPlayer, let buffer else { return }
            previewGeneration += 1
            let generation = previewGeneration
            previewPlayer.volume = Float(preferences.volume)
            // Replace a previous preview while dragging rather than queuing clicks.
            previewPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, previewGeneration == generation else { return }
                    stopPreview()
                }
            }
            if !previewPlayer.isPlaying { previewPlayer.play() }
            error = nil
        } catch {
            reportFailure(error)
        }
    }

    private func startEngine() throws {
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let previewPlayer = AVAudioPlayerNode()
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
            for node in [player, previewPlayer] {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
            }
            self.engine = engine
            self.player = player
            self.previewPlayer = previewPlayer
            self.buffer = buffer
        }
        if let engine, !engine.isRunning { try engine.start() }
    }

    private func reportFailure(_ error: Error) {
        self.error = error.localizedDescription
        stopPreview()
        stop()
    }

    private func stopPreview() {
        if previewPlayer?.isPlaying == true {
            previewGeneration += 1
            previewPlayer?.stop()
            if player?.isPlaying != true { engine?.stop() }
        }
    }

    func stop() {
        player?.stop()
        if previewPlayer?.isPlaying != true { engine?.stop() }
    }
}
