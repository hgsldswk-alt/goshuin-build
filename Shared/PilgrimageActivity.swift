import ActivityKit
import Foundation

struct PilgrimageActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var visited: Int
        var total: Int
    }

    var routeID: UUID
}
