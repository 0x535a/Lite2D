import Foundation

struct CompanionMonitorQuery: Codable, Equatable {
    var section = "overview"
    var owner = ""
    var search = ""
    var status = ""
    var memoryType = ""
    var source = ""
    var validity = ""
    var from = ""
    var to = ""
    var sort = "newest"
    var page = 0
    var pageSize = 30
    var detailID = ""
    var detailKind = ""
    var detailOwner = ""
}
struct CompanionMonitorField: Codable, Identifiable {
    var key: String
    var value: String
    var id: String { key }
}
struct CompanionMonitorLink: Codable, Identifiable {
    var id: String
    var kind = "reference"
}
struct CompanionMonitorItem: Codable, Identifiable {
    var id: String
    var kind: String
    var owner: String
    var title: String
    var content = ""
    var status = ""
    var source = ""
    var memoryType = ""
    var at = ""
    var version = ""
    var fields: [CompanionMonitorField] = []
    var links: [CompanionMonitorLink] = []
    var actions: [String] = []
    var key: String { kind + ":" + id }
}
struct CompanionMonitorMetric: Codable, Identifiable {
    var owner: String
    var key: String
    var count: Int
    var id: String { owner + ":" + key }
}
struct CompanionMonitorPage: Codable {
    var requestID: String
    var query: CompanionMonitorQuery
    var items: [CompanionMonitorItem]
    var metrics: [CompanionMonitorMetric] = []
    var total: Int
    var detail: CompanionMonitorItem?
    var at = NativeCompanionData.iso()
}
struct CompanionMonitorAction: Codable {
    var operation: String
    var owner: String
    var kind: String
    var target: String
    var content = ""
    var reason = ""
}
struct CompanionMonitorPlan: Codable, Identifiable {
    var id: String
    var action: CompanionMonitorAction
    var before: String
    var after: String
    var affected: [CompanionMonitorLink]
    var expiresAt: String
}
struct CompanionMonitorOutcome: Codable {
    var requestID: String
    var operation: String
    var owner: String
    var target: String
    var result: String
}

enum CompanionMonitorCoding {
    static func object<T: Encodable>(_ value: T) throws -> CompanionObject {
        NativeCompanionData.object(try NativeCompanionData.decode(JSONEncoder().encode(value)))
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: CompanionObject) throws -> T {
        try JSONDecoder().decode(type, from: NativeCompanionData.json(value))
    }
}
