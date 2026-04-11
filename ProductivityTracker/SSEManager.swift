import Foundation
import Combine

final class SSEManager: NSObject, ObservableObject {
    static let shared = SSEManager()

    @Published var isConnected: Bool = false

    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var buffer: String = ""
    private var retryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 60.0
    private var pendingReconnect: DispatchWorkItem?

    private override init() {
        super.init()
    }

    func connect() {
        guard task == nil, AuthManager.shared.isLoggedIn else { return }

        // APIConfig.baseURL already includes "/api", so path is just "/events/stream"
        guard let url = URL(string: "\(APIConfig.baseURL)/events/stream") else {
            print("[SSE] Invalid URL")
            return
        }

        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = .infinity

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true

        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = newSession
        task = newSession.dataTask(with: request)
        task?.resume()

        print("[SSE] Connecting to \(url.absoluteString)")
    }

    func disconnect() {
        pendingReconnect?.cancel()
        pendingReconnect = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer = ""
        DispatchQueue.main.async { self.isConnected = false }
        print("[SSE] Disconnected")
    }

    // MARK: - Stream parsing

    fileprivate func handleData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text

        while let range = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            processEvent(eventBlock)
        }
    }

    private func processEvent(_ block: String) {
        var eventType = ""
        var isComment = false

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(":") {
                isComment = true
                continue
            }
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            }
            // data: lines are parsed but the payload is ignored — SSE events are nudges,
            // the sync managers re-fetch through normal API calls.
        }

        if isComment && eventType.isEmpty { return }
        guard !eventType.isEmpty else { return }

        print("[SSE] Received event: \(eventType)")

        DispatchQueue.main.async {
            switch eventType {
            case "connected":
                self.isConnected = true
                self.retryDelay = 1.0
                print("[SSE] Connected successfully")
            case "blocklist_updated":
                BlocklistSyncManager.shared.syncNow()
            case "alert_updated":
                AlertManager.shared.fetchRules()
            case "category_updated":
                CategoryRuleSyncManager.shared.performSync()
            case "accountability_changed":
                AccountabilityManager.shared.checkStatus()
            default:
                print("[SSE] Unknown event type: \(eventType)")
            }
        }
    }

    // MARK: - Disconnect + reconnect

    fileprivate func handleDisconnect(error: Error?) {
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer = ""
        DispatchQueue.main.async { self.isConnected = false }

        if let error = error {
            print("[SSE] Connection error: \(error.localizedDescription)")
        }

        guard AuthManager.shared.isLoggedIn else { return }

        let delay = retryDelay
        retryDelay = min(retryDelay * 2, maxRetryDelay)

        print("[SSE] Reconnecting in \(Int(delay))s...")
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        pendingReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - URLSessionDataDelegate

extension SSEManager: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 200 {
                completionHandler(.allow)
            } else {
                print("[SSE] Server returned status \(http.statusCode)")
                completionHandler(.cancel)
                handleDisconnect(error: nil)
            }
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Don't reconnect if the task was explicitly cancelled (disconnect() path)
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }
        handleDisconnect(error: error)
    }
}
