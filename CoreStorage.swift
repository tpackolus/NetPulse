import Cocoa
import Foundation
import SQLite3

// MARK: - Data Models
struct TrafficMetrics: Codable {
    var bytes_in: Int64 = 0
    var bytes_out: Int64 = 0
    var total: Int64 = 0
}

struct Summaries: Codable {
    var today = TrafficMetrics()
    var yesterday = TrafficMetrics()
    var this_week = TrafficMetrics()
    var last_7_days = TrafficMetrics()
    var this_month = TrafficMetrics()
    var last_30_days = TrafficMetrics()
    var this_year = TrafficMetrics()
    var all_time = TrafficMetrics()
}

struct TimelineRow: Codable {
    let label: String
    let bytes_in: Int64
    let bytes_out: Int64
    let total: Int64
}

struct AppRow: Codable {
    let app_name: String
    var speed_in: Double = 0
    var speed_out: Double = 0
    var bytes_in: Int64 = 0
    var bytes_out: Int64 = 0
    var total: Int64 = 0
    var pids: [Int] = []
}

struct InterfaceRow: Codable {
    let interface: String
    let label: String
    let speed_in: Double
    let speed_out: Double
    let boot_bytes_in: Int64
    let boot_bytes_out: Int64
    let boot_total: Int64
    let is_loopback: Bool
}

struct ConnectionRow: Codable {
    let command: String
    let pid: String
    let proto: String
    let local_addr: String
    let remote_addr: String
    let remote_ip: String
    let state: String
    var geo_org: String = "—"
    var country_code: String = ""
    var country_flag: String = "🌐"
    var country_name: String = "—"
    var asn_isp: String = "—"
    var service_port: String = "—"
    var security_status: String = "verified"
    var security_label: String = "Verified"
}

struct DiagnosticsInfo: Codable {
    var local_ip: String = "—"
    var router_ip: String = "—"
    var public_ip: String = "—"
    var isp_org: String = "—"
    var country_city: String = "—"
    var network_profile: String = "Wi-Fi / LAN"
    var ping_router_ms: Double = -1
    var ping_internet_ms: Double = -1
    var vpn_active: Bool = false
    var db_path: String = ""
    var db_size_kb: Int64 = 0
    var speedtest_down_mbps: Double = 0
    var speedtest_running: Bool = false
    var app_version: String = "2.3.3"
    var latest_version: String = "2.3.3"
    var update_available: Bool = false
    var update_checking: Bool = false
    var update_installing: Bool = false
    var update_status: String = "Up to date (v2.3.3)"
    var update_notes: String = ""
}

struct WiFiUsageRow: Codable {
    let ssid: String
    let is_active: Bool
    let is_saved_only: Bool
    let today_in: Int64
    let today_out: Int64
    let today_total: Int64
    let week_total: Int64
    let month_total: Int64
    let all_in: Int64
    let all_out: Int64
    let all_total: Int64
    let last_seen: String
}

struct RealtimePoint: Codable {
    let timestamp: Int64
    let time_str: String
    let speed_in: Double
    let speed_out: Double
}

// MARK: - SQLite Native Storage Manager
final class SQLiteManager {
    static let shared = SQLiteManager()
    let dbPath: String
    let legacyDbPath: String
    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let appDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let localDb = (appDir as NSString).appendingPathComponent("netpulse_data.db")
        self.legacyDbPath = localDb

        let targetDb = folder.appendingPathComponent("netpulse_data.db").path
        if !FileManager.default.fileExists(atPath: targetDb) && FileManager.default.fileExists(atPath: localDb) {
            try? FileManager.default.copyItem(atPath: localDb, toPath: targetDb)
        }

        var testDb: OpaquePointer?
        if sqlite3_open_v2(targetDb, &testDb, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            self.dbPath = targetDb
            self.db = testDb
        } else {
            if let testDb = testDb { sqlite3_close(testDb) }
            self.dbPath = localDb
            sqlite3_open_v2(localDb, &self.db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        }

        execSQL("PRAGMA journal_mode=WAL;")
        execSQL("PRAGMA synchronous=NORMAL;")
        initTables()
    }

    private func execSQL(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &errMsg)
        if let errMsg = errMsg {
            sqlite3_free(errMsg)
        }
    }

    private func initTables() {
        lock.lock()
        defer { lock.unlock() }

        execSQL("""
            CREATE TABLE IF NOT EXISTS interface_traffic (
                date TEXT NOT NULL,
                hour INTEGER NOT NULL,
                interface TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                packets_in INTEGER NOT NULL DEFAULT 0,
                packets_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date, hour, interface)
            );
            CREATE INDEX IF NOT EXISTS idx_iface_date ON interface_traffic(date);

            CREATE TABLE IF NOT EXISTS app_traffic (
                date TEXT NOT NULL,
                hour INTEGER NOT NULL,
                app_name TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date, hour, app_name)
            );
            CREATE INDEX IF NOT EXISTS idx_app_date ON app_traffic(date);

            CREATE TABLE IF NOT EXISTS profile_traffic (
                date TEXT NOT NULL,
                profile TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date, profile)
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """)

        let defaults: [String: String] = [
            "daily_limit_gb": "0",
            "weekly_limit_gb": "0",
            "monthly_limit_gb": "500",
            "alert_threshold_pct": "85",
            "launch_at_login": "1"
        ]
        for (k, v) in defaults {
            var stmt: OpaquePointer?
            let sql = "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (k as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (v as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        syncToWorkspaceIfPossible()
    }

    func syncToWorkspaceIfPossible() {
        if dbPath != legacyDbPath && FileManager.default.fileExists(atPath: legacyDbPath) {
            execSQL("ATTACH DATABASE '\(legacyDbPath)' AS legacy_db;")
            execSQL("""
                INSERT INTO interface_traffic (date, hour, interface, bytes_in, bytes_out, packets_in, packets_out)
                SELECT date, hour, interface, bytes_in, bytes_out, packets_in, packets_out FROM legacy_db.interface_traffic
                WHERE true
                ON CONFLICT(date, hour, interface) DO UPDATE SET
                    bytes_in = MAX(interface_traffic.bytes_in, excluded.bytes_in),
                    bytes_out = MAX(interface_traffic.bytes_out, excluded.bytes_out);
            """)
            execSQL("""
                INSERT INTO app_traffic (date, hour, app_name, bytes_in, bytes_out)
                SELECT date, hour, app_name, bytes_in, bytes_out FROM legacy_db.app_traffic
                WHERE true
                ON CONFLICT(date, hour, app_name) DO UPDATE SET
                    bytes_in = MAX(app_traffic.bytes_in, excluded.bytes_in),
                    bytes_out = MAX(app_traffic.bytes_out, excluded.bytes_out);
            """)
            execSQL("DETACH DATABASE legacy_db;")
        }
    }

    func getDatabaseFileSizeKB() -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? NSNumber {
            return max(1, size.int64Value / 1024)
        }
        return 0
    }

    func recordDelta(
        dateStr: String,
        hour: Int,
        profile: String,
        ifaceDeltas: [String: (Int64, Int64, Int64, Int64)],
        appDeltas: [String: (Int64, Int64)],
        totalIn: Int64,
        totalOut: Int64
    ) {
        lock.lock()
        defer { lock.unlock() }

        execSQL("BEGIN TRANSACTION;")

        let ifaceSQL = """
            INSERT INTO interface_traffic (date, hour, interface, bytes_in, bytes_out, packets_in, packets_out)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date, hour, interface) DO UPDATE SET
                bytes_in = bytes_in + excluded.bytes_in,
                bytes_out = bytes_out + excluded.bytes_out,
                packets_in = packets_in + excluded.packets_in,
                packets_out = packets_out + excluded.packets_out;
        """
        for (iface, (bi, bo, pi, po)) in ifaceDeltas {
            if bi <= 0 && bo <= 0 { continue }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, ifaceSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(hour))
                sqlite3_bind_text(stmt, 3, (iface as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 4, bi)
                sqlite3_bind_int64(stmt, 5, bo)
                sqlite3_bind_int64(stmt, 6, pi)
                sqlite3_bind_int64(stmt, 7, po)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        let appSQL = """
            INSERT INTO app_traffic (date, hour, app_name, bytes_in, bytes_out)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(date, hour, app_name) DO UPDATE SET
                bytes_in = bytes_in + excluded.bytes_in,
                bytes_out = bytes_out + excluded.bytes_out;
        """
        for (appName, (bi, bo)) in appDeltas {
            if bi <= 0 && bo <= 0 { continue }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, appSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(hour))
                sqlite3_bind_text(stmt, 3, (appName as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 4, bi)
                sqlite3_bind_int64(stmt, 5, bo)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        if totalIn > 0 || totalOut > 0 {
            let profSQL = """
                INSERT INTO profile_traffic (date, profile, bytes_in, bytes_out)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(date, profile) DO UPDATE SET
                    bytes_in = bytes_in + excluded.bytes_in,
                    bytes_out = bytes_out + excluded.bytes_out;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, profSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (profile as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 3, totalIn)
                sqlite3_bind_int64(stmt, 4, totalOut)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        execSQL("COMMIT;")
    }

    private func queryRange(start: String, end: String, ifaceFilter: String) -> TrafficMetrics {
        let clause = (ifaceFilter != "all" && !ifaceFilter.isEmpty) ? "AND interface = ?" : "AND interface != 'lo0'"
        let sql = """
            SELECT COALESCE(SUM(bytes_in), 0), COALESCE(SUM(bytes_out), 0)
            FROM interface_traffic
            WHERE date >= ? AND date <= ? \(clause);
        """
        var stmt: OpaquePointer?
        var m = TrafficMetrics()
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (start as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (end as NSString).utf8String, -1, nil)
            if ifaceFilter != "all" && !ifaceFilter.isEmpty {
                sqlite3_bind_text(stmt, 3, (ifaceFilter as NSString).utf8String, -1, nil)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                m.bytes_in = sqlite3_column_int64(stmt, 0)
                m.bytes_out = sqlite3_column_int64(stmt, 1)
                m.total = m.bytes_in + m.bytes_out
            }
        }
        sqlite3_finalize(stmt)
        return m
    }

    func getSummaries(ifaceFilter: String = "all") -> Summaries {
        lock.lock()
        defer { lock.unlock() }

        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let todayStr = fmt.string(from: now)
        let yesterdayStr = fmt.string(from: cal.date(byAdding: .day, value: -1, to: now)!)
        let last7dStr = fmt.string(from: cal.date(byAdding: .day, value: -6, to: now)!)
        let last30dStr = fmt.string(from: cal.date(byAdding: .day, value: -29, to: now)!)

        let weekday = cal.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        let startOfWeekStr = fmt.string(from: cal.date(byAdding: .day, value: -daysFromMonday, to: now)!)

        let comps = cal.dateComponents([.year, .month], from: now)
        let startOfMonthStr = String(format: "%04d-%02d-01", comps.year ?? 2026, comps.month ?? 1)
        let startOfYearStr = String(format: "%04d-01-01", comps.year ?? 2026)

        var s = Summaries()
        s.today = queryRange(start: todayStr, end: todayStr, ifaceFilter: ifaceFilter)
        s.yesterday = queryRange(start: yesterdayStr, end: yesterdayStr, ifaceFilter: ifaceFilter)
        s.this_week = queryRange(start: startOfWeekStr, end: todayStr, ifaceFilter: ifaceFilter)
        s.last_7_days = queryRange(start: last7dStr, end: todayStr, ifaceFilter: ifaceFilter)
        s.this_month = queryRange(start: startOfMonthStr, end: todayStr, ifaceFilter: ifaceFilter)
        s.last_30_days = queryRange(start: last30dStr, end: todayStr, ifaceFilter: ifaceFilter)
        s.this_year = queryRange(start: startOfYearStr, end: todayStr, ifaceFilter: ifaceFilter)
        s.all_time = queryRange(start: "2000-01-01", end: "2099-12-31", ifaceFilter: ifaceFilter)
        return s
    }

    func queryHistory(start: String, end: String, groupBy: String, ifaceFilter: String) -> (timeline: [TimelineRow], apps: [AppRow], totalIn: Int64, totalOut: Int64) {
        lock.lock()
        defer { lock.unlock() }

        let clause = (ifaceFilter != "all" && !ifaceFilter.isEmpty) ? "AND interface = ?" : "AND interface != 'lo0'"
        var timeline: [TimelineRow] = []

        let sql: String
        if groupBy == "hour" {
            sql = """
                SELECT date || ' ' || printf('%02d:00', hour) AS lbl,
                       SUM(bytes_in), SUM(bytes_out)
                FROM interface_traffic
                WHERE date >= ? AND date <= ? \(clause)
                GROUP BY date, hour
                ORDER BY date ASC, hour ASC;
            """
        } else if groupBy == "month" {
            sql = """
                SELECT SUBSTR(date, 1, 7) AS lbl,
                       SUM(bytes_in), SUM(bytes_out)
                FROM interface_traffic
                WHERE date >= ? AND date <= ? \(clause)
                GROUP BY lbl
                ORDER BY lbl ASC;
            """
        } else {
            sql = """
                SELECT date AS lbl,
                       SUM(bytes_in), SUM(bytes_out)
                FROM interface_traffic
                WHERE date >= ? AND date <= ? \(clause)
                GROUP BY lbl
                ORDER BY lbl ASC;
            """
        }

        var rawMap: [String: (Int64, Int64)] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (start as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (end as NSString).utf8String, -1, nil)
            if ifaceFilter != "all" && !ifaceFilter.isEmpty {
                sqlite3_bind_text(stmt, 3, (ifaceFilter as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let lbl = String(cString: sqlite3_column_text(stmt, 0))
                let bi = sqlite3_column_int64(stmt, 1)
                let bo = sqlite3_column_int64(stmt, 2)
                rawMap[lbl] = (bi, bo)
            }
        }
        sqlite3_finalize(stmt)

        // Generate complete continuous timeline slots (e.g. full 24 hours 00:00..23:00 for a day)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current

        if groupBy == "hour", let startDate = fmt.date(from: start), let endDate = fmt.date(from: end) {
            var cur = startDate
            while cur <= endDate {
                let dStr = fmt.string(from: cur)
                for h in 0..<24 {
                    let key = String(format: "%@ %02d:00", dStr, h)
                    let (bi, bo) = rawMap[key] ?? (0, 0)
                    timeline.append(TimelineRow(label: key, bytes_in: bi, bytes_out: bo, total: bi + bo))
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
                cur = next
            }
        } else if groupBy == "day", let startDate = fmt.date(from: start), let endDate = fmt.date(from: end) {
            var cur = startDate
            while cur <= endDate {
                let key = fmt.string(from: cur)
                let (bi, bo) = rawMap[key] ?? (0, 0)
                timeline.append(TimelineRow(label: key, bytes_in: bi, bytes_out: bo, total: bi + bo))
                guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
                cur = next
            }
        } else if groupBy == "month" {
            let yearPrefix = String(start.prefix(4))
            for m in 1...12 {
                let key = String(format: "%@-%02d", yearPrefix, m)
                let (bi, bo) = rawMap[key] ?? (0, 0)
                timeline.append(TimelineRow(label: key, bytes_in: bi, bytes_out: bo, total: bi + bo))
            }
        } else {
            for (k, (bi, bo)) in rawMap.sorted(by: { $0.key < $1.key }) {
                timeline.append(TimelineRow(label: k, bytes_in: bi, bytes_out: bo, total: bi + bo))
            }
        }

        // Top apps in range
        var apps: [AppRow] = []
        let appSQL = """
            SELECT app_name, SUM(bytes_in), SUM(bytes_out)
            FROM app_traffic
            WHERE date >= ? AND date <= ?
            GROUP BY app_name
            ORDER BY (SUM(bytes_in) + SUM(bytes_out)) DESC
            LIMIT 60;
        """
        var appStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, appSQL, -1, &appStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(appStmt, 1, (start as NSString).utf8String, -1, nil)
            sqlite3_bind_text(appStmt, 2, (end as NSString).utf8String, -1, nil)
            while sqlite3_step(appStmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(appStmt, 0))
                let bi = sqlite3_column_int64(appStmt, 1)
                let bo = sqlite3_column_int64(appStmt, 2)
                apps.append(AppRow(app_name: name, bytes_in: bi, bytes_out: bo, total: bi + bo))
            }
        }
        sqlite3_finalize(appStmt)

        let totalIn = timeline.reduce(0) { $0 + $1.bytes_in }
        let totalOut = timeline.reduce(0) { $0 + $1.bytes_out }
        return (timeline, apps, totalIn, totalOut)
    }

    func queryAppHourlyHistory(appName: String, dateStr: String) -> [TimelineRow] {
        lock.lock()
        defer { lock.unlock() }
        var rawMap: [Int: (Int64, Int64)] = [:]
        let sql = """
            SELECT hour, SUM(bytes_in), SUM(bytes_out)
            FROM app_traffic
            WHERE date = ? AND app_name = ?
            GROUP BY hour
            ORDER BY hour ASC;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (appName as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let h = Int(sqlite3_column_int(stmt, 0))
                let bi = sqlite3_column_int64(stmt, 1)
                let bo = sqlite3_column_int64(stmt, 2)
                rawMap[h] = (bi, bo)
            }
        }
        sqlite3_finalize(stmt)

        var rows: [TimelineRow] = []
        for h in 0..<24 {
            let lbl = String(format: "%02d:00", h)
            let (bi, bo) = rawMap[h] ?? (0, 0)
            rows.append(TimelineRow(label: lbl, bytes_in: bi, bytes_out: bo, total: bi + bo))
        }
        return rows
    }

    func attributeGenericWiFiRowsIfNeeded(activeSSID: String) {
        let genericNames: Set<String> = ["Wi-Fi (en0)", "Wi-Fi / LAN", "Wi-Fi", "—", ""]
        guard !genericNames.contains(activeSSID) else { return }

        lock.lock()
        defer { lock.unlock() }

        let mergeSQL = """
            INSERT INTO profile_traffic (date, profile, bytes_in, bytes_out)
            SELECT date, ?, SUM(bytes_in), SUM(bytes_out)
            FROM profile_traffic
            WHERE profile IN ('Wi-Fi (en0)', 'Wi-Fi / LAN')
            GROUP BY date
            ON CONFLICT(date, profile) DO UPDATE SET
                bytes_in = profile_traffic.bytes_in + excluded.bytes_in,
                bytes_out = profile_traffic.bytes_out + excluded.bytes_out;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, mergeSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (activeSSID as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        execSQL("DELETE FROM profile_traffic WHERE profile IN ('Wi-Fi (en0)', 'Wi-Fi / LAN');")
    }

    func getWiFiUsage(activeProfile: String, preferredSSIDs: [String] = []) -> [WiFiUsageRow] {
        lock.lock()
        defer { lock.unlock() }

        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let todayStr = fmt.string(from: now)

        let weekday = cal.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        let startOfWeekStr = fmt.string(from: cal.date(byAdding: .day, value: -daysFromMonday, to: now)!)

        let comps = cal.dateComponents([.year, .month], from: now)
        let startOfMonthStr = String(format: "%04d-%02d-01", comps.year ?? 2026, comps.month ?? 1)

        let sql = """
            SELECT
                profile,
                COALESCE(SUM(CASE WHEN date = ? THEN bytes_in ELSE 0 END), 0) AS today_in,
                COALESCE(SUM(CASE WHEN date = ? THEN bytes_out ELSE 0 END), 0) AS today_out,
                COALESCE(SUM(CASE WHEN date >= ? THEN bytes_in + bytes_out ELSE 0 END), 0) AS week_total,
                COALESCE(SUM(CASE WHEN date >= ? THEN bytes_in + bytes_out ELSE 0 END), 0) AS month_total,
                COALESCE(SUM(bytes_in), 0) AS all_in,
                COALESCE(SUM(bytes_out), 0) AS all_out,
                COALESCE(MAX(date), '') AS last_seen
            FROM profile_traffic
            GROUP BY profile
            ORDER BY (SUM(bytes_in) + SUM(bytes_out)) DESC;
        """

        var rows: [WiFiUsageRow] = []
        var seenSSIDs = Set<String>()
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (todayStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (todayStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (startOfWeekStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (startOfMonthStr as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let profPtr = sqlite3_column_text(stmt, 0) else { continue }
                let ssid = String(cString: profPtr)
                let tIn = sqlite3_column_int64(stmt, 1)
                let tOut = sqlite3_column_int64(stmt, 2)
                let wTot = sqlite3_column_int64(stmt, 3)
                let mTot = sqlite3_column_int64(stmt, 4)
                let aIn = sqlite3_column_int64(stmt, 5)
                let aOut = sqlite3_column_int64(stmt, 6)
                let lastSeen = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? todayStr

                let isActive = (ssid == activeProfile)
                seenSSIDs.insert(ssid)
                rows.append(WiFiUsageRow(
                    ssid: ssid,
                    is_active: isActive,
                    is_saved_only: false,
                    today_in: tIn,
                    today_out: tOut,
                    today_total: tIn + tOut,
                    week_total: wTot,
                    month_total: mTot,
                    all_in: aIn,
                    all_out: aOut,
                    all_total: aIn + aOut,
                    last_seen: isActive ? "Active Now" : lastSeen
                ))
            }
        }
        sqlite3_finalize(stmt)

        let cleanActive = activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanActive.isEmpty && cleanActive != "—" && !seenSSIDs.contains(cleanActive) {
            seenSSIDs.insert(cleanActive)
            rows.insert(WiFiUsageRow(
                ssid: cleanActive,
                is_active: true,
                is_saved_only: false,
                today_in: 0,
                today_out: 0,
                today_total: 0,
                week_total: 0,
                month_total: 0,
                all_in: 0,
                all_out: 0,
                all_total: 0,
                last_seen: "Active Now"
            ), at: 0)
        }

        for savedSSID in preferredSSIDs {
            let trimmed = savedSSID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seenSSIDs.contains(trimmed) else { continue }
            seenSSIDs.insert(trimmed)
            rows.append(WiFiUsageRow(
                ssid: trimmed,
                is_active: false,
                is_saved_only: true,
                today_in: 0,
                today_out: 0,
                today_total: 0,
                week_total: 0,
                month_total: 0,
                all_in: 0,
                all_out: 0,
                all_total: 0,
                last_seen: "Saved Wi-Fi"
            ))
        }

        rows.sort { a, b in
            if a.is_active != b.is_active { return a.is_active }
            if a.is_saved_only != b.is_saved_only { return !a.is_saved_only }
            return a.all_total > b.all_total
        }
        return rows
    }

    func getSettings() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var res: [String: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key, value FROM settings;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let k = String(cString: sqlite3_column_text(stmt, 0))
                let v = String(cString: sqlite3_column_text(stmt, 1))
                res[k] = v
            }
        }
        sqlite3_finalize(stmt)
        return res
    }

    func updateSettings(_ dict: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        let sql = "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?);"
        for (k, v) in dict {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (k as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (v as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
}
