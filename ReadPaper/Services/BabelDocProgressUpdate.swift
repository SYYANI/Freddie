import Foundation

struct BabelDocProgressUpdate: Sendable, Equatable {
    var completed: Double
    var total: Double
    var summary: String
    var statusMessage: String
}
