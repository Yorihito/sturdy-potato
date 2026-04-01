import Foundation

struct Profile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var mappings: [String: String]   // bundleID -> deviceUID ("system-default" for default)

    init(id: UUID = UUID(), name: String, mappings: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.mappings = mappings
    }
}
