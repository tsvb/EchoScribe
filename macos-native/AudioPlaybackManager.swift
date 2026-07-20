import Foundation
import AVFoundation
import Combine

/// Plays back a stored meeting recording. One player at a time; toggling on a
/// different URL switches to it.
final class AudioPlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var lastError: String?

    private(set) var currentURL: URL?
    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?

    func togglePlayback(url: URL) {
        lastError = nil
        if currentURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
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
        currentTime = 0
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
            timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.currentTime = self?.player?.currentTime ?? 0 }
        } catch {
            lastError = "Couldn't play recording: \(error.localizedDescription)"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}
