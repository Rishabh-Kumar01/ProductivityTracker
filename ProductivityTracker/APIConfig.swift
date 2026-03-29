import Foundation

struct APIConfig {
    #if DEBUG
    static let baseURL = "https://productivitytracker-api.onrender.com/api"
    #else
    static let baseURL = "https://productivitytracker-api.onrender.com/api"
    #endif
}
