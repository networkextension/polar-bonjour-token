import Foundation
import PolarRemote

/// An in-memory fake player so the receiver is testable without a real audio stack.
/// Mirrors the surface ShangDynasty's `MusicPlayer` exposes (playPause/next/previous/seek).
final class DemoPlayer: PlaybackTarget {
    private let lock = NSLock()
    private let tracks: [(title: String, artist: String, album: String, id: String, dur: Double)] = [
        ("Clair de Lune", "Debussy", "Suite Bergamasque", "t1", 300),
        ("Gymnopédie No.1", "Satie", "Trois Gymnopédies", "t2", 210),
        ("Spiegel im Spiegel", "Pärt", "Alina", "t3", 540),
    ]
    private var index = 0
    private var isPlaying = true
    private var currentTime = 0.0
    private var volume = 1.0

    /// Notified after every state change so the receiver can push status to controllers.
    var onChange: ((PlaybackStatus) -> Void)?

    func handleRemoteCommand(_ command: PlaybackCommand) {
        lock.lock()
        switch command.action {
        case .playPause: isPlaying.toggle()
        case .play:      isPlaying = true
        case .pause:     isPlaying = false
        case .stop:      isPlaying = false; currentTime = 0
        case .next:      index = (index + 1) % tracks.count; currentTime = 0
        case .previous:
            if currentTime > 3 { currentTime = 0 }
            else { index = (index - 1 + tracks.count) % tracks.count; currentTime = 0 }
        case .seek:      currentTime = (command.fraction ?? 0) * tracks[index].dur
        case .volumeUp:   volume = min(1, volume + 0.1)
        case .volumeDown: volume = max(0, volume - 0.1)
        case .setVolume:  volume = max(0, min(1, command.fraction ?? volume))
        case .status:    break
        }
        let snapshot = statusLocked()
        lock.unlock()
        FileHandle.standardError.write(Data("[receiver] \(command.action.rawValue) → \(snapshot.title) (\(snapshot.isPlaying ? "playing" : "paused"))\n".utf8))
        onChange?(snapshot)
    }

    func currentPlaybackStatus() -> PlaybackStatus {
        lock.lock(); defer { lock.unlock() }
        return statusLocked()
    }

    private func statusLocked() -> PlaybackStatus {
        let t = tracks[index]
        return PlaybackStatus(isPlaying: isPlaying, title: t.title, artist: t.artist,
                              album: t.album, trackID: t.id, index: index,
                              queueCount: tracks.count, currentTime: currentTime, duration: t.dur)
    }
}
