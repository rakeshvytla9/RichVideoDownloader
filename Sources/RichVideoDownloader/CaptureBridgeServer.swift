import Foundation
import Network

struct CapturedRequestPayload: Decodable {
    let mediaURL: String
    let pageURL: String?
    let tabTitle: String?
    let resourceType: String?
    let captureSource: String?
    let fileName: String?
    let mimeType: String?
    let cookieHeader: String?
    let userAgent: String?
    let timestamp: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case mediaURL = "mediaUrl"
        case pageURL = "pageUrl"
        case tabTitle
        case resourceType
        case captureSource
        case fileName
        case mimeType
        case cookieHeader
        case userAgent
        case timestamp
    }
}

struct CapturedMediaItem: Identifiable, Hashable {
    let id: UUID
    let mediaURL: String
    let pageURL: String?
    let tabTitle: String?
    let resourceType: String?
    let captureSource: String?
    let fileName: String?
    let mimeType: String?
    let cookieHeader: String?
    let userAgent: String?
    let capturedAt: Date
}

struct TelegramDownloadCommand: Encodable {
    let action: String = "download"
    let url: String
    let id: String
}

final class CaptureBridgeServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "RichVideoDownloader.CaptureBridge", qos: .utility)
    private var listener: NWListener?

    var onStatus: ((String) -> Void)?
    var onCapture: ((CapturedRequestPayload) -> Void)?
    
    var onExtensionProgress: ((String, Double) -> Void)?
    var onExtensionFinish: ((String) -> Void)?
    var onExtensionError: ((String, String) -> Void)?

    private var pendingCommands: [TelegramDownloadCommand] = []
    private var activePollConnections: [NWConnection] = []
    private var activeHandles: [String: FileHandle] = [:]

    init(port: UInt16 = 38123) {
        self.port = port
    }

    func start() {
        guard listener == nil else {
            onStatus?("Running on http://127.0.0.1:\(port)")
            return
        }

        do {
            let parameters = NWParameters.tcp
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus?("Running on http://127.0.0.1:\(self?.port ?? 0)")
                case let .failed(error):
                    self?.onStatus?("Bridge failed: \(error.localizedDescription)")
                case .cancelled:
                    self?.onStatus?("Bridge stopped")
                default:
                    break
                }
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onStatus?("Bridge failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for handle in activeHandles.values {
            try? handle.close()
        }
    }

    func sendTelegramCommand(url: String, id: String, savePath: String) {
        let cmd = TelegramDownloadCommand(url: url, id: id)
        queue.async {
            print("[Bridge] Initiating telegram download command for ID: \(id)")
            let fileURL = URL(fileURLWithPath: savePath)
            try? FileManager.default.removeItem(at: fileURL)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                self.activeHandles[id] = handle
                print("[Bridge] Opened file handle for ID: \(id)")
            } else {
                print("[Bridge] CRITICAL: Failed to open file handle for ID: \(id) at \(fileURL.path)")
            }
            
            if let conn = self.activePollConnections.popLast() {
                if let data = try? JSONEncoder().encode(cmd) {
                    print("[Bridge] Responding to active poll with download command")
                    let response = Self.httpResponse(statusCode: 200, bodyData: data)
                    conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
                }
            } else {
                print("[Bridge] No active poll, queueing command")
                self.pendingCommands.insert(cmd, at: 0)
            }
        }
    }
    
    func cancelTelegramDownload(id: String) {
        queue.async {
            if let handle = self.activeHandles.removeValue(forKey: id) {
                try? handle.close()
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveFullHTTPMessage(connection: connection, buffer: Data())
    }

    private func receiveFullHTTPMessage(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 10 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            var newBuffer = buffer
            if let data = data {
                newBuffer.append(data)
            }

            if let (headerString, headerEndIndex) = self.parseHeaderEnd(data: newBuffer) {
                let contentLength = self.parseContentLength(header: headerString)
                let headersLength = headerEndIndex
                let totalExpected = headersLength + contentLength
                
                if newBuffer.count >= totalExpected {
                    let bodyData = newBuffer.subdata(in: headersLength..<totalExpected)
                    self.processRequest(connection: connection, header: headerString, body: bodyData)
                    return
                }
            }
            
            if error == nil && newBuffer.count < 50 * 1024 * 1024 {
                self.receiveFullHTTPMessage(connection: connection, buffer: newBuffer)
            } else {
                connection.cancel()
            }
        }
    }
    
    private func parseHeaderEnd(data: Data) -> (String, Int)? {
        if let range = data.firstRange(of: Data("\r\n\r\n".utf8)) {
            let headerData = data.subdata(in: 0..<range.upperBound)
            if let headerString = String(data: headerData, encoding: .utf8) {
                return (headerString, range.upperBound)
            }
        }
        return nil
    }
    
    private func parseContentLength(header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst(15).trimmingCharacters(in: .whitespaces)
                let components = val.components(separatedBy: ";")
                if let intString = components.first, let size = Int(intString) {
                    return size
                }
            }
        }
        return 0
    }

    private func processRequest(connection: NWConnection, header: String, body: Data) {
        let lines = header.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }
        
        let proxyPrefix = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 2\r\n\r\nOK"
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = parts[0]
        let path = parts[1]
        
        print("[Bridge] Received \(method) \(path)")
        
        if method == "OPTIONS" {
            let optionsRes = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n\r\n"
            connection.send(content: optionsRes.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        
        let urlParts = path.components(separatedBy: "?")
        let route = urlParts[0]
        var queries: [String: String] = [:]
        if urlParts.count > 1 {
            for kv in urlParts[1].components(separatedBy: "&") {
                let pair = kv.components(separatedBy: "=")
                if pair.count == 2 { queries[pair[0]] = pair[1] }
            }
        }

        if route == "/poll" {
            if let cmd = pendingCommands.popLast(), let data = try? JSONEncoder().encode(cmd) {
                print("[Bridge] Found pending command, responding to poll")
                let res = Self.httpResponse(statusCode: 200, contentType: "application/json", bodyData: data)
                connection.send(content: res, completion: .contentProcessed { _ in connection.cancel() })
            } else {
                activePollConnections.append(connection)
            }
            return
        }
        
        if route == "/chunk", let id = queries["id"] {
            if let handle = activeHandles[id] {
                if let offsetStr = queries["offset"], let offset = UInt64(offsetStr) {
                    if #available(macOS 10.15.4, *) {
                        try? handle.seek(toOffset: offset)
                    } else {
                        handle.seek(toFileOffset: offset)
                    }
                } else {
                    // Fallback to end
                    if #available(macOS 10.15.4, *) {
                        _ = try? handle.seekToEnd()
                    } else {
                        handle.seekToEndOfFile()
                    }
                }
                handle.write(body)
            }
            connection.send(content: proxyPrefix.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        
        if route == "/progress", let id = queries["id"], let progStr = queries["p"], let prog = Double(progStr) {
            DispatchQueue.main.async { self.onExtensionProgress?(id, prog) }
            connection.send(content: proxyPrefix.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        
        if route == "/finish", let id = queries["id"] {
            if let handle = activeHandles.removeValue(forKey: id) {
                try? handle.close()
            }
            DispatchQueue.main.async { self.onExtensionFinish?(id) }
            connection.send(content: proxyPrefix.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        
        if route == "/relay_log" {
            if let msg = String(data: body, encoding: .utf8) {
                print("\(msg)")
            }
            connection.send(content: proxyPrefix.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        
        if route == "/error", let id = queries["id"] {
            let msg = String(data: body, encoding: .utf8) ?? "Unknown"
            print("[Bridge] ERROR received from extension for \(id): \(msg)")
            if let handle = activeHandles.removeValue(forKey: id) {
                try? handle.close()
            }
            DispatchQueue.main.async { self.onExtensionError?(id, msg) }
            connection.send(content: proxyPrefix.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        if route == "/capture" || path == "/capture" {
            print("[Bridge] Captured payload received: \(body.count) bytes")
            if let payload = try? JSONDecoder().decode(CapturedRequestPayload.self, from: body) {
                print("[Bridge] Decoded URL: \(payload.mediaURL)")
                DispatchQueue.main.async { self.onCapture?(payload) }
                connection.send(content: proxyPrefix.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                print("[Bridge] Failed to decode CapturedRequestPayload")
                connection.send(content: "HTTP/1.1 400 Bad\r\nConnection: close\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }
        
        connection.send(content: "HTTP/1.1 404 Route\r\nConnection: close\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func httpResponse(statusCode: Int, contentType: String = "text/plain", bodyData: Data) -> Data {
        let headers = """
        HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Status")\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r\n
        """
        var data = headers.data(using: .utf8)!
        data.append(bodyData)
        return data
    }
}
