import Foundation

public struct SyncSnapshotTracker: Sendable {
    private var lastLocal: ClipboardSnapshot?
    private var lastRemote: ClipboardSnapshot?
    private var lastAppliedRemote: ClipboardSnapshot?
    private var suppressedFingerprint: String?

    public init() {}

    public mutating func shouldUpload(_ snapshot: ClipboardSnapshot) -> Bool {
        defer { lastLocal = snapshot }

        if suppressedFingerprint == snapshot.fingerprint {
            suppressedFingerprint = nil
            return false
        }
        if lastAppliedRemote == snapshot {
            return false
        }
        if lastRemote == snapshot {
            return false
        }
        if lastLocal == snapshot {
            return false
        }

        return true
    }

    public mutating func markUploaded(_ snapshot: ClipboardSnapshot) {
        lastLocal = snapshot
        lastRemote = snapshot
    }

    public mutating func shouldApplyRemote(_ snapshot: ClipboardSnapshot) -> Bool {
        lastRemote = snapshot

        if lastAppliedRemote == snapshot {
            return false
        }
        if lastLocal == snapshot {
            return false
        }

        return true
    }

    public mutating func markAppliedRemote(_ snapshot: ClipboardSnapshot) {
        lastAppliedRemote = snapshot
        lastLocal = snapshot
        lastRemote = snapshot
        suppressedFingerprint = snapshot.fingerprint
    }
}
