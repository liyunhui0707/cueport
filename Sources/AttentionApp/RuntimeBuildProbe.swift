import Foundation
import AttentionCore

enum RuntimeBuildProbe {
    static func loadedUUID() -> String? {
        MachOBuildIdentity.loadedUUID()
    }
    static func diskUUID() -> String? {
        readUUID(Bundle.main.executableURL)
    }
    static func helperDiskUUID() -> String? {
        readUUID(Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cueport"))
    }
    private static func readUUID(_ file: URL?) -> String? {
        guard let file else { return nil }
        return MachOBuildIdentity.fileUUID(file)
    }
}
