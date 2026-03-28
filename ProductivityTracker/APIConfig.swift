import Foundation

struct APIConfig {
    #if DEBUG
    static let baseURL = "http://localhost:3000/api"
    #else
    static let baseURL = "https://productivity-api.onrender.com/api"
    #endif
}
