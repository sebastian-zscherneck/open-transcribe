import CoreAudio
import Foundation

/// Errors raised while querying CoreAudio for the process object list.
public struct CoreAudioError: Error, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public let context: String

    public init(status: OSStatus, context: String) {
        self.status = status
        self.context = context
    }

    public var description: String { "CoreAudio error \(status) in \(context)" }
}

/// Real `AudioProcessSource` backed by `kAudioHardwarePropertyProcessObjectList`.
public struct CoreAudioProcessSource: AudioProcessSource {
    public init() {}

    public func snapshot() throws -> [AudioProcessSnapshot] {
        try CoreAudioProcessDirectory.allObjectIDs().compactMap { try? Self.snapshot(for: $0) }
    }

    private static func snapshot(for objectID: AudioObjectID) throws -> AudioProcessSnapshot {
        let bundleID = try CoreAudioProcessDirectory.bundleID(for: objectID)
        let pid = try CoreAudioProcessDirectory.pid(for: objectID)
        let isRunningInput = try CoreAudioProcessDirectory.isRunningInput(objectID)
        return AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: isRunningInput)
    }
}

/// Shared low-level CoreAudio process-object lookups, used both by detection (which needs one
/// snapshot per process) and by the process tap (which needs every process object belonging to
/// one app family, since a browser/Electron app's mic-holding helper and its audio-output
/// process are often not the same process).
enum CoreAudioProcessDirectory {
    static func allObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "ProcessObjectList size")
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        status = withUnsafeMutablePointer(to: &address) { addr in
            ids.withUnsafeMutableBufferPointer { buf in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), addr, 0, nil, &dataSize, buf.baseAddress!
                )
            }
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "ProcessObjectList data")
        }
        return ids
    }

    static func bundleID(for objectID: AudioObjectID) throws -> String {
        try string(objectID, selector: kAudioProcessPropertyBundleID)
    }

    static func pid(for objectID: AudioObjectID) throws -> pid_t {
        try pidValue(objectID, selector: kAudioProcessPropertyPID)
    }

    static func isRunningInput(_ objectID: AudioObjectID) throws -> Bool {
        try uint32Value(objectID, selector: kAudioProcessPropertyIsRunningInput) != 0
    }

    private static func uint32Value(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "property \(selector)")
        }
        return value
    }

    private static func pidValue(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "property \(selector)")
        }
        return value
    }

    private static func string(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "bundleID")
        }
        guard let cfString else { return "" }
        return cfString.takeRetainedValue() as String
    }
}
