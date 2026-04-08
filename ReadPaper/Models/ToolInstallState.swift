import Foundation
import SwiftData

@Model
final class ToolInstallState {
    @Attribute(.unique) var id: UUID
    var toolName: String
    var statusRawValue: String
    var version: String?
    var executablePath: String?
    var log: String
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        toolName: String,
        status: ToolInstallStatus = .missing,
        version: String? = nil,
        executablePath: String? = nil,
        log: String = "",
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.statusRawValue = status.rawValue
        self.version = version
        self.executablePath = executablePath
        self.log = log
        self.modifiedAt = modifiedAt
    }

    var status: ToolInstallStatus {
        get { ToolInstallStatus(rawValue: statusRawValue) ?? .missing }
        set { statusRawValue = newValue.rawValue }
    }
}
