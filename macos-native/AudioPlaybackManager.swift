import Foundation
import AVFoundation
import Combine

/// Plays back a stored meeting recording. One player at a time; toggling on a
/// different URL switches to it.
final class AudioPlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// Isolates the 0.5s playback tick from the rest of the manager's
    /// @Published state. Views that only need the running time (e.g.
    /// PlaybackTimeLabel) observe this instead of the manager itself, so a
    /// tick re-renders just that label rather than every view holding the
    /// manager as a @StateObject.
    final class Clock: ObservableObject {
        @Published var currentTime: TimeInterval = 0
    }

    @Published var isPlaying = false
    @Published var lastError: String?
    let clock = Clock()

    private(set) var currentURL: URL?
    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?

    func togglePlayback(url: URL) {
        lastError = nil
        if currentURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                // Stop polling while paused — nothing is advancing.
                timer?.cancel()
                timer = nil
            } else {
                player.play()
                isPlaying = true
                startClock()
            }
            return
        }
        play(url: url)
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.cancel()
        timer = nil
        currentURL = nil
        isPlaying = false
        clock.currentTime = 0
    }

    private func play(url: URL) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            player = p
            currentURL = url
            p.play()
            isPlaying = true
            startClock()
        } catch {
            lastError = "Couldn't play recording: \(error.localizedDescription)"
        }
    }

    private func startClock() {
        timer?.cancel()
        timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.clock.currentTime = self?.player?.currentTime ?? 0 }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}
