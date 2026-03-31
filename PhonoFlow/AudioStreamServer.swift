//
//  AudioStreamServer.swift
//  PhonoFlow
//

import Foundation
import Network

nonisolated final class AudioStreamServer: @unchecked Sendable {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    // High-priority queue for streaming to prevent audio dropouts
    private let queue = DispatchQueue(label: "PhonoFlow.stream", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    private var sampleRate: Double = 44100
    private(set) var port: UInt16 = 7865
    private(set) var isRunning = false
    var allowedHosts: [String] = []

    func start(port: UInt16, sampleRate: Double) throws {
        stop()
        self.port = port
        self.sampleRate = sampleRate

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CocoaError(.featureUnsupported)
        }

        let newListener = try NWListener(using: .tcp, on: nwPort)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
            case .failed, .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }
        newListener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        isRunning = false
    }

    func broadcast(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard isRunning else { return }
        let data = Data(bytes: samples, count: frameCount * 2 * MemoryLayout<Float>.size)
        queue.async { [weak self] in
            guard let self, !self.connections.isEmpty else { return }
            for (id, conn) in self.connections {
                conn.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.connections.removeValue(forKey: id)
                        conn.cancel()
                    }
                })
            }
        }
    }

    var clientCount: Int { connections.count }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        if !allowedHosts.isEmpty, !isHostAllowed(conn) {
            let body = "403 Forbidden"
            let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.start(queue: queue)
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil else {
                conn.cancel()
                return
            }

            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let isStreamRequest = requestLine.contains("GET /stream")

            if isStreamRequest {
                let response = self.wavResponseHeader()
                conn.send(content: response, completion: .contentProcessed { [weak self] error in
                    if error == nil {
                        self?.connections[ObjectIdentifier(conn)] = conn
                    } else {
                        conn.cancel()
                    }
                })
            } else {
                let ip = Self.localIPAddress() ?? "localhost"
                let html = Self.landingPageHTML(host: ip, port: self.port)
                var header = "HTTP/1.1 200 OK\r\n"
                header += "Content-Type: text/html; charset=utf-8\r\n"
                header += "Content-Length: \(html.utf8.count)\r\n"
                header += "Connection: close\r\n"
                header += "\r\n"
                let response = Data(header.utf8) + Data(html.utf8)
                conn.send(content: response, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    // MARK: - WAV stream response

    private func wavResponseHeader() -> Data {
        let sr = UInt32(sampleRate)
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 32
        let byteRate = sr * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var http = "HTTP/1.1 200 OK\r\n"
        http += "Content-Type: audio/wav\r\n"
        http += "Cache-Control: no-cache, no-store\r\n"
        http += "Connection: close\r\n"
        http += "Access-Control-Allow-Origin: *\r\n"
        http += "icy-name: PhonoFlow Radio\r\n"
        http += "\r\n"

        var d = Data(http.utf8)

        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE32(0x7FFF_FFFF)
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE32(16)
        appendLE16(3) // IEEE float
        appendLE16(channels)
        appendLE32(sr)
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(bitsPerSample)

        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE32(0x7FFF_FFFF - 36)

        return d
    }

    // MARK: - Landing page

    private static func landingPageHTML(host: String, port: UInt16) -> String {
        let streamURL = "http://\(host):\(port)/stream"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PhonoFlow Radio</title>
        <script src="https://unpkg.com/lucide@latest"></script>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{
          font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;
          background:#09090b;color:#e4e4e7;
          min-height:100vh;display:flex;align-items:center;justify-content:center;
          padding:24px;
        }
        .card{
          width:100%;max-width:440px;
        }
        .header{
          text-align:center;margin-bottom:36px;
        }
        .app-icon{
          width:56px;height:56px;border-radius:12px;
          margin:0 auto 12px;display:block;
        }
        .logo{
          font-size:22px;font-weight:700;letter-spacing:-0.3px;
          color:#fafafa;margin-bottom:6px;
        }
        .badge{
          display:inline-block;font-size:8px;font-weight:700;letter-spacing:0.5px;
          color:#fff;padding:2px 7px;border-radius:4px;
          background:linear-gradient(135deg,#7c3aed,#3b82f6);
          vertical-align:middle;margin-left:6px;position:relative;top:-1px;
        }
        .subtitle{color:#71717a;font-size:13px;font-weight:400}
        .live{
          display:inline-flex;align-items:center;gap:8px;
          padding:6px 16px;border-radius:6px;
          background:rgba(249,115,22,0.08);
          border:1px solid rgba(249,115,22,0.15);
          font-size:12px;font-weight:500;color:#f97316;
          margin-top:16px;
        }
        .live .dot{
          width:6px;height:6px;border-radius:50%;background:#f97316;
          animation:pulse 2s ease-in-out infinite;
        }
        @keyframes pulse{0%,100%{opacity:1}50%{opacity:0.3}}
        .url-block{
          display:flex;align-items:center;gap:10px;
          background:#18181b;
          border:1px solid #27272a;
          border-radius:8px;padding:10px 14px;
          margin-bottom:28px;
        }
        .url-block .icon{color:#52525b;flex-shrink:0}
        .url-block code{
          flex:1;font-family:"SF Mono",Menlo,"Fira Code",monospace;
          font-size:12px;color:#a1a1aa;word-break:break-all;
        }
        .copy-btn{
          background:#27272a;border:1px solid #3f3f46;color:#a1a1aa;
          padding:5px 10px;border-radius:5px;cursor:pointer;
          font-size:11px;font-weight:500;transition:all 0.15s;
          display:flex;align-items:center;gap:4px;
        }
        .copy-btn:hover{background:#3f3f46;color:#e4e4e7;border-color:#52525b}
        .section-label{
          font-size:11px;font-weight:600;color:#52525b;
          text-transform:uppercase;letter-spacing:0.5px;
          margin-bottom:10px;
        }
        .methods{display:flex;flex-direction:column;gap:6px;margin-bottom:28px}
        .method{
          display:flex;gap:12px;align-items:flex-start;
          padding:12px 14px;
          background:#18181b;
          border:1px solid #27272a;
          border-radius:8px;
          transition:border-color 0.15s;
        }
        .method:hover{border-color:#3f3f46}
        .method-icon{
          width:18px;height:18px;color:#52525b;flex-shrink:0;
          margin-top:1px;
        }
        .method-body{flex:1;min-width:0}
        .method-name{font-size:13px;font-weight:500;color:#d4d4d8}
        .method-desc{font-size:11px;color:#71717a;margin-top:2px;line-height:1.5}
        .method-desc code{
          background:#27272a;padding:1px 5px;
          border-radius:3px;font-size:10px;
          font-family:"SF Mono",Menlo,monospace;color:#a1a1aa;
        }
        .spec{
          display:flex;gap:16px;justify-content:center;
          padding:12px 0;border-top:1px solid #27272a;
        }
        .spec-item{
          font-size:11px;color:#52525b;
          display:flex;align-items:center;gap:5px;
        }
        .spec-item span{color:#71717a;font-weight:500}
        .footer{
          text-align:center;margin-top:20px;
          font-size:11px;color:#3f3f46;
        }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="header">
            <img class="app-icon" src="data:image/png;base64,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" alt="PhonoFlow">
            <div class="logo">PhonoFlow<span class="badge">PRO</span></div>
            <div class="subtitle">Lossless audio stream</div>
            <div class="live"><span class="dot"></span>Live now</div>
          </div>

          <div class="url-block">
            <i data-lucide="link" class="icon" style="width:14px;height:14px"></i>
            <code id="url">\(streamURL)</code>
            <button class="copy-btn" onclick="copyURL()">
              <i data-lucide="clipboard" style="width:12px;height:12px"></i>
              <span id="copy-text">Copy</span>
            </button>
          </div>

          <div class="section-label">How to listen</div>
          <div class="methods">
            <div class="method">
              <i data-lucide="play" class="method-icon"></i>
              <div class="method-body">
                <div class="method-name">VLC Player</div>
                <div class="method-desc">File &rarr; Open Network Stream &rarr; paste the URL above</div>
              </div>
            </div>
            <div class="method">
              <i data-lucide="terminal" class="method-icon"></i>
              <div class="method-body">
                <div class="method-name">Terminal</div>
                <div class="method-desc">Run <code>mpv \(streamURL)</code> or <code>ffplay \(streamURL)</code></div>
              </div>
            </div>
            <div class="method">
              <i data-lucide="radio" class="method-icon"></i>
              <div class="method-body">
                <div class="method-name">Any network player</div>
                <div class="method-desc">Open the stream URL in any app that supports WAV over HTTP</div>
              </div>
            </div>
          </div>

          <div class="spec">
            <div class="spec-item"><i data-lucide="audio-waveform" style="width:12px;height:12px"></i><span>32-bit float</span></div>
            <div class="spec-item"><i data-lucide="activity" style="width:12px;height:12px"></i><span>44.1 kHz</span></div>
            <div class="spec-item"><i data-lucide="headphones" style="width:12px;height:12px"></i><span>Stereo</span></div>
            <div class="spec-item"><i data-lucide="shield-check" style="width:12px;height:12px"></i><span>Lossless PCM</span></div>
          </div>

          <div class="footer">PhonoFlow &middot; Local network only</div>
        </div>

        <script>
        lucide.createIcons();
        function copyURL(){
          const url=document.getElementById('url').textContent;
          navigator.clipboard.writeText(url).then(()=>{
            document.getElementById('copy-text').textContent='Copied';
            setTimeout(()=>document.getElementById('copy-text').textContent='Copy',1500);
          });
        }
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Host filtering

    private func isHostAllowed(_ conn: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = conn.currentPath?.remoteEndpoint ?? conn.endpoint else {
            return false
        }
        let remoteIP: String
        switch host {
        case .ipv4(let addr):
            remoteIP = "\(addr)"
        case .ipv6(let addr):
            remoteIP = "\(addr)"
        default:
            return false
        }

        for entry in allowedHosts {
            if entry.contains("/") {
                if cidrContains(entry, ip: remoteIP) { return true }
            } else if entry == remoteIP {
                return true
            }
        }
        return false
    }

    private func cidrContains(_ cidr: String, ip: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              let netAddr = ipToUInt32(String(parts[0])),
              let ipAddr = ipToUInt32(ip) else { return false }
        let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return (netAddr & mask) == (ipAddr & mask)
    }

    private func ipToUInt32(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return nil }
        return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    }

    // MARK: - Local IP

    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            return String(cString: hostname)
        }
        return nil
    }
}
