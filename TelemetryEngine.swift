import Cocoa
import Foundation

final class TelemetryEngine {
    static let shared = TelemetryEngine()
    private let lock = NSLock()
    private var running = false

    private var prevIface: [String: (Int64, Int64, Int64, Int64)] = [:]
    private var prevApps: [String: (Int64, Int64)] = [:]
    private var prevTime: TimeInterval = Date().timeIntervalSince1970
    private var tickCount: Int = 0

    var ifaceLabels: [String: String] = [
        "lo0": "Loopback (Local)",
        "awdl0": "Apple Wireless Direct",
        "llw0": "Low Latency WLAN",
        "bridge0": "Thunderbolt Bridge"
    ]

    var liveSpeedIn: Double = 0
    var liveSpeedOut: Double = 0
    var peakSpeedIn: Double = 0
    var peakSpeedOut: Double = 0
    var liveInterfaces: [InterfaceRow] = []
    var liveApps: [AppRow] = []
    var realtimeHistory: [RealtimePoint] = []
    var diagnostics = DiagnosticsInfo()
    var geoCache: [String: String] = [:]

    private let friendlyAppMap: [String: String] = [
        "Google Chrome H": "Google Chrome",
        "Google Chrome": "Google Chrome",
        "com.apple.WebKi": "Safari / WebKit",
        "Safari": "Safari",
        "MSTeams": "Microsoft Teams",
        "Microsoft Teams": "Microsoft Teams",
        "Windows App": "Windows App (RDP)",
        "mDNSResponder": "macOS Bonjour / DNS",
        "cloudd": "iCloud Sync",
        "nsurlsessiond": "macOS Background Transfer",
        "apsd": "Apple Push Service",
        "identityservice": "Apple Identity Service",
        "Mail": "Apple Mail",
        "Code Helper": "VS Code",
        "Cursor Helper": "Cursor"
    ]

    private init() {
        diagnostics.db_path = SQLiteManager.shared.dbPath
        discoverHardwarePorts()
    }

    func start() {
        guard !running else { return }
        running = true
        prevIface = readNetstat()
        prevApps = readNettop()
        prevTime = Date().timeIntervalSince1970

        // Pre-fill 120 seconds of timeline slots so the real-time chart immediately spans the full 2-minute axis
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        var initialPoints: [RealtimePoint] = []
        for i in stride(from: 119, through: 0, by: -1) {
            let t = now.addingTimeInterval(TimeInterval(-i))
            initialPoints.append(RealtimePoint(
                timestamp: Int64(t.timeIntervalSince1970),
                time_str: timeFmt.string(from: t),
                speed_in: 0,
                speed_out: 0
            ))
        }
        lock.lock()
        realtimeHistory = initialPoints
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.collectorLoop()
        }
        Thread.detachNewThread { [weak self] in
            self?.diagnosticsLoop()
        }
    }

    private func runCommand(_ launchPath: String, _ args: [String], timeout: TimeInterval = 3.0) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func discoverHardwarePorts() {
        let out = runCommand("/usr/sbin/networksetup", ["-listallhardwareports"])
        var currentPort: String?
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentPort = trimmed.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:"), let port = currentPort {
                let dev = trimmed.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                ifaceLabels[dev] = port
                currentPort = nil
            }
        }
    }

    func labelForInterface(_ iface: String) -> String {
        if let name = ifaceLabels[iface] {
            return "\(name) (\(iface))"
        }
        if iface.hasPrefix("utun") {
            return "VPN / Tunnel (\(iface))"
        }
        if iface.hasPrefix("en") {
            return "Network Adapter (\(iface))"
        }
        return iface
    }

    private func normalizeAppName(_ rawProc: String) -> (name: String, pid: Int) {
        var pid = 0
        var base = rawProc.trimmingCharacters(in: .whitespaces)
        if let dotRange = base.range(of: ".", options: .backwards) {
            let pidStr = String(base[dotRange.upperBound...])
            if let p = Int(pidStr) {
                pid = p
                base = String(base[..<dotRange.lowerBound])
            }
        }
        if base.isEmpty { return ("System", pid) }
        for (prefix, friendly) in friendlyAppMap {
            if base.hasPrefix(prefix) {
                return (friendly, pid)
            }
        }
        if let r = base.range(of: " Helper") {
            base = String(base[..<r.lowerBound])
        }
        return (base, pid)
    }

    var isMainWindowVisible: Bool = true
    private var lastAppSampleTime: TimeInterval = Date().timeIntervalSince1970

    private func readNetstat() -> [String: (Int64, Int64, Int64, Int64)] {
        var res: [String: (Int64, Int64, Int64, Int64)] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return res }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let addr = current.pointee
            if let sa = addr.ifa_addr, Int32(sa.pointee.sa_family) == AF_LINK, let dataPtr = addr.ifa_data {
                let name = String(cString: addr.ifa_name)
                let ifData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                let ibytes = Int64(ifData.ifi_ibytes)
                let obytes = Int64(ifData.ifi_obytes)
                let ipkts = Int64(ifData.ifi_ipackets)
                let opkts = Int64(ifData.ifi_opackets)

                if let existing = res[name] {
                    if (ibytes + obytes) > (existing.0 + existing.1) {
                        res[name] = (ibytes, obytes, ipkts, opkts)
                    }
                } else {
                    res[name] = (ibytes, obytes, ipkts, opkts)
                }
            }
            ptr = addr.ifa_next
        }
        return res
    }

    private func readNettop() -> [String: (Int64, Int64)] {
        var res: [String: (Int64, Int64)] = [:]
        let out = runCommand("/usr/bin/nettop", ["-n", "-P", "-L", "1", "-J", "bytes_in,bytes_out"])
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(",bytes_in") || trimmed.hasPrefix("time") { continue }
            let parts = trimmed.split(separator: ",", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count < 3 { continue }
            let procId = parts[0]
            if let bi = Int64(parts[1]), let bo = Int64(parts[2]) {
                res[procId] = (bi, bo)
            }
        }
        return res
    }

    private func collectorLoop() {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        lastAppSampleTime = Date().timeIntervalSince1970

        while running {
            Thread.sleep(forTimeInterval: 1.0)
            let now = Date()
            let nowTs = now.timeIntervalSince1970
            let dt = max(0.2, nowTs - prevTime)
            prevTime = nowTs
            tickCount += 1

            let currIface = readNetstat()
            // Eco-Smart polling: every 3s when window is open, every 15s when closed in Menu Bar
            let appInterval = isMainWindowVisible ? 3 : 15
            let updateApps = (tickCount % appInterval == 0) || prevApps.isEmpty
            let currApps = updateApps ? readNettop() : prevApps

            var ifaceDeltas: [String: (Int64, Int64, Int64, Int64)] = [:]
            var totalDeltaIn: Int64 = 0
            var totalDeltaOut: Int64 = 0
            var newIfaces: [InterfaceRow] = []
            var vpnActive = false

            for (iface, (bi, bo, pi, po)) in currIface {
                let prev = prevIface[iface] ?? (bi, bo, pi, po)
                var dBi = max(0, bi - prev.0)
                var dBo = max(0, bo - prev.1)
                let dPi = max(0, pi - prev.2)
                let dPo = max(0, po - prev.3)

                if dBi > 10 * 1024 * 1024 * 1024 || dBo > 10 * 1024 * 1024 * 1024 {
                    dBi = 0; dBo = 0
                }
                ifaceDeltas[iface] = (dBi, dBo, dPi, dPo)

                if iface != "lo0" {
                    totalDeltaIn += dBi
                    totalDeltaOut += dBo
                }
                if iface.hasPrefix("utun") && (dBi + dBo) > 0 {
                    vpnActive = true
                }

                let spdIn = Double(dBi) / dt
                let spdOut = Double(dBo) / dt
                if (bi + bo) > 0 {
                    newIfaces.append(InterfaceRow(
                        interface: iface,
                        label: labelForInterface(iface),
                        speed_in: spdIn,
                        speed_out: spdOut,
                        boot_bytes_in: bi,
                        boot_bytes_out: bo,
                        boot_total: bi + bo,
                        is_loopback: iface == "lo0"
                    ))
                }
            }
            prevIface = currIface
            newIfaces.sort {
                if $0.is_loopback != $1.is_loopback { return !$0.is_loopback }
                let s0 = $0.speed_in + $0.speed_out
                let s1 = $1.speed_in + $1.speed_out
                if abs(s0 - s1) > 1 { return s0 > s1 }
                return $0.boot_total > $1.boot_total
            }

            var appDeltasGrouped: [String: (Int64, Int64)] = [:]
            if updateApps {
                let appDt = max(0.5, nowTs - lastAppSampleTime)
                lastAppSampleTime = nowTs
                var appMap: [String: AppRow] = [:]

                for (rawProc, (bi, bo)) in currApps {
                    var dBi: Int64 = 0
                    var dBo: Int64 = 0
                    if let p = prevApps[rawProc] {
                        dBi = max(0, bi - p.0)
                        dBo = max(0, bo - p.1)
                    }
                    if dBi > 10 * 1024 * 1024 * 1024 || dBo > 10 * 1024 * 1024 * 1024 {
                        dBi = 0; dBo = 0
                    }

                    let (appName, pid) = normalizeAppName(rawProc)
                    let prevG = appDeltasGrouped[appName] ?? (0, 0)
                    appDeltasGrouped[appName] = (prevG.0 + dBi, prevG.1 + dBo)

                    var row = appMap[appName] ?? AppRow(app_name: appName)
                    row.speed_in += Double(dBi) / appDt
                    row.speed_out += Double(dBo) / appDt
                    row.bytes_in += bi
                    row.bytes_out += bo
                    row.total += (bi + bo)
                    if pid > 0 { row.pids.append(pid) }
                    appMap[appName] = row
                }
                prevApps = currApps

                let sortedApps = appMap.values.sorted {
                    let s0 = $0.speed_in + $0.speed_out
                    let s1 = $1.speed_in + $1.speed_out
                    if abs(s0 - s1) > 10 { return s0 > s1 }
                    return $0.total > $1.total
                }
                lock.lock()
                liveApps = Array(sortedApps.prefix(40))
                lock.unlock()
            }

            let spdIn = Double(totalDeltaIn) / dt
            let spdOut = Double(totalDeltaOut) / dt

            lock.lock()
            liveSpeedIn = spdIn
            liveSpeedOut = spdOut
            if spdIn > peakSpeedIn { peakSpeedIn = spdIn }
            if spdOut > peakSpeedOut { peakSpeedOut = spdOut }
            liveInterfaces = newIfaces
            if vpnActive { diagnostics.vpn_active = true }

            realtimeHistory.append(RealtimePoint(
                timestamp: Int64(nowTs),
                time_str: timeFmt.string(from: now),
                speed_in: spdIn,
                speed_out: spdOut
            ))
            if realtimeHistory.count > 120 {
                realtimeHistory.removeFirst(realtimeHistory.count - 120)
            }
            let currentProfile = diagnostics.network_profile
            diagnostics.db_size_kb = SQLiteManager.shared.getDatabaseFileSizeKB()
            lock.unlock()

            let hour = Calendar.current.component(.hour, from: now)
            SQLiteManager.shared.recordDelta(
                dateStr: dateFmt.string(from: now),
                hour: hour,
                profile: currentProfile,
                ifaceDeltas: ifaceDeltas,
                appDeltas: appDeltasGrouped,
                totalIn: totalDeltaIn,
                totalOut: totalDeltaOut
            )
        }
    }

    // MARK: - Network Diagnostics, Ping, Public IP & Geo Lookup
    private func diagnosticsLoop() {
        var cycle = 0
        while running {
            if isMainWindowVisible || cycle % 4 == 0 {
                updateLocalNetworkInfo()
                updatePingMetrics()
            }
            if cycle % 15 == 0 {
                updatePublicIPInfo()
            }
            cycle += 1
            Thread.sleep(forTimeInterval: isMainWindowVisible ? 6.0 : 15.0)
        }
    }

    private func updateLocalNetworkInfo() {
        let info = runCommand("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"])
        var ip = "—"
        var router = "—"
        for line in info.components(separatedBy: .newlines) {
            if line.hasPrefix("IP address:") {
                ip = line.replacingOccurrences(of: "IP address:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Router:") {
                router = line.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        let airport = runCommand("/usr/sbin/networksetup", ["-getairportnetwork", "en0"])
        var profile = "Wi-Fi (en0)"
        if airport.contains("Current Wi-Fi Network:") {
            let ssid = airport.replacingOccurrences(of: "Current Wi-Fi Network:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !ssid.isEmpty { profile = ssid }
        }

        lock.lock()
        diagnostics.local_ip = ip
        diagnostics.router_ip = router
        diagnostics.network_profile = profile
        lock.unlock()
    }

    private func parsePingMs(_ output: String) -> Double {
        if let range = output.range(of: "time=") {
            let sub = output[range.upperBound...]
            let numStr = sub.prefix(while: { $0.isNumber || $0 == "." })
            if let val = Double(numStr) { return val }
        }
        return -1
    }

    private func updatePingMetrics() {
        lock.lock()
        let router = diagnostics.router_ip
        lock.unlock()

        var routerMs: Double = -1
        if router != "—" && !router.isEmpty && router != "none" {
            let outR = runCommand("/sbin/ping", ["-c", "1", "-t", "1", router])
            routerMs = parsePingMs(outR)
        }
        let outI = runCommand("/sbin/ping", ["-c", "1", "-t", "1", "1.1.1.1"])
        let internetMs = parsePingMs(outI)

        lock.lock()
        diagnostics.ping_router_ms = routerMs
        diagnostics.ping_internet_ms = internetMs
        lock.unlock()
    }

    private func updatePublicIPInfo() {
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,country,city,isp,org,query") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self, let data = data, err == nil else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let query = json["query"] as? String {
                let isp = (json["isp"] as? String) ?? (json["org"] as? String) ?? "—"
                let city = (json["city"] as? String) ?? ""
                let country = (json["country"] as? String) ?? ""
                let loc = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")

                self.lock.lock()
                self.diagnostics.public_ip = query
                self.diagnostics.isp_org = isp
                self.diagnostics.country_city = loc.isEmpty ? "—" : loc
                self.lock.unlock()
            }
        }.resume()
    }

    // MARK: - Built-in Speedtest (Cloudflare 10MB test payload)
    func runSpeedtest() {
        lock.lock()
        if diagnostics.speedtest_running {
            lock.unlock()
            return
        }
        diagnostics.speedtest_running = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            let start = Date().timeIntervalSince1970
            let out = self.runCommand("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{size_download}", "--max-time", "8", "https://speed.cloudflare.com/__down?bytes=15000000"])
            let elapsed = max(0.1, Date().timeIntervalSince1970 - start)
            let bytes = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let mbps = (bytes * 8.0) / (elapsed * 1_000_000.0)

            self.lock.lock()
            if mbps > 0.1 {
                self.diagnostics.speedtest_down_mbps = round(mbps * 10) / 10
            }
            self.diagnostics.speedtest_running = false
            self.lock.unlock()
        }
    }

    // MARK: - Active Connections + Geo/Org Resolution + Process Termination
    func getActiveConnections(limit: Int = 35) -> [ConnectionRow] {
        let out = runCommand("/usr/sbin/lsof", ["-i", "-n", "-P"])
        var conns: [ConnectionRow] = []
        var seen = Set<String>()

        for line in out.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count < 9 { continue }
            let cmd = parts[0].replacingOccurrences(of: "\\x20", with: " ")
            let pid = parts[1]
            let proto = parts[7]
            let name = parts[8]
            let state = parts.count > 9 ? parts[9].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") : "ACTIVE"

            let key = "\(cmd)|\(proto)|\(name)|\(state)"
            if seen.contains(key) { continue }
            seen.insert(key)

            var localAddr = name
            var remoteAddr = "—"
            var remoteIP = ""
            if let arrowRange = name.range(of: "->") {
                localAddr = String(name[..<arrowRange.lowerBound])
                remoteAddr = String(name[arrowRange.upperBound...])
                if let colonRange = remoteAddr.range(of: ":", options: .backwards) {
                    remoteIP = String(remoteAddr[..<colonRange.lowerBound]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                }
            }

            let geo = resolveGeoOrg(for: remoteIP)
            conns.append(ConnectionRow(
                command: cmd,
                pid: pid,
                proto: proto,
                local_addr: localAddr,
                remote_addr: remoteAddr,
                remote_ip: remoteIP,
                state: state,
                geo_org: geo
            ))
            if conns.count >= limit { break }
        }
        return conns
    }

    private func resolveGeoOrg(for ip: String) -> String {
        if ip.isEmpty || ip == "*" || ip.hasPrefix("127.") || ip.hasPrefix("fe80:") || ip.hasPrefix("::1") {
            return "Local Loopback (macOS)"
        }
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.16.") {
            return "Local Network (LAN)"
        }
        lock.lock()
        if let cached = geoCache[ip] {
            lock.unlock()
            return cached
        }
        geoCache[ip] = "Resolving..."
        lock.unlock()

        if let url = URL(string: "http://ip-api.com/json/\(ip)?fields=countryCode,org,isp") {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let cc = (json["countryCode"] as? String) ?? ""
                let org = (json["org"] as? String) ?? (json["isp"] as? String) ?? "External Host"
                let label = cc.isEmpty ? org : "[\(cc)] \(org)"
                self.lock.lock()
                self.geoCache[ip] = label
                self.lock.unlock()
            }.resume()
        }
        return "External Node"
    }

    func terminateAppByName(_ appName: String) -> Bool {
        lock.lock()
        let match = liveApps.first(where: { $0.app_name == appName })
        lock.unlock()
        guard let pids = match?.pids, !pids.isEmpty else { return false }
        for pid in pids {
            kill(pid_t(pid), SIGTERM)
        }
        return true
    }

    // MARK: - Launch at Login (macOS LaunchAgent with KeepAlive)
    func setLaunchAtLogin(enabled: Bool, appBundlePath: String) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        let plistURL = launchAgentsDir.appendingPathComponent("com.maros.netpulse.plist")

        if enabled {
            let execPath = (appBundlePath as NSString).appendingPathComponent("Contents/MacOS/NetPulse")
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.maros.netpulse</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                    <string>--background</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                </dict>
            </dict>
            </plist>
            """
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
        SQLiteManager.shared.updateSettings(["launch_at_login": enabled ? "1" : "0"])
    }
}
