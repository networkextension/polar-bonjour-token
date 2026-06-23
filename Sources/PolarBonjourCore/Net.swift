import Foundation
import Network

/// async helpers over NWConnection + a 4-byte-length-prefixed JSON framing.
public extension NWConnection {

    /// Drive the connection to `.ready`, or throw if it fails/cannot find a path.
    func waitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce(cont)
            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.success()
                case .failed(let e):
                    resumed.failure(e)
                case .waiting(let e):
                    // On a LAN we expect an immediate path; treat waiting as failure.
                    resumed.failure(e)
                case .cancelled:
                    resumed.failure(PolarError.connectionClosed)
                default:
                    break
                }
            }
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Read exactly `n` bytes (or throw on early close).
    func receiveExact(_ n: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < n {
            let want = n - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                self.receive(minimumIncompleteLength: 1, maximumLength: want) {
                    data, _, isComplete, error in
                    if let error { cont.resume(throwing: error); return }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: PolarError.connectionClosed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    func sendFramed(_ data: Data) async throws {
        let len = UInt32(data.count)
        var frame = Data([
            UInt8((len >> 24) & 0xff), UInt8((len >> 16) & 0xff),
            UInt8((len >> 8) & 0xff),  UInt8(len & 0xff),
        ])
        frame.append(data)
        try await sendAsync(frame)
    }

    func recvFramed(maxLen: Int = 1_000_000) async throws -> Data {
        let header = try await receiveExact(4)
        let len = (Int(header[0]) << 24) | (Int(header[1]) << 16)
                | (Int(header[2]) << 8)  |  Int(header[3])
        guard len >= 0, len <= maxLen else { throw PolarError.frameTooLarge(len) }
        return try await receiveExact(len)
    }
}

/// Guards a CheckedContinuation against double-resume across NWConnection callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<Void, Error>
    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
    func success() {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; cont.resume()
    }
    func failure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; cont.resume(throwing: error)
    }
}
