import Foundation

public enum MeetingError: Error, Equatable {
    case micPermissionDenied
    case systemAudioPermissionDenied(status: OSStatus)
    case captureSetupFailed(String)
    case emptyRecording
    case transcriptionFailed(String)
    case mappingFailed(String)
    case sessionNotFound
    case alreadyRecording
}
