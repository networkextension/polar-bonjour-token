import Foundation

/// Bonjour service for remote playback control.
public enum PolarRemoteService {
    public static let type = "_polar-remote._tcp"
    public static let version = "1"
    /// PSK identity label — must match on both sides (see `PolarPSK`).
    public static let pskIdentity = "polar-remote"

    public enum TXT {
        public static let version = "v"
        public static let name    = "name"   // human label for the receiver
    }
}

/// A command sent controller → receiver. JSON-friendly (one `action` string + optional arg)
/// so it stays trivially cross-language and forward-compatible.
public struct PlaybackCommand: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case playPause, play, pause, next, previous, stop, seek, status
    }
    public var action: Action
    public var fraction: Double?   // for .seek (0…1)

    public init(_ action: Action, fraction: Double? = nil) {
        self.action = action
        self.fraction = fraction
    }

    public static let playPause = PlaybackCommand(.playPause)
    public static let play      = PlaybackCommand(.play)
    public static let pause     = PlaybackCommand(.pause)
    public static let next      = PlaybackCommand(.next)
    public static let previous  = PlaybackCommand(.previous)
    public static let stop      = PlaybackCommand(.stop)
    public static let status    = PlaybackCommand(.status)
    public static func seek(_ fraction: Double) -> PlaybackCommand {
        PlaybackCommand(.seek, fraction: fraction)
    }
}

/// A snapshot of the receiver's playback state, pushed receiver → controller.
public struct PlaybackStatus: Codable, Sendable, Equatable {
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    public var album: String
    public var trackID: String
    public var index: Int
    public var queueCount: Int
    public var currentTime: Double
    public var duration: Double

    public init(isPlaying: Bool = false, title: String = "", artist: String = "",
                album: String = "", trackID: String = "", index: Int = 0,
                queueCount: Int = 0, currentTime: Double = 0, duration: Double = 0) {
        self.isPlaying = isPlaying
        self.title = title; self.artist = artist; self.album = album
        self.trackID = trackID; self.index = index; self.queueCount = queueCount
        self.currentTime = currentTime; self.duration = duration
    }

    public static let idle = PlaybackStatus()
}

/// Envelope on the wire (one framed JSON message each way).
enum RemoteMessage {
    struct Command: Codable { var type = "cmd"; var command: PlaybackCommand }
    struct Status: Codable { var type = "status"; var status: PlaybackStatus }
}
