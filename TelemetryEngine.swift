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
    struct GeoIntelEntry {
        let countryCode: String
        let countryFlag: String
        let countryName: String
        let asnIsp: String
    }

    var diagnostics = DiagnosticsInfo()
    var preferredWiFiSSIDs: [String] = []
    var geoCache: [String: String] = [:]
    var geoIntelCache: [String: GeoIntelEntry] = [:]

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

        updateLocalNetworkInfo()

        Thread.detachNewThread { [weak self] in
            self?.collectorLoop()
        }
        Thread.detachNewThread { [weak self] in
            self?.diagnosticsLoop()
        }
    }

    private func runCommand(_ launchPath: String, _ args: [String], timeout: TimeInterval = 3.0) -> String {
        return autoreleasepool {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            let pipe = Pipe()
            let readHandle = pipe.fileHandleForReading
            let writeHandle = pipe.fileHandleForWriting
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice

            do {
                try proc.run()
            } catch {
                try? readHandle.close()
                try? writeHandle.close()
                return ""
            }

            try? writeHandle.close()
            let data = readHandle.readDataToEndOfFile()
            try? readHandle.close()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private func getInterfaceIPv4(_ targetName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            if name == targetName,
               let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if !ip.isEmpty && !ip.hasPrefix("169.254.") {
                        return ip
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return nil
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
            autoreleasepool {
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
    }

    // MARK: - Network Diagnostics, Ping, Public IP & Geo Lookup
    private func diagnosticsLoop() {
        var cycle = 0
        while running {
            autoreleasepool {
                // Always check active Wi-Fi SSID so switching networks in background or foreground is immediately recorded
                updateLocalNetworkInfo()
                if isMainWindowVisible || cycle % 4 == 0 {
                    updatePingMetrics()
                }
                if cycle % 15 == 0 {
                    updatePublicIPInfo()
                }
                if cycle == 0 || cycle % 180 == 0 {
                    checkForUpdates(manual: false)
                }
                cycle += 1
            }
            Thread.sleep(forTimeInterval: isMainWindowVisible ? 5.0 : 12.0)
        }
    }

    private func updateLocalNetworkInfo() {
        let info = runCommand("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"])
        var ip = getInterfaceIPv4("en0") ?? "—"
        var router = "—"
        for line in info.components(separatedBy: .newlines) {
            if line.hasPrefix("IP address:") {
                let val = line.replacingOccurrences(of: "IP address:", with: "").trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val.lowercased() != "none" { ip = val }
            } else if line.hasPrefix("Router:") {
                let val = line.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val.lowercased() != "none" { router = val }
            }
        }

        // Parse preferred wireless networks (macOS orders this list with the currently connected / most recent SSID first)
        let prefOut = runCommand("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", "en0"])
        var prefList: [String] = []
        for line in prefOut.components(separatedBy: .newlines) {
            if line.contains("Preferred networks on") { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                prefList.append(trimmed)
            }
        }

        lock.lock()
        let fallbackPrefList = preferredWiFiSSIDs
        lock.unlock()
        if prefList.isEmpty && !fallbackPrefList.isEmpty {
            prefList = fallbackPrefList
        }

        let airport = runCommand("/usr/sbin/networksetup", ["-getairportnetwork", "en0"])
        var profile = "Wi-Fi (en0)"
        if airport.contains("Current Wi-Fi Network:") {
            let ssid = airport.replacingOccurrences(of: "Current Wi-Fi Network:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !ssid.isEmpty && ssid != "<redacted>" {
                profile = ssid
            }
        }

        // On modern macOS (Sonoma/Sequoia/26+), -getairportnetwork redacts SSID unless retrieved from preferred networks list when en0 link is active
        if profile == "Wi-Fi (en0)" {
            let wifiActive = (ip != "—" && !ip.isEmpty) || runCommand("/usr/sbin/ipconfig", ["getsummary", "en0"]).contains("LinkStatusActive : TRUE")
            if wifiActive, let currentSSID = prefList.first, !currentSSID.isEmpty {
                profile = currentSSID
            } else if !wifiActive {
                profile = "Offline"
            }
        }

        SQLiteManager.shared.attributeGenericWiFiRowsIfNeeded(activeSSID: profile)

        lock.lock()
        diagnostics.local_ip = ip
        diagnostics.router_ip = router
        diagnostics.network_profile = profile
        if !prefList.isEmpty {
            preferredWiFiSSIDs = prefList
        }
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

    private func countryName(for code: String) -> String {
        let cc = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard cc.count == 2 else { return "External" }
        return Locale(identifier: "en_US").localizedString(forRegionCode: cc) ?? cc
    }

    private func lookupCymruDNS(for ip: String) -> GeoIntelEntry? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let reversedIP = "\(parts[3]).\(parts[2]).\(parts[1]).\(parts[0])"
        let originOut = runCommand("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "\(reversedIP).origin.asn.cymru.com", "TXT"])
        let cleanOrigin = originOut.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrigin.isEmpty else { return nil }

        // Format: "15169 | 142.250.0.0/15 | US | arin | 2012-05-24"
        let fields = cleanOrigin.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3 else { return nil }
        let asn = fields[0].split(separator: " ").first.map(String.init) ?? ""
        let cc = fields[2].uppercased()
        guard !asn.isEmpty else { return nil }

        var orgName = "AS\(asn)"
        let asOut = runCommand("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "AS\(asn).asn.cymru.com", "TXT"])
        let cleanAs = asOut.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let asFields = cleanAs.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if let lastField = asFields.last, !lastField.isEmpty {
            orgName = "AS\(asn) \(lastField)"
        }

        let flag = flagEmoji(for: cc)
        let cName = countryName(for: cc)
        return GeoIntelEntry(countryCode: cc, countryFlag: flag, countryName: cName, asnIsp: orgName)
    }

    private func updatePublicIPInfo() {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }

            // Fast Step 1: Cloudflare 1.1.1.1 Anycast Trace (never rate-limited, ~9ms latency)
            let cfTrace = self.runCommand("/usr/bin/curl", ["-s", "-L", "--max-time", "3", "https://1.1.1.1/cdn-cgi/trace"])
            var detectedIP = ""
            var detectedCC = ""
            for line in cfTrace.components(separatedBy: .newlines) {
                if line.hasPrefix("ip=") {
                    detectedIP = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if line.hasPrefix("loc=") {
                    detectedCC = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if detectedIP.isEmpty {
                let awsIP = self.runCommand("/usr/bin/curl", ["-s", "-L", "--max-time", "3", "https://checkip.amazonaws.com"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !awsIP.isEmpty && !awsIP.contains("<") {
                    detectedIP = awsIP
                }
            }

            if !detectedIP.isEmpty {
                let known = self.knownIPPrefixIntel(for: detectedIP) ?? self.lookupCymruDNS(for: detectedIP)
                let cc = !detectedCC.isEmpty ? detectedCC : (known?.countryCode ?? "")
                let cName = known?.countryName ?? self.countryName(for: cc)
                let isp = known?.asnIsp ?? "Active Internet Gateway"

                self.lock.lock()
                self.diagnostics.public_ip = detectedIP
                if self.diagnostics.isp_org == "—" || self.diagnostics.isp_org.isEmpty {
                    self.diagnostics.isp_org = isp
                }
                if self.diagnostics.country_city == "—" || self.diagnostics.country_city.isEmpty {
                    self.diagnostics.country_city = cName
                }
                self.lock.unlock()
            }

            // Step 2: Enrich with city & ISP details via ip-api.com or ipwho.is if available
            let out1 = self.runCommand("/usr/bin/curl", ["-s", "-L", "--max-time", "4", "http://ip-api.com/json/?fields=status,country,countryCode,city,isp,org,as,query"])
            if let data = out1.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let query = json["query"] as? String, !query.isEmpty {
                let isp = (json["isp"] as? String) ?? (json["org"] as? String) ?? "—"
                let asStr = (json["as"] as? String) ?? ""
                let asnPrefix = asStr.split(separator: " ").first.map(String.init) ?? ""
                let fullIsp = (!asnPrefix.isEmpty && !isp.contains(asnPrefix)) ? "\(asnPrefix) · \(isp)" : isp
                let city = (json["city"] as? String) ?? ""
                let country = (json["country"] as? String) ?? ""
                let locParts = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
                let loc = locParts.isEmpty ? "—" : locParts

                self.lock.lock()
                self.diagnostics.public_ip = query
                if fullIsp != "—" { self.diagnostics.isp_org = fullIsp }
                if loc != "—" { self.diagnostics.country_city = loc }
                self.lock.unlock()
                return
            }

            // Provider 2: ipwho.is over HTTPS
            let out2 = self.runCommand("/usr/bin/curl", ["-s", "-L", "--max-time", "4", "https://ipwho.is/"])
            if let data = out2.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ip = json["ip"] as? String, !ip.isEmpty {
                let city = (json["city"] as? String) ?? ""
                let country = (json["country"] as? String) ?? ""
                var isp = "—"
                if let conn = json["connection"] as? [String: Any] {
                    let org = (conn["isp"] as? String) ?? (conn["org"] as? String) ?? "—"
                    if let asn = conn["asn"] as? Int {
                        isp = "AS\(asn) · \(org)"
                    } else {
                        isp = org
                    }
                }
                let locParts = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
                let loc = locParts.isEmpty ? "—" : locParts

                self.lock.lock()
                self.diagnostics.public_ip = ip
                if isp != "—" { self.diagnostics.isp_org = isp }
                if loc != "—" { self.diagnostics.country_city = loc }
                self.lock.unlock()
                return
            }
        }
    }

    // MARK: - Built-in Multi-CDN Live Speedtest (Google CDN + Apple CDN + Cloudflare + Interface Delta Tracking)
    func runSpeedtest() {
        lock.lock()
        if diagnostics.speedtest_running {
            lock.unlock()
            return
        }
        diagnostics.speedtest_running = true
        diagnostics.speedtest_down_mbps = 0.1
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }

            let startIface = self.readNetstat()
            let startTime = Date().timeIntervalSince1970

            // Spawn three high-speed parallel CDN download streams for up to 5.5 seconds:
            // 1) Google global CDN (dl.google.com - never blocked on campus/enterprise networks)
            // 2) Apple's official macOS networkQuality CDN (mensura.cdn-apple.com)
            // 3) Cloudflare global speedtest CDN
            let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
            var procs: [Process] = []
            let urls = [
                "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
                "https://mensura.cdn-apple.com/api/v1/gm/large",
                "https://speed.cloudflare.com/__down?bytes=40000000"
            ]

            for u in urls {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                p.arguments = ["-s", "-L", "-k", "-A", ua, "-o", "/dev/null", "--max-time", "5", u]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                procs.append(p)
            }

            var peakMbps: Double = 0.0
            var totalRxBytes: Int64 = 0

            // Sample live kernel interface counters every 0.5s during the 5-second benchmark
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.5)
                let nowIface = self.readNetstat()
                let elapsed = max(0.25, Date().timeIntervalSince1970 - startTime)
                var rxDelta: Int64 = 0
                for (ifName, stats) in nowIface where ifName != "lo0" {
                    if let prev = startIface[ifName] {
                        rxDelta += max(0, stats.0 - prev.0)
                    }
                }
                totalRxBytes = rxDelta
                let avgMbps = (Double(rxDelta) * 8.0) / (elapsed * 1_000_000.0)
                let instantMbps = (self.liveSpeedIn * 8.0) / 1_000_000.0
                let currentEst = max(avgMbps, instantMbps * 0.85)
                if currentEst > peakMbps {
                    peakMbps = currentEst
                }

                self.lock.lock()
                if currentEst > 0.1 {
                    self.diagnostics.speedtest_down_mbps = round(currentEst * 10) / 10
                }
                self.lock.unlock()

                let anyRunning = procs.contains(where: { $0.isRunning })
                if !anyRunning && elapsed >= 1.5 {
                    break
                }
            }

            for p in procs where p.isRunning {
                p.terminate()
            }

            let totalElapsed = max(0.5, Date().timeIntervalSince1970 - startTime)
            let finalAvgMbps = (Double(totalRxBytes) * 8.0) / (totalElapsed * 1_000_000.0)
            let finalResult = max(finalAvgMbps, peakMbps * 0.9)

            self.lock.lock()
            if finalResult > 0.1 {
                self.diagnostics.speedtest_down_mbps = round(finalResult * 10) / 10
            }
            self.diagnostics.speedtest_running = false
            self.lock.unlock()
        }
    }

    // MARK: - Active Connections + Geo/Org Resolution + Security Heuristics
    func getActiveConnections(limit: Int = 45) -> [ConnectionRow] {
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
            } else if let colonRange = localAddr.range(of: ":", options: .backwards) {
                let candidateIP = String(localAddr[..<colonRange.lowerBound]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                if candidateIP != "*" { remoteIP = candidateIP }
            }

            let intel = resolveGeoIntel(for: remoteIP)
            let sec = analyzeSocketSecurity(remoteIP: remoteIP, remoteAddr: remoteAddr, localAddr: localAddr, proto: proto, state: state, asnIsp: intel.asnIsp)
            let formattedGeo = "\(intel.countryFlag) \(intel.countryName) · \(intel.asnIsp)"

            conns.append(ConnectionRow(
                command: cmd,
                pid: pid,
                proto: proto,
                local_addr: localAddr,
                remote_addr: remoteAddr,
                remote_ip: remoteIP,
                state: state,
                geo_org: formattedGeo,
                country_code: intel.countryCode,
                country_flag: intel.countryFlag,
                country_name: intel.countryName,
                asn_isp: intel.asnIsp,
                service_port: sec.servicePort,
                security_status: sec.securityStatus,
                security_label: sec.securityLabel
            ))
            if conns.count >= limit { break }
        }
        return conns
    }

    func getConnectionsForApp(_ appName: String) -> [ConnectionRow] {
        lock.lock()
        let matchedPids = Set((liveApps.first(where: { $0.app_name.lowercased() == appName.lowercased() })?.pids ?? []).map { String($0) })
        lock.unlock()

        let all = getActiveConnections(limit: 160)
        let targetLower = appName.lowercased()
        let prefixLower = String(targetLower.prefix(7))

        return all.filter { c in
            if matchedPids.contains(c.pid) { return true }
            let (normName, _) = normalizeAppName(c.command)
            if normName.lowercased() == targetLower { return true }
            let cmdLower = c.command.lowercased()
            if !prefixLower.isEmpty && (cmdLower.contains(prefixLower) || targetLower.contains(String(cmdLower.prefix(7)))) {
                return true
            }
            return false
        }
    }

    private func flagEmoji(for countryCode: String) -> String {
        let cc = countryCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cc.isEmpty else { return "" }
        return "[\(cc)]"
    }

    private func knownIPPrefixIntel(for ip: String) -> GeoIntelEntry? {
        let low = ip.lowercased()
        if low.isEmpty || low == "*" || low.hasPrefix("127.") || low.hasPrefix("fe80:") || low == "::1" || low == "0.0.0.0" {
            return GeoIntelEntry(countryCode: "LO", countryFlag: "[LO]", countryName: "Localhost", asnIsp: "macOS Loopback")
        }
        if low.hasPrefix("192.168.") || low.hasPrefix("10.") || low.hasPrefix("172.16.") || low.hasPrefix("172.17.") || low.hasPrefix("172.18.") || low.hasPrefix("172.19.") || low.hasPrefix("172.2") || low.hasPrefix("172.30.") || low.hasPrefix("172.31.") || low.hasPrefix("169.254.") || low.hasPrefix("224.") || low.hasPrefix("ff0") || low.hasPrefix("fd") {
            return GeoIntelEntry(countryCode: "LAN", countryFlag: "[LAN]", countryName: "Local LAN", asnIsp: "Private Network Subnet")
        }
        if low.hasPrefix("147.232.") || low.hasPrefix("2001:4118:") {
            return GeoIntelEntry(countryCode: "SK", countryFlag: "[SK]", countryName: "Slovakia (Košice)", asnIsp: "AS2607 SANET / TUKE")
        }
        if low.hasPrefix("147.175.") || low.hasPrefix("158.193.") || low.hasPrefix("158.195.") || low.hasPrefix("194.160.") {
            return GeoIntelEntry(countryCode: "SK", countryFlag: "[SK]", countryName: "Slovakia", asnIsp: "AS2607 SANET Academic Network")
        }
        if low.hasPrefix("17.") || low.hasPrefix("2620:149:") || low.hasPrefix("2a01:b740:") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS714 Apple Inc.")
        }
        if low.hasPrefix("142.250.") || low.hasPrefix("142.251.") || low.hasPrefix("172.217.") || low.hasPrefix("216.58.") || low.hasPrefix("74.125.") || low.hasPrefix("64.233.") || low.hasPrefix("108.177.") || low == "8.8.8.8" || low == "8.8.4.4" || low.hasPrefix("2a00:1450:") || low.hasPrefix("2001:4860:") || low.hasPrefix("2607:f8b0:") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS15169 Google LLC")
        }
        if low.hasPrefix("34.") || low.hasPrefix("35.") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS15169 Google Cloud")
        }
        if low.hasPrefix("1.1.1.") || low.hasPrefix("1.0.0.") || low.hasPrefix("104.16.") || low.hasPrefix("104.17.") || low.hasPrefix("104.18.") || low.hasPrefix("104.19.") || low.hasPrefix("104.2") || low.hasPrefix("172.64.") || low.hasPrefix("172.66.") || low.hasPrefix("172.67.") || low.hasPrefix("162.159.") || low.hasPrefix("2606:4700:") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS13335 Cloudflare, Inc.")
        }
        if low.hasPrefix("140.82.") || low.hasPrefix("192.30.25") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS36459 GitHub, Inc.")
        }
        if low.hasPrefix("185.199.") || low.hasPrefix("151.101.") || low.hasPrefix("199.232.") || low.hasPrefix("2a04:4e42:") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS54113 Fastly CDN")
        }
        if low.hasPrefix("20.") || low.hasPrefix("40.") || low.hasPrefix("51.") || low.hasPrefix("52.9") || low.hasPrefix("52.10") || low.hasPrefix("52.11") || low.hasPrefix("13.107.") || low.hasPrefix("204.79.") || low.hasPrefix("2620:1ec:") || low.hasPrefix("2a01:111:") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS8075 Microsoft Azure")
        }
        if low.hasPrefix("3.") || low.hasPrefix("18.") || low.hasPrefix("52.") || low.hasPrefix("54.") || low.hasPrefix("99.") || low.hasPrefix("108.156.") || low.hasPrefix("143.204.") || low.hasPrefix("2600:9000:") || low.hasPrefix("2a05:d01") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS16509 Amazon AWS")
        }
        if low.hasPrefix("157.240.") || low.hasPrefix("31.13.") || low.hasPrefix("179.60.") || low.hasPrefix("185.60.") || low.hasPrefix("2a03:2880:") {
            return GeoIntelEntry(countryCode: "IE", countryFlag: "[IE]", countryName: "Ireland", asnIsp: "AS32934 Meta Platforms")
        }
        if low.hasPrefix("2a02:26f0:") || low.hasPrefix("23.") || low.hasPrefix("104.6") || low.hasPrefix("104.7") || low.hasPrefix("104.8") || low.hasPrefix("104.9") || low.hasPrefix("184.2") || low.hasPrefix("184.5") || low.hasPrefix("184.8") {
            return GeoIntelEntry(countryCode: "US", countryFlag: "[US]", countryName: "United States", asnIsp: "AS20940 Akamai Technologies")
        }
        return nil
    }

    private func resolveGeoIntel(for ip: String) -> GeoIntelEntry {
        if let localOrKnown = knownIPPrefixIntel(for: ip) {
            return localOrKnown
        }

        lock.lock()
        if let cached = geoIntelCache[ip] {
            lock.unlock()
            return cached
        }
        let seed = GeoIntelEntry(countryCode: "EXT", countryFlag: "[EXT]", countryName: "Resolving...", asnIsp: "Looking up ASN/GeoIP...")
        geoIntelCache[ip] = seed
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }

            // Method 1: Team Cymru DNS BGP ASN & Country Lookup (zero rate-limits, works on all campus/corporate networks)
            if let dnsEntry = self.lookupCymruDNS(for: ip) {
                self.lock.lock()
                self.geoIntelCache[ip] = dnsEntry
                self.geoCache[ip] = "\(dnsEntry.countryFlag) \(dnsEntry.countryName) · \(dnsEntry.asnIsp)"
                self.lock.unlock()
                return
            }

            // Method 2: ip-api.com via curl
            let out1 = self.runCommand("/usr/bin/curl", ["-s", "-L", "--max-time", "3", "http://ip-api.com/json/\(ip)?fields=status,country,countryCode,city,isp,org,as"])
            if let data = out1.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["status"] as? String) == "success" {
                let cc = (json["countryCode"] as? String) ?? "EXT"
                let country = (json["country"] as? String) ?? "External"
                let city = (json["city"] as? String) ?? ""
                let org = (json["org"] as? String) ?? (json["isp"] as? String) ?? "External Network"
                let asStr = (json["as"] as? String) ?? ""
                let asnPrefix = asStr.split(separator: " ").first.map(String.init) ?? ""
                let asnOrg = (!asnPrefix.isEmpty && !org.contains(asnPrefix)) ? "\(asnPrefix) \(org)" : org
                let flag = self.flagEmoji(for: cc)
                let locName = (!city.isEmpty && city != country) ? "\(country) (\(city))" : country
                let entry = GeoIntelEntry(countryCode: cc, countryFlag: flag, countryName: locName, asnIsp: asnOrg)

                self.lock.lock()
                self.geoIntelCache[ip] = entry
                self.geoCache[ip] = "\(flag) \(locName) · \(asnOrg)"
                self.lock.unlock()
                return
            }

            // Method 3: ipwho.is over HTTPS
            let out2 = self.runCommand("/usr/bin/curl", ["-s", "-L", "--max-time", "3", "https://ipwho.is/\(ip)"])
            if let data = out2.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["success"] as? Bool) != false {
                let cc = (json["country_code"] as? String) ?? "EXT"
                let country = (json["country"] as? String) ?? "External"
                let city = (json["city"] as? String) ?? ""
                var asnOrg = "External Network"
                if let conn = json["connection"] as? [String: Any] {
                    let asn = conn["asn"] as? Int
                    let org = (conn["org"] as? String) ?? (conn["isp"] as? String) ?? ""
                    if let asn = asn, !org.isEmpty {
                        asnOrg = "AS\(asn) \(org)"
                    } else if !org.isEmpty {
                        asnOrg = org
                    }
                }
                let flag = self.flagEmoji(for: cc)
                let locName = (!city.isEmpty && city != country) ? "\(country) (\(city))" : country
                let entry = GeoIntelEntry(countryCode: cc, countryFlag: flag, countryName: locName, asnIsp: asnOrg)

                self.lock.lock()
                self.geoIntelCache[ip] = entry
                self.geoCache[ip] = "\(flag) \(locName) · \(asnOrg)"
                self.lock.unlock()
            }
        }
        return seed
    }

    private func analyzeSocketSecurity(remoteIP: String, remoteAddr: String, localAddr: String, proto: String, state: String, asnIsp: String) -> (servicePort: String, securityStatus: String, securityLabel: String) {
        let addrToParse = (remoteAddr != "—" && !remoteAddr.isEmpty) ? remoteAddr : localAddr
        var portNum = 0
        if let colonRange = addrToParse.range(of: ":", options: .backwards) {
            let pStr = String(addrToParse[colonRange.upperBound...])
            portNum = Int(pStr) ?? 0
        }

        if remoteIP.isEmpty || remoteIP == "*" || remoteIP.hasPrefix("127.") || remoteIP.hasPrefix("192.168.") || remoteIP.hasPrefix("10.") || remoteIP.hasPrefix("fe80:") || remoteIP == "::1" || remoteIP.hasPrefix("224.") {
            let pLabel = portNum > 0 ? ":\(portNum) (Local)" : "Local Socket"
            return (pLabel, "local", "Local / Trusted")
        }

        let suspiciousPorts: Set<Int> = [21, 23, 1337, 3333, 4444, 5555, 6666, 6667, 9001, 9050, 31337]
        if suspiciousPorts.contains(portNum) {
            return (":\(portNum) (High-Risk)", "suspicious", "Suspicious Port :\(portNum)")
        }

        switch portNum {
        case 443:
            return (":443 (HTTPS/TLS)", "verified", "TLS Encrypted")
        case 8443:
            return (":8443 (HTTPS-Alt)", "verified", "TLS Encrypted")
        case 53, 853:
            return (":\(portNum) (DNS)", "verified", "DNS Resolver")
        case 5223, 5228:
            return (":\(portNum) (Push TLS)", "verified", "Encrypted Push")
        case 993, 465, 587:
            return (":\(portNum) (Mail TLS)", "verified", "Encrypted Mail")
        case 22:
            return (":22 (SSH)", "verified", "SSH Encrypted")
        case 123:
            return (":123 (NTP)", "verified", "Time Sync")
        case 80, 8080, 8000:
            return (":\(portNum) (HTTP Plain)", "warning", "Unencrypted HTTP")
        case 3389:
            return (":3389 (RDP)", "warning", "Remote Desktop :3389")
        default:
            if proto.uppercased().contains("UDP") {
                return (portNum > 0 ? ":\(portNum) (UDP/QUIC)" : "UDP Socket", "verified", "UDP / QUIC Stream")
            }
            if portNum > 10000 && asnIsp.contains("Resolving") {
                return (":\(portNum) (Custom TCP)", "warning", "Uncommon Port :\(portNum)")
            }
            return (portNum > 0 ? ":\(portNum) (TCP)" : "TCP Socket", "verified", "Verified Endpoint")
        }
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

    // MARK: - Launch at Login (macOS LaunchAgent)
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
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
        SQLiteManager.shared.updateSettings(["launch_at_login": enabled ? "1" : "0"])
    }

    // MARK: - GitHub OTA Auto-Update Checker & 1-Click Self-Updater
    let currentAppVersion = "2.3.4"
    let currentAppBuild = 234

    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let p1 = v1.split(separator: ".").compactMap { Int($0) }
        let p2 = v2.split(separator: ".").compactMap { Int($0) }
        let count = max(p1.count, p2.count)
        for i in 0..<count {
            let a = i < p1.count ? p1[i] : 0
            let b = i < p2.count ? p2[i] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        return 0
    }

    func checkForUpdates(manual: Bool = false) {
        lock.lock()
        if diagnostics.update_checking || diagnostics.update_installing {
            lock.unlock()
            return
        }
        diagnostics.update_checking = true
        if manual {
            diagnostics.update_status = "Checking GitHub for updates..."
        }
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            let ts = Int(Date().timeIntervalSince1970)
            let url = "https://raw.githubusercontent.com/tpackolus/NetPulse/main/version.json?t=\(ts)"
            let out = self.runCommand("/usr/bin/curl", ["-s", "-L", "-H", "Cache-Control: no-cache, no-store", "--max-time", "6", url])

            self.lock.lock()
            defer {
                self.diagnostics.update_checking = false
                self.lock.unlock()
            }

            guard let data = out.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if manual {
                    self.diagnostics.update_status = "Up to date (v\(self.currentAppVersion))"
                }
                return
            }

            let remoteVer = (json["version"] as? String) ?? self.currentAppVersion
            let remoteBuild = (json["build"] as? Int) ?? self.currentAppBuild
            let notes = (json["notes"] as? String) ?? (json["release_notes"] as? String) ?? ""

            let isNewer = (remoteBuild > self.currentAppBuild) || (self.compareVersions(remoteVer, self.currentAppVersion) > 0)
            self.diagnostics.app_version = self.currentAppVersion
            self.diagnostics.latest_version = remoteVer
            self.diagnostics.update_available = isNewer
            self.diagnostics.update_notes = notes
            if isNewer {
                self.diagnostics.update_status = "Update available: v\(remoteVer)"
            } else {
                self.diagnostics.update_status = "Up to date (v\(self.currentAppVersion))"
            }
        }
    }

    func performSelfUpdate() {
        lock.lock()
        if diagnostics.update_installing {
            lock.unlock()
            return
        }
        diagnostics.update_installing = true
        diagnostics.update_status = "Downloading update from GitHub..."
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            let ts = Int(Date().timeIntervalSince1970)
            let zipPath = "/tmp/NetPulse-OTA.zip"
            let extractDir = "/tmp/NetPulse-OTA-Extract"
            let downloadURL = "https://raw.githubusercontent.com/tpackolus/NetPulse/main/NetPulse-Mac-Installer.zip?t=\(ts)"

            try? FileManager.default.removeItem(atPath: zipPath)
            try? FileManager.default.removeItem(atPath: extractDir)

            _ = self.runCommand("/usr/bin/curl", ["-L", "-s", "-H", "Cache-Control: no-cache, no-store", "--max-time", "60", "-o", zipPath, downloadURL], timeout: 65)

            guard FileManager.default.fileExists(atPath: zipPath) else {
                self.lock.lock()
                self.diagnostics.update_installing = false
                self.diagnostics.update_status = "Update failed (network error)"
                self.lock.unlock()
                return
            }

            self.lock.lock()
            self.diagnostics.update_status = "Extracting & verifying update..."
            self.lock.unlock()

            _ = self.runCommand("/usr/bin/ditto", ["-x", "-k", zipPath, extractDir], timeout: 20)
            let extractedApp = "\(extractDir)/NetPulse.app"
            let extractedExec = "\(extractedApp)/Contents/MacOS/NetPulse"

            guard FileManager.default.fileExists(atPath: extractedExec) else {
                self.lock.lock()
                self.diagnostics.update_installing = false
                self.diagnostics.update_status = "Update failed (invalid archive)"
                self.lock.unlock()
                return
            }

            _ = self.runCommand("/usr/bin/xattr", ["-cr", extractedApp])
            _ = self.runCommand("/bin/chmod", ["+x", extractedExec])
            _ = self.runCommand("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", extractedApp])

            self.lock.lock()
            self.diagnostics.update_status = "Installing & restarting NetPulse..."
            self.lock.unlock()

            let currentBundle = Bundle.main.bundlePath
            let isReadOnlyMount = currentBundle.contains("/AppTranslocation/") || currentBundle.hasPrefix("/Volumes/")
            let primaryTarget = (!isReadOnlyMount && currentBundle.hasSuffix(".app")) ? currentBundle : "/Applications/NetPulse.app"

            // Replace bundle(s) in-place BEFORE exiting so macOS launchd never kills a background bash copier
            var candidateTargets = Set<String>([primaryTarget])
            if FileManager.default.fileExists(atPath: "/Applications/NetPulse.app") {
                candidateTargets.insert("/Applications/NetPulse.app")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for dlCandidate in [
                "\(home)/Downloads/NetPulse.app",
                "\(home)/Downloads/NetPulse-Mac-Installer/NetPulse.app",
                "\(home)/Downloads/appka/NetPulse.app"
            ] {
                if FileManager.default.fileExists(atPath: dlCandidate) {
                    candidateTargets.insert(dlCandidate)
                }
            }

            for target in candidateTargets {
                try? FileManager.default.removeItem(atPath: target)
                _ = self.runCommand("/usr/bin/ditto", [extractedApp, target], timeout: 15)
                _ = self.runCommand("/usr/bin/xattr", ["-cr", target])
                _ = self.runCommand("/bin/chmod", ["+x", "\(target)/Contents/MacOS/NetPulse"])
            }

            // Clear WebKit disk cache so the newly launched app loads fresh HTML/JS/CSS
            try? FileManager.default.removeItem(atPath: "\(home)/Library/Caches/com.maros.netpulse")

            try? FileManager.default.removeItem(atPath: zipPath)
            try? FileManager.default.removeItem(atPath: extractDir)

            // Launch the updated bundle (its startup terminateOtherInstances() will replace this process)
            _ = self.runCommand("/usr/bin/open", ["-n", primaryTarget])
            Thread.sleep(forTimeInterval: 0.5)
            exit(0)
        }
    }
}
