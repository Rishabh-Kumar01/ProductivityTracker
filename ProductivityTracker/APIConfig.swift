import Foundation

struct APIConfig {
    #if DEBUG
    static let baseURL = "https://api.sam-focussync.com/api"
    #else
    static let baseURL = "https://api.sam-focussync.com/api"
    #endif
}
