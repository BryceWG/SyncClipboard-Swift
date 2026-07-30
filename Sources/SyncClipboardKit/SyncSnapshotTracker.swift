import Foundation

public struct SyncSnapshotTracker: Sendable {
    private var lastLocalFingerprint: String?
    private var lastAppliedRemoteFingerprint: String?
    private var suppressedFingerprint: String?

    public init() {}

    public mutating func shouldUpload(_ snapshot: ClipboardSnapshot) -> Bool {
        let fingerprint = snapshot.fingerprint

        defer { lastLocalFingerprint = fingerprint }

        if suppressedFingerprint == fingerprint {
            suppressedFingerprint = nil
            return false
        }
        if lastAppliedRemoteFingerprint == fingerprint {
            return false
        }
        if lastLocalFingerprint == fingerprint {
            return false
        }

        return true
    }

    public mutating func shouldFetchRemote(fingerprint: String) -> Bool {
        if lastAppliedRemoteFingerprint == fingerprint {
            return false
        }
        if lastLocalFingerprint == fingerprint {
            return false
        }

        return true
    }

    public mutating func markUploaded(_ snapshot: ClipboardSnapshot) {
        lastLocalFingerprint = snapshot.fingerprint
    }

    public mutating func shouldApplyRemote(_ snapshot: ClipboardSnapshot) -> Bool {
        let fingerprint = snapshot.fingerprint

        if lastAppliedRemoteFingerprint == fingerprint {
            return false
        }
        if lastLocalFingerprint == fingerprint {
            return false
        }

        return true
    }

    public mutating func markAppliedRemote(_ snapshot: ClipboardSnapshot) {
        let fingerprint = snapshot.fingerprint
        lastAppliedRemoteFingerprint = fingerprint
        lastLocalFingerprint = fingerprint
        suppressedFingerprint = fingerprint
    }

    /// Records a remote fingerprint as handled without applying it to the
    /// pasteboard, used by binary auto-pull where no text snapshot exists.
    public mutating func markHandledRemote(fingerprint: String) {
        lastAppliedRemoteFingerprint = fingerprint
    }
}
