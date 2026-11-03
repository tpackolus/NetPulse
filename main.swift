import Cocoa
import WebKit
import Foundation

// MARK: - Custom URL Scheme Handler (netpulse://) — Zero External Server
final class NetPulseSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceDir: String

    init(resourceDir: String) {
        self.resourceDir = resourceDir
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let path = url.path.isEmpty ? "/index.html" : url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func param(_ name: String, default defVal: String = "") -> String {
            return queryItems.first(where: { $0.name == name })?.value ?? defVal
        }

        // Handle API calls in-memory directly from Swift + SQLite
        if path.hasPrefix("/api/") {
            let responseData = handleAPI(path: path, param: param, request: urlSchemeTask.request)
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Cache-Control": "no-store"
                ]
            )!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(responseData)
            urlSchemeTask.didFinish()
            return
        }

        // Serve static UI assets from bundle Resources
        let cleanFile = path == "/" ? "index.html" : String(path.dropFirst())
        let fullPath = (resourceDir as NSString).appendingPathComponent(cleanFile)
        if let fileData = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) {
            let ext = (cleanFile as NSString).pathExtension.lowercased()
            let mime: String
            switch ext {
            case "html": mime = "text/html; charset=utf-8"
            case "css":  mime = "text/css; charset=utf-8"
            case "js":   mime = "application/javascript; charset=utf-8"
            case "svg":  mime = "image/svg+xml"
            default:     mime = "application/octet-stream"
            }
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mime]
            )!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(fileData)
            urlSchemeTask.didFinish()
        } else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func handleAPI(path: String, param: (String, String) -> String, request: URLRequest) -> Data {
        let engine = TelemetryEngine.shared
        let db = SQLiteManager.shared

        if path == "/api/realtime" {
            let iface = param("interface", "all")
            let summaries = db.getSummaries(ifaceFilter: iface)

            var spdIn = engine.liveSpeedIn
            var spdOut = engine.liveSpeedOut
            if iface != "all", let found = engine.liveInterfaces.first(where: { $0.interface == iface }) {
                spdIn = found.speed_in
                spdOut = found.speed_out
            }

            let dict: [String: Any] = [
                "speed_in": spdIn,
                "speed_out": spdOut,
                "peak_speed_in": engine.peakSpeedIn,
                "peak_speed_out": engine.peakSpeedOut,
                "summaries": encodeToObject(summaries),
                "interfaces": encodeToObject(engine.liveInterfaces),
                "live_apps": encodeToObject(engine.liveApps),
                "realtime_history": encodeToObject(engine.realtimeHistory),
                "diagnostics": encodeToObject(engine.diagnostics)
            ]
            return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        }

        if path == "/api/history" {
            let preset = param("preset", "today")
            let iface = param("interface", "all")
            var groupBy = param("group_by", "auto")

            let cal = Calendar.current
            let now = Date()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let todayStr = fmt.string(from: now)

            var startStr = todayStr
            var endStr = todayStr

            switch preset {
            case "today":
                startStr = todayStr; endStr = todayStr
                if groupBy == "auto" { groupBy = "hour" }
            case "yesterday":
                let yd = fmt.string(from: cal.date(byAdding: .day, value: -1, to: now)!)
                startStr = yd; endStr = yd
                if groupBy == "auto" { groupBy = "hour" }
            case "this_week":
                let weekday = cal.component(.weekday, from: now)
                let daysFromMon = (weekday + 5) % 7
                startStr = fmt.string(from: cal.date(byAdding: .day, value: -daysFromMon, to: now)!)
                endStr = todayStr
                if groupBy == "auto" { groupBy = "day" }
            case "last_7_days":
                startStr = fmt.string(from: cal.date(byAdding: .day, value: -6, to: now)!)
                endStr = todayStr
                if groupBy == "auto" { groupBy = "day" }
            case "this_month":
                let comps = cal.dateComponents([.year, .month], from: now)
                startStr = String(format: "%04d-%02d-01", comps.year ?? 2026, comps.month ?? 1)
                endStr = todayStr
                if groupBy == "auto" { groupBy = "day" }
            case "last_30_days":
                startStr = fmt.string(from: cal.date(byAdding: .day, value: -29, to: now)!)
                endStr = todayStr
                if groupBy == "auto" { groupBy = "day" }
            case "this_year":
                let comps = cal.dateComponents([.year], from: now)
                startStr = String(format: "%04d-01-01", comps.year ?? 2026)
                endStr = todayStr
                if groupBy == "auto" { groupBy = "month" }
            default:
                startStr = param("start", todayStr)
                endStr = param("end", todayStr)
                if groupBy == "auto" { groupBy = (startStr == endStr) ? "hour" : "day" }
            }

            let res = db.queryHistory(start: startStr, end: endStr, groupBy: groupBy, ifaceFilter: iface)
            let peak = res.timeline.max(by: { $0.total < $1.total })

            let dict: [String: Any] = [
                "start_date": startStr,
                "end_date": endStr,
                "group_by": groupBy,
                "totals": [
                    "bytes_in": res.totalIn,
                    "bytes_out": res.totalOut,
                    "total": res.totalIn + res.totalOut,
                    "peak": peak != nil ? encodeToObject(peak!) : NSNull()
                ],
                "timeline": encodeToObject(res.timeline),
                "apps": encodeToObject(res.apps)
            ]
            return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        }

        if path == "/api/app_detail" {
            let appName = param("app", "")
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let todayStr = fmt.string(from: Date())
            let hourly = db.queryAppHourlyHistory(appName: appName, dateStr: todayStr)
            let conns = engine.getActiveConnections(limit: 80).filter {
                $0.command.lowercased().contains(appName.prefix(8).lowercased()) ||
                appName.lowercased().contains($0.command.lowercased())
            }
            let dict: [String: Any] = [
                "app_name": appName,
                "hourly": encodeToObject(hourly),
                "connections": encodeToObject(conns)
            ]
            return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        }

        if path == "/api/connections" {
            let conns = engine.getActiveConnections(limit: 40)
            return (try? JSONSerialization.data(withJSONObject: ["connections": encodeToObject(conns)])) ?? Data()
        }

        if path == "/api/settings" {
            return (try? JSONSerialization.data(withJSONObject: ["settings": db.getSettings()])) ?? Data()
        }

        if path == "/api/speedtest" {
            engine.runSpeedtest()
            return (try? JSONSerialization.data(withJSONObject: ["status": "started"])) ?? Data()
        }

        if path == "/api/check_updates" {
            engine.checkForUpdates(manual: true)
            return (try? JSONSerialization.data(withJSONObject: ["status": "checking"])) ?? Data()
        }

        if path == "/api/install_update" {
            engine.performSelfUpdate()
            return (try? JSONSerialization.data(withJSONObject: ["status": "installing"])) ?? Data()
        }

        return (try? JSONSerialization.data(withJSONObject: ["status": "ok"])) ?? Data()
    }

    private func encodeToObject<T: Encodable>(_ val: T) -> Any {
        guard let data = try? JSONEncoder().encode(val),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return obj
    }
}

// MARK: - Native Bridge Handler for Actions (Save Settings, Reveal DB in Finder, Kill Process, Export, Auto-Update)
final class NativeActionHandler: NSObject, WKScriptMessageHandler {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else { return }

        switch action {
        case "reveal_db":
            let dbURL = URL(fileURLWithPath: SQLiteManager.shared.dbPath)
            NSWorkspace.shared.activateFileViewerSelecting([dbURL])

        case "save_settings":
            if let settings = dict["settings"] as? [String: String] {
                SQLiteManager.shared.updateSettings(settings)
                if let loginStr = settings["launch_at_login"] {
                    TelemetryEngine.shared.setLaunchAtLogin(
                        enabled: loginStr == "1",
                        appBundlePath: Bundle.main.bundlePath
                    )
                }
            }

        case "kill_app":
            if let appName = dict["app_name"] as? String {
                _ = TelemetryEngine.shared.terminateAppByName(appName)
            }

        case "set_theme":
            if let theme = dict["theme"] as? String {
                SQLiteManager.shared.updateSettings(["theme": theme])
                DispatchQueue.main.async {
                    self.appDelegate?.applyWindowTheme(theme)
                }
            }

        case "run_speedtest":
            TelemetryEngine.shared.runSpeedtest()

        case "check_updates":
            TelemetryEngine.shared.checkForUpdates(manual: true)

        case "install_update":
            TelemetryEngine.shared.performSelfUpdate()

        case "export":
            let fmt = (dict["format"] as? String) ?? "csv"
            let start = (dict["start"] as? String) ?? "2026-01-01"
            let end = (dict["end"] as? String) ?? "2026-12-31"
            let groupBy = (dict["group_by"] as? String) ?? "day"
            let iface = (dict["interface"] as? String) ?? "all"

            let res = SQLiteManager.shared.queryHistory(start: start, end: end, groupBy: groupBy, ifaceFilter: iface)
            var content = ""
            if fmt == "json" {
                let payload: [String: Any] = [
                    "start_date": start,
                    "end_date": end,
                    "total_bytes_in": res.totalIn,
                    "total_bytes_out": res.totalOut,
                    "timeline": res.timeline.map { ["label": $0.label, "bytes_in": $0.bytes_in, "bytes_out": $0.bytes_out, "total": $0.total] },
                    "apps": res.apps.map { ["app_name": $0.app_name, "bytes_in": $0.bytes_in, "bytes_out": $0.bytes_out, "total": $0.total] }
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
                    content = String(data: data, encoding: .utf8) ?? "{}"
                }
            } else {
                var lines = ["Interval,Download (Bytes),Upload (Bytes),Total (Bytes),Total (GB)"]
                for r in res.timeline {
                    let gb = String(format: "%.4f", Double(r.total) / (1024 * 1024 * 1024))
                    lines.append("\(r.label),\(r.bytes_in),\(r.bytes_out),\(r.total),\(gb)")
                }
                lines.append("")
                lines.append("Application,Download (Bytes),Upload (Bytes),Total (Bytes),Total (MB)")
                for a in res.apps {
                    let mb = String(format: "%.2f", Double(a.total) / (1024 * 1024))
                    lines.append("\"\(a.app_name)\",\(a.bytes_in),\(a.bytes_out),\(a.total),\(mb)")
                }
                content = lines.joined(separator: "\n")
            }

            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = "netpulse_export_\(start)_\(end).\(fmt)"
            savePanel.canCreateDirectories = true
            savePanel.title = "Export NetPulse Telemetry Data"
            savePanel.begin { resp in
                if resp == .OK, let targetURL = savePanel.url {
                    try? content.write(to: targetURL, atomically: true, encoding: .utf8)
                }
            }

        default:
            break
        }
    }
}

// MARK: - Main Application Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    var mainWindow: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var statusTimer: Timer?
    var allowFullTermination = false

    let todayItem = NSMenuItem(title: "Today: 0 MB", action: nil, keyEquivalent: "")
    let weekItem = NSMenuItem(title: "This Week: 0 MB", action: nil, keyEquivalent: "")
    let monthItem = NSMenuItem(title: "This Month: 0 MB", action: nil, keyEquivalent: "")
    let pingItem = NSMenuItem(title: "Latency: —", action: nil, keyEquivalent: "")
    let topApp1 = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    let topApp2 = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    let topApp3 = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    let updateMenuItem = NSMenuItem(title: "Check for Updates... (v2.2.0)", action: nil, keyEquivalent: "u")

    func resolveResourceDir() -> String {
        if let resPath = Bundle.main.resourcePath {
            let staticDir = (resPath as NSString).appendingPathComponent("static")
            let indexCheck = (staticDir as NSString).appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexCheck) {
                return staticDir
            }
        }
        let appDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        return (appDir as NSString).appendingPathComponent("static")
    }

    private func terminateOtherInstances() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if pid != myPID {
                if app.bundleIdentifier == "com.maros.netpulse" || app.localizedName == "NetPulse" || (app.executableURL?.lastPathComponent == "NetPulse") {
                    kill(pid, SIGKILL)
                }
            }
        }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "NetPulse.app/Contents/MacOS/NetPulse"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.split(whereSeparator: \.isNewline) {
                    if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != myPID {
                        kill(pid, SIGKILL)
                    }
                }
            }
        } catch {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()

        let startInBackground = CommandLine.arguments.contains("--background")
        NSApp.setActivationPolicy(startInBackground ? .accessory : .regular)
        TelemetryEngine.shared.isMainWindowVisible = !startInBackground
        TelemetryEngine.shared.start()

        let settings = SQLiteManager.shared.getSettings()
        if (settings["launch_at_login"] ?? "1") == "1" {
            TelemetryEngine.shared.setLaunchAtLogin(enabled: true, appBundlePath: Bundle.main.bundlePath)
        }

        setupMainMenu()
        setupStatusBar()
        setupMainWindow()

        let savedTheme = settings["theme"] ?? "dark"
        applyWindowTheme(savedTheme)

        if startInBackground {
            mainWindow.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        statusTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateStatusBar), userInfo: nil, repeats: true)
        updateStatusBar()

        if CommandLine.arguments.contains("--capture-screenshots") {
            allowFullTermination = true
            captureRealScreenshots()
        }
    }

    private func saveSnapshotImage(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private func captureRealScreenshots() {
        let docsDir = "/Users/marosharahus/Downloads/appka/docs"
        try? FileManager.default.createDirectory(atPath: docsDir, withIntermediateDirectories: true)

        // Expand window & webView so the entire dashboard from topbar to bottom tables renders in one full view
        let fullW: CGFloat = 1440
        let fullH: CGFloat = 2120
        let fullRect = NSRect(x: 20, y: 20, width: fullW, height: fullH)
        mainWindow.setFrame(fullRect, display: true)
        webView.frame = NSRect(x: 0, y: 0, width: fullW, height: fullH)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            let prepJS = """
            const snapStyle = document.createElement('style');
            snapStyle.textContent = `
                .realtime-frame { height: 215px !important; }
                .history-frame { height: 245px !important; }
                .app-table-height { max-height: 420px !important; }
                .conn-table-height { max-height: 220px !important; }
                .iface-stack { max-height: 210px !important; }
            `;
            document.head.appendChild(snapStyle);
            applyTheme('dark');
            setAppViewMode('history');
            fetchRealtime();
            fetchHistory();
            fetchConnections();
            """
            self.applyWindowTheme("dark")
            self.webView.evaluateJavaScript(prepJS) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = NSRect(x: 0, y: 0, width: fullW, height: fullH)
                    self.webView.takeSnapshot(with: cfg) { img, _ in
                        if let img = img {
                            self.saveSnapshotImage(img, to: "\(docsDir)/netpulse-dark.png")
                        }
                        // Switch to Light Mode and capture full Light Mode screenshot
                        self.applyWindowTheme("light")
                        self.webView.evaluateJavaScript("applyTheme('light'); renderRealtimeChart(); renderHistoryChart(); renderAppTable();") { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.webView.takeSnapshot(with: cfg) { imgLight, _ in
                                    if let imgLight = imgLight {
                                        self.saveSnapshotImage(imgLight, to: "\(docsDir)/netpulse-light.png")
                                    }
                                    // Capture Process Inspector Modal in 1440x920 viewport
                                    let modalRect = NSRect(x: 40, y: 40, width: 1440, height: 920)
                                    self.mainWindow.setFrame(modalRect, display: true)
                                    self.webView.frame = NSRect(x: 0, y: 0, width: 1440, height: 920)
                                    self.applyWindowTheme("dark")
                                    let openModalJS = """
                                    applyTheme('dark');
                                    window.scrollTo(0, 0);
                                    if (state.historyApps && state.historyApps.length > 0) {
                                        openAppInspector(state.historyApps[0].app_name);
                                    } else if (state.liveApps && state.liveApps.length > 0) {
                                        openAppInspector(state.liveApps[0].app_name);
                                    } else {
                                        openLimitsModal();
                                    }
                                    """
                                    self.webView.evaluateJavaScript(openModalJS) { _, _ in
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            let modalCfg = WKSnapshotConfiguration()
                                            modalCfg.rect = NSRect(x: 0, y: 0, width: 1440, height: 920)
                                            self.webView.takeSnapshot(with: modalCfg) { imgModal, _ in
                                                if let imgModal = imgModal {
                                                    self.saveSnapshotImage(imgModal, to: "\(docsDir)/netpulse-inspector.png")
                                                }
                                                SQLiteManager.shared.updateSettings(["theme": "dark"])
                                                NSApplication.shared.terminate(nil)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func applyWindowTheme(_ theme: String) {
        guard let win = mainWindow else { return }
        if theme == "light" {
            win.appearance = NSAppearance(named: .aqua)
            win.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.965, blue: 0.975, alpha: 1.0)
        } else {
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.043, alpha: 1.0)
        }
    }

    func setupMainWindow() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Adapt initial size to 90% of current monitor's visible frame (from 13" MacBook to 4K/5K external display)
        let winWidth = max(760, screenRect.width * 0.90)
        let winHeight = max(560, screenRect.height * 0.88)
        let winRect = NSRect(
            x: screenRect.origin.x + (screenRect.width - winWidth) / 2,
            y: screenRect.origin.y + (screenRect.height - winHeight) / 2,
            width: winWidth,
            height: winHeight
        )

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        mainWindow = NSWindow(contentRect: winRect, styleMask: styleMask, backing: .buffered, defer: false)
        mainWindow.title = "NetPulse"
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.collectionBehavior = [.fullScreenPrimary, .managed]
        mainWindow.appearance = NSAppearance(named: .darkAqua)
        mainWindow.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.043, alpha: 1.0)
        mainWindow.minSize = NSSize(width: 720, height: 520)
        if !CommandLine.arguments.contains("--capture-screenshots") {
            mainWindow.setFrameAutosaveName("NetPulseMainWindowFrame")
        }
        mainWindow.delegate = self
        mainWindow.isReleasedWhenClosed = false

        // Clamp window to visible screen if saved frame was from a larger disconnected external monitor
        if !CommandLine.arguments.contains("--capture-screenshots") {
            fitWindowToCurrentScreenIfNeeded()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let config = WKWebViewConfiguration()
        let schemeHandler = NetPulseSchemeHandler(resourceDir: resolveResourceDir())
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "netpulse")
        config.userContentController.add(NativeActionHandler(appDelegate: self), name: "netpulseNative")

        let cssInjection = """
        .topbar-inner { padding-left: 86px !important; -webkit-user-select: none; }
        body { -webkit-user-select: none; }
        td, .metric-val, .kpi-primary, .strip-val, code { -webkit-user-select: text; }
        """
        let script = WKUserScript(
            source: "const st = document.createElement('style'); st.textContent = `\(cssInjection)`; document.head.appendChild(st);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(script)

        webView = WKWebView(frame: mainWindow.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        mainWindow.contentView?.addSubview(webView)
        mainWindow.makeKeyAndOrderFront(nil)

        if let url = URL(string: "netpulse://app/index.html") {
            webView.load(URLRequest(url: url))
        }
    }

    @objc func screenParametersChanged() {
        fitWindowToCurrentScreenIfNeeded()
    }

    private func fitWindowToCurrentScreenIfNeeded() {
        guard let win = mainWindow, !win.styleMask.contains(.fullScreen) else { return }
        let screenFrame = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = win.frame

        if frame.width > screenFrame.width {
            frame.size.width = screenFrame.width * 0.94
        }
        if frame.height > screenFrame.height {
            frame.size.height = screenFrame.height * 0.92
        }
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width
        }
        if frame.minX < screenFrame.minX {
            frame.origin.x = screenFrame.minX
        }
        if frame.maxY > screenFrame.maxY {
            frame.origin.y = screenFrame.maxY - frame.height
        }
        if frame.minY < screenFrame.minY {
            frame.origin.y = screenFrame.minY
        }
        win.setFrame(frame, display: true, animate: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        minimizeToBackground()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowFullTermination {
            return .terminateNow
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit NetPulse or Keep Running in Background?"
        alert.informativeText = "If you keep NetPulse running in the background, the window and Dock icon will be hidden while live telemetry continues in the top Menu Bar."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit Completely")
        alert.addButton(withTitle: "Run in Background (Menu Bar)")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            allowFullTermination = true
            return .terminateNow
        } else if response == .alertSecondButtonReturn {
            minimizeToBackground()
            return .terminateCancel
        } else {
            return .terminateCancel
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Top Menu Bar Item (Compact Smaller Typography as Requested)
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            setCompactMenuBarTitle(down: 0, up: 0, button: button)
        }

        let menu = NSMenu()
        let headerItem = NSMenuItem(title: "NetPulse Telemetry (Background Active)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open NetPulse Window", action: #selector(showMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let hideBgItem = NSMenuItem(title: "Hide Window (Keep Running in Background)", action: #selector(minimizeToBackground), keyEquivalent: "w")
        hideBgItem.target = self
        menu.addItem(hideBgItem)

        let revealDbItem = NSMenuItem(title: "Reveal SQLite Database in Finder", action: #selector(revealDatabase), keyEquivalent: "f")
        revealDbItem.target = self
        menu.addItem(revealDbItem)

        updateMenuItem.target = self
        updateMenuItem.action = #selector(handleMenuBarUpdateClick)
        menu.addItem(updateMenuItem)

        menu.addItem(NSMenuItem.separator())
        let statsHeader = NSMenuItem(title: "DATA TRANSFERRED", action: nil, keyEquivalent: "")
        statsHeader.isEnabled = false
        menu.addItem(statsHeader)
        menu.addItem(todayItem)
        menu.addItem(weekItem)
        menu.addItem(monthItem)
        menu.addItem(pingItem)

        menu.addItem(NSMenuItem.separator())
        let appsHeader = NSMenuItem(title: "TOP PROCESSES (LIVE)", action: nil, keyEquivalent: "")
        appsHeader.isEnabled = false
        menu.addItem(appsHeader)
        menu.addItem(topApp1)
        menu.addItem(topApp2)
        menu.addItem(topApp3)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit NetPulse Completely", action: #selector(stopBackgroundAndExit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setCompactMenuBarTitle(down: Double, up: Double, button: NSStatusBarButton) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)

        let attr = NSMutableAttributedString()
        let downColor = NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        let upColor = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1.0)

        attr.append(NSAttributedString(string: "↓ ", attributes: [.font: labelFont, .foregroundColor: downColor]))
        attr.append(NSAttributedString(string: "\(formatSpeedCompact(down))  ", attributes: [.font: font]))
        attr.append(NSAttributedString(string: "↑ ", attributes: [.font: labelFont, .foregroundColor: upColor]))
        attr.append(NSAttributedString(string: formatSpeedCompact(up), attributes: [.font: font]))

        button.attributedTitle = attr
    }

    private func formatSpeedCompact(_ bps: Double) -> String {
        if bps >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB/s", bps / (1024 * 1024 * 1024))
        } else if bps >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bps / (1024 * 1024))
        } else if bps >= 1024 {
            return String(format: "%.0f KB/s", bps / 1024)
        } else {
            return "0 KB/s"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
        } else if b >= 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        }
        return "\(bytes) B"
    }

    @objc func updateStatusBar() {
        let engine = TelemetryEngine.shared
        if let button = statusItem.button {
            setCompactMenuBarTitle(down: engine.liveSpeedIn, up: engine.liveSpeedOut, button: button)
        }

        let s = SQLiteManager.shared.getSummaries()
        todayItem.title = "Today: \(formatBytes(s.today.total))  (IN \(formatBytes(s.today.bytes_in)) / OUT \(formatBytes(s.today.bytes_out)))"
        weekItem.title  = "This Week: \(formatBytes(s.this_week.total))  (IN \(formatBytes(s.this_week.bytes_in)) / OUT \(formatBytes(s.this_week.bytes_out)))"
        monthItem.title = "This Month: \(formatBytes(s.this_month.total))  (IN \(formatBytes(s.this_month.bytes_in)) / OUT \(formatBytes(s.this_month.bytes_out)))"

        let d = engine.diagnostics
        let rPing = d.ping_router_ms >= 0 ? String(format: "%.1f ms", d.ping_router_ms) : "—"
        let iPing = d.ping_internet_ms >= 0 ? String(format: "%.1f ms", d.ping_internet_ms) : "—"
        pingItem.title = "Latency: Gateway \(rPing) | Internet \(iPing)"

        if d.update_installing {
            updateMenuItem.title = d.update_status
        } else if d.update_available {
            updateMenuItem.title = "Install Update Now (v\(d.latest_version) Available)"
        } else if d.update_checking {
            updateMenuItem.title = "Checking for Updates..."
        } else {
            updateMenuItem.title = "Check for Updates... (v\(d.app_version))"
        }

        let apps = engine.liveApps
        let slots = [topApp1, topApp2, topApp3]
        for i in 0..<3 {
            if i < apps.count {
                let a = apps[i]
                let spd = a.speed_in + a.speed_out
                let spdTxt = spd > 500 ? " [\(formatSpeedCompact(spd))]" : ""
                slots[i].title = "\(i + 1). \(a.app_name): \(formatBytes(a.total))\(spdTxt)"
            } else {
                slots[i].title = "—"
            }
        }
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "Show NetPulse Window", action: #selector(showMainWindow), keyEquivalent: "1")
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(handleMenuBarUpdateClick), keyEquivalent: "u")
        appMenu.addItem(withTitle: "Reveal Database in Finder", action: #selector(revealDatabase), keyEquivalent: "f")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Window to Background Menu Bar", action: #selector(minimizeToBackground), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Hide NetPulse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit NetPulse...", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close Window to Background Menu Bar", action: #selector(minimizeToBackground), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        TelemetryEngine.shared.isMainWindowVisible = true
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func minimizeToBackground() {
        TelemetryEngine.shared.isMainWindowVisible = false
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func handleMenuBarUpdateClick() {
        if TelemetryEngine.shared.diagnostics.update_available {
            TelemetryEngine.shared.performSelfUpdate()
        } else {
            TelemetryEngine.shared.checkForUpdates(manual: true)
            showMainWindow()
            webView.evaluateJavaScript("openLimitsModal();", completionHandler: nil)
        }
    }

    @objc func revealDatabase() {
        let dbURL = URL(fileURLWithPath: SQLiteManager.shared.dbPath)
        NSWorkspace.shared.activateFileViewerSelecting([dbURL])
    }

    @objc func stopBackgroundAndExit() {
        allowFullTermination = true
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
