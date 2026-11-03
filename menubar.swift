import Cocoa
import WebKit
import Foundation

// MARK: - API Models
struct TrafficMetrics: Decodable {
    let bytes_in: Int64
    let bytes_out: Int64
    let total: Int64
}

struct Summaries: Decodable {
    let today: TrafficMetrics
    let this_week: TrafficMetrics
    let this_month: TrafficMetrics
}

struct AppTraffic: Decodable {
    let app_name: String
    let speed_in: Double
    let speed_out: Double
    let session_total: Int64
}

struct RealtimeResponse: Decodable {
    let speed_in: Double
    let speed_out: Double
    let summaries: Summaries
    let live_apps: [AppTraffic]
}

// MARK: - Main Native macOS Application Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    var mainWindow: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var statsTimer: Timer?
    var backendProcess: Process?

    let todayItem = NSMenuItem(title: "Dnes: načítavam...", action: nil, keyEquivalent: "")
    let weekItem = NSMenuItem(title: "Týždeň: načítavam...", action: nil, keyEquivalent: "")
    let monthItem = NSMenuItem(title: "Mesiac: načítavam...", action: nil, keyEquivalent: "")
    let topApp1 = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    let topApp2 = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    let topApp3 = NSMenuItem(title: "—", action: nil, keyEquivalent: "")

    let port: String
    let dashboardURL: String
    var projectRoot: String = ""

    override init() {
        self.port = ProcessInfo.processInfo.environment["NETPULSE_PORT"] ?? "8765"
        self.dashboardURL = "http://127.0.0.1:\(self.port)"
        super.init()
        self.projectRoot = resolveProjectRoot()
    }

    func resolveProjectRoot() -> String {
        // If running from NetPulse.app/Contents/MacOS/NetPulse
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return (bundlePath as NSString).deletingLastPathComponent
        }
        return FileManager.default.currentDirectoryPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        setupStatusBar()
        setupMainWindow()
        ensureBackendRunning()

        statsTimer = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(fetchStats), userInfo: nil, repeats: true)
        fetchStats()

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Backend Process Management
    func ensureBackendRunning() {
        guard let url = URL(string: "\(dashboardURL)/api/settings") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.8

        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else { return }
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, error == nil {
                DispatchQueue.main.async {
                    self.loadDashboardInWebView()
                }
            } else {
                self.startBackendProcess()
            }
        }.resume()
    }

    func startBackendProcess() {
        let serverScript = (projectRoot as NSString).appendingPathComponent("server.py")
        guard FileManager.default.fileExists(atPath: serverScript) else {
            DispatchQueue.main.async {
                self.loadDashboardInWebView()
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [serverScript, "--no-browser"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

        var env = ProcessInfo.processInfo.environment
        env["NETPULSE_PORT"] = port
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            self.backendProcess = proc
        } catch {
            print("Failed to start server.py: \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.loadDashboardInWebView()
        }
    }

    // MARK: - Window & WebView Setup
    func setupMainWindow() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let winWidth = min(1420, screenRect.width * 0.9)
        let winHeight = min(900, screenRect.height * 0.88)
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
        mainWindow.appearance = NSAppearance(named: .darkAqua)
        mainWindow.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.043, alpha: 1.0)
        mainWindow.minSize = NSSize(width: 960, height: 640)
        mainWindow.delegate = self
        mainWindow.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Inject subtle top padding so macOS window traffic lights (close/minimize/zoom) sit cleanly in the top bar
        let cssInjection = """
        .topbar-inner { padding-left: 88px !important; -webkit-user-select: none; }
        body { -webkit-user-select: none; }
        td, .metric-val, .kpi-primary, .strip-val { -webkit-user-select: text; }
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

        //Intercept CSV/JSON export links so they save directly to ~/Downloads and reveal in Finder
        let exportScript = """
        window.exportData = function(format) {
            const start = document.getElementById('filterStartDate').value;
            const end = document.getElementById('filterEndDate').value;
            const groupBy = document.getElementById('filterGroupBy').value === 'auto' ? 'day' : document.getElementById('filterGroupBy').value;
            const iface = state.selectedInterface;
            const url = `/api/export?format=${encodeURIComponent(format)}&start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}&group_by=${encodeURIComponent(groupBy)}&interface=${encodeURIComponent(iface)}`;
            fetch(url).then(r => r.text()).then(content => {
                window.webkit.messageHandlers.netpulseExport.postMessage({
                    filename: `netpulse_export_${start}_${end}.${format}`,
                    content: content
                });
            });
        };
        """
        let exportUserScript = WKUserScript(source: exportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(exportUserScript)
        config.userContentController.add(ExportScriptHandler(), name: "netpulseExport")

        mainWindow.contentView?.addSubview(webView)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    func loadDashboardInWebView() {
        guard let url = URL(string: dashboardURL) else { return }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Retry loading if Python server is still warming up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.loadDashboardInWebView()
        }
    }

    // Intercept window close button so the app keeps monitoring in the Menu Bar
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let proc = backendProcess, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Native macOS Menu Bar (Cmd+Q, Cmd+R, Cmd+W, Edit/Copy)
    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "O aplikácii NetPulse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let showItem = NSMenuItem(title: "Zobraziť hlavné okno", action: #selector(showMainWindow), keyEquivalent: "1")
        showItem.target = self
        appMenu.addItem(showItem)

        let reloadItem = NSMenuItem(title: "Obnoviť dáta", action: #selector(reloadWebView), keyEquivalent: "r")
        reloadItem.target = self
        appMenu.addItem(reloadItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Skryť NetPulse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Ukončiť NetPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File / Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Okno")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Zavrieť okno (ponechať v lište)", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimalizovať", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        // Edit Menu (needed for copy/paste in inputs)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Úpravy")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Kopírovať", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Prilepiť", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Vybrať všetko", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Top Status Bar Item
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "IN 0 KB/s   OUT 0 KB/s"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        }

        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "NetPulse Telemetry", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Otvoriť okno aplikácie", action: #selector(showMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())
        let statsHeader = NSMenuItem(title: "PRENESENÉ DÁTA", action: nil, keyEquivalent: "")
        statsHeader.isEnabled = false
        menu.addItem(statsHeader)
        menu.addItem(todayItem)
        menu.addItem(weekItem)
        menu.addItem(monthItem)

        menu.addItem(NSMenuItem.separator())
        let appsHeader = NSMenuItem(title: "TOP PROCESY (AKTÍVNA RELÁCIA)", action: nil, keyEquivalent: "")
        appsHeader.isEnabled = false
        menu.addItem(appsHeader)
        menu.addItem(topApp1)
        menu.addItem(topApp2)
        menu.addItem(topApp3)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Ukončiť NetPulse", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
        } else if bytesPerSec >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
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

    @objc func fetchStats() {
        guard let url = URL(string: "\(dashboardURL)/api/realtime") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            guard let decoded = try? JSONDecoder().decode(RealtimeResponse.self, from: data) else { return }

            DispatchQueue.main.async {
                if let button = self.statusItem.button {
                    let downStr = self.formatSpeed(decoded.speed_in)
                    let upStr = self.formatSpeed(decoded.speed_out)
                    button.title = "IN \(downStr)   OUT \(upStr)"
                }

                let t = decoded.summaries.today
                let w = decoded.summaries.this_week
                let m = decoded.summaries.this_month

                self.todayItem.title = "Dnes: \(self.formatBytes(t.total))  (IN \(self.formatBytes(t.bytes_in)) / OUT \(self.formatBytes(t.bytes_out)))"
                self.weekItem.title  = "Týždeň: \(self.formatBytes(w.total))  (IN \(self.formatBytes(w.bytes_in)) / OUT \(self.formatBytes(w.bytes_out)))"
                self.monthItem.title = "Mesiac: \(self.formatBytes(m.total))  (IN \(self.formatBytes(m.bytes_in)) / OUT \(self.formatBytes(m.bytes_out)))"

                let apps = decoded.live_apps
                let slots = [self.topApp1, self.topApp2, self.topApp3]
                for i in 0..<3 {
                    if i < apps.count {
                        let a = apps[i]
                        let spd = a.speed_in + a.speed_out
                        let spdTxt = spd > 100 ? " [\(self.formatSpeed(spd))]" : ""
                        slots[i].title = "\(i + 1). \(a.app_name): \(self.formatBytes(a.session_total))\(spdTxt)"
                    } else {
                        slots[i].title = "—"
                    }
                }
            }
        }
        task.resume()
    }

    @objc func showMainWindow() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reloadWebView() {
        webView.reload()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Native File Save Handler for CSV / JSON Export
class ExportScriptHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: String],
              let filename = dict["filename"],
              let content = dict["content"] else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = filename
        savePanel.canCreateDirectories = true
        savePanel.title = "Exportovať štatistiky NetPulse"

        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                try? content.write(to: targetURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
