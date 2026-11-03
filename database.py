#!/usr/bin/env python3
"""
NetPulse macOS - Database & Storage Manager (SQLite)
Stores real-time samples, hourly/daily interface & per-app statistics, and user alerts/settings.
"""

import sqlite3
import os
import time
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional, Tuple
import threading

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "netpulse_data.db")


class NetPulseDB:
    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path
        self._lock = threading.Lock()
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=15.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        return conn

    def _init_db(self):
        with self._lock:
            conn = self._get_conn()
            try:
                cur = conn.cursor()
                # 1. Hourly & Daily Interface Traffic
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS interface_traffic (
                        date TEXT NOT NULL,
                        hour INTEGER NOT NULL,
                        interface TEXT NOT NULL,
                        bytes_in INTEGER NOT NULL DEFAULT 0,
                        bytes_out INTEGER NOT NULL DEFAULT 0,
                        packets_in INTEGER NOT NULL DEFAULT 0,
                        packets_out INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY (date, hour, interface)
                    )
                """)
                cur.execute("CREATE INDEX IF NOT EXISTS idx_iface_date ON interface_traffic(date);")

                # 2. Per-Application Daily Traffic
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS app_traffic (
                        date TEXT NOT NULL,
                        hour INTEGER NOT NULL,
                        app_name TEXT NOT NULL,
                        bytes_in INTEGER NOT NULL DEFAULT 0,
                        bytes_out INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY (date, hour, app_name)
                    )
                """)
                cur.execute("CREATE INDEX IF NOT EXISTS idx_app_date ON app_traffic(date);")

                # 3. Fine-grained samples (10-second intervals, kept for last 48 hours for smooth live/intraday charts)
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS traffic_samples (
                        timestamp INTEGER PRIMARY KEY,
                        bytes_in INTEGER NOT NULL,
                        bytes_out INTEGER NOT NULL,
                        speed_in REAL NOT NULL,
                        speed_out REAL NOT NULL,
                        top_app TEXT
                    )
                """)

                # 4. Settings & Data Caps / Alerts
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS settings (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                """)

                # Default settings
                defaults = {
                    "daily_limit_gb": "0",       # 0 = disabled
                    "weekly_limit_gb": "0",
                    "monthly_limit_gb": "500",   # 500 GB default visual cap
                    "primary_interface": "auto", # auto or specific e.g. en0
                    "alert_threshold_pct": "85",
                    "menubar_enabled": "1"
                }
                for k, v in defaults.items():
                    cur.execute("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)", (k, v))

                conn.commit()
            finally:
                conn.close()

    def record_delta(
        self,
        timestamp: float,
        iface_deltas: Dict[str, Tuple[int, int, int, int]],
        app_deltas: Dict[str, Tuple[int, int]],
        total_in: int,
        total_out: int,
        speed_in: float,
        speed_out: float,
        top_app: str = "",
        record_sample: bool = False
    ):
        """
        Records incremental bytes transferred since the last tick.
        iface_deltas: {iface_name: (d_bytes_in, d_bytes_out, d_pkts_in, d_pkts_out)}
        app_deltas: {app_name: (d_bytes_in, d_bytes_out)}
        """
        dt = datetime.fromtimestamp(timestamp)
        date_str = dt.strftime("%Y-%m-%d")
        hour_int = dt.hour
        ts_int = int(timestamp)

        with self._lock:
            conn = self._get_conn()
            try:
                cur = conn.cursor()

                # Upsert interface traffic
                for iface, (bi, bo, pi, po) in iface_deltas.items():
                    if bi <= 0 and bo <= 0:
                        continue
                    cur.execute("""
                        INSERT INTO interface_traffic (date, hour, interface, bytes_in, bytes_out, packets_in, packets_out)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(date, hour, interface) DO UPDATE SET
                            bytes_in = bytes_in + excluded.bytes_in,
                            bytes_out = bytes_out + excluded.bytes_out,
                            packets_in = packets_in + excluded.packets_in,
                            packets_out = packets_out + excluded.packets_out
                    """, (date_str, hour_int, iface, bi, bo, pi, po))

                # Upsert application traffic
                for app_name, (bi, bo) in app_deltas.items():
                    if bi <= 0 and bo <= 0:
                        continue
                    cur.execute("""
                        INSERT INTO app_traffic (date, hour, app_name, bytes_in, bytes_out)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(date, hour, app_name) DO UPDATE SET
                            bytes_in = bytes_in + excluded.bytes_in,
                            bytes_out = bytes_out + excluded.bytes_out
                    """, (date_str, hour_int, app_name, bi, bo))

                # Optional fine-grained sample
                if record_sample:
                    cur.execute("""
                        INSERT OR REPLACE INTO traffic_samples (timestamp, bytes_in, bytes_out, speed_in, speed_out, top_app)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """, (ts_int, total_in, total_out, speed_in, speed_out, top_app))

                    # Prune samples older than 7 days
                    cutoff = ts_int - (7 * 86400)
                    cur.execute("DELETE FROM traffic_samples WHERE timestamp < ?", (cutoff,))

                conn.commit()
            finally:
                conn.close()

    def get_summary_periods(self, interface_filter: Optional[str] = None) -> Dict[str, Dict[str, int]]:
        """
        Returns total bytes_in, bytes_out, total for:
        - today
        - yesterday
        - week (last 7 days including today, plus current ISO week)
        - month (current calendar month, plus last 30 days)
        - year (current calendar year)
        - all_time
        """
        now = datetime.now()
        today_str = now.strftime("%Y-%m-%d")
        yesterday_str = (now - timedelta(days=1)).strftime("%Y-%m-%d")
        # Start of current ISO week (Monday)
        start_of_week = (now - timedelta(days=now.weekday())).strftime("%Y-%m-%d")
        last_7d_str = (now - timedelta(days=6)).strftime("%Y-%m-%d")
        start_of_month = now.strftime("%Y-%m-01")
        last_30d_str = (now - timedelta(days=29)).strftime("%Y-%m-%d")
        start_of_year = now.strftime("%Y-01-01")

        iface_clause = "AND interface = ?" if (interface_filter and interface_filter != "all") else "AND interface != 'lo0'"
        iface_params = [interface_filter] if (interface_filter and interface_filter != "all") else []

        def query_range(start_date: str, end_date: str) -> Dict[str, int]:
            sql = f"""
                SELECT COALESCE(SUM(bytes_in), 0) AS bi,
                       COALESCE(SUM(bytes_out), 0) AS bo,
                       COALESCE(SUM(packets_in), 0) AS pi,
                       COALESCE(SUM(packets_out), 0) AS po
                FROM interface_traffic
                WHERE date >= ? AND date <= ? {iface_clause}
            """
            cur.execute(sql, [start_date, end_date] + iface_params)
            row = cur.fetchone()
            bi = int(row["bi"])
            bo = int(row["bo"])
            return {
                "bytes_in": bi,
                "bytes_out": bo,
                "total": bi + bo,
                "packets_in": int(row["pi"]),
                "packets_out": int(row["po"]),
            }

        with self._lock:
            conn = self._get_conn()
            try:
                cur = conn.cursor()
                return {
                    "today": query_range(today_str, today_str),
                    "yesterday": query_range(yesterday_str, yesterday_str),
                    "this_week": query_range(start_of_week, today_str),
                    "last_7_days": query_range(last_7d_str, today_str),
                    "this_month": query_range(start_of_month, today_str),
                    "last_30_days": query_range(last_30d_str, today_str),
                    "this_year": query_range(start_of_year, today_str),
                    "all_time": query_range("2000-01-01", "2099-12-31"),
                }
            finally:
                conn.close()

    def query_history(
        self,
        start_date: str,
        end_date: str,
        group_by: str = "day",  # 'hour', 'day', 'month'
        interface_filter: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Queries historical data for charts, tables, and custom date ranges.
        Returns timeline series, interface breakdown, and top applications in that period.
        """
        iface_clause = "AND interface = ?" if (interface_filter and interface_filter != "all") else "AND interface != 'lo0'"
        iface_params = [interface_filter] if (interface_filter and interface_filter != "all") else []

        with self._lock:
            conn = self._get_conn()
            try:
                cur = conn.cursor()

                # 1. Timeline series
                if group_by == "hour":
                    cur.execute(f"""
                        SELECT date, hour,
                               SUM(bytes_in) AS bytes_in,
                               SUM(bytes_out) AS bytes_out
                        FROM interface_traffic
                        WHERE date >= ? AND date <= ? {iface_clause}
                        GROUP BY date, hour
                        ORDER BY date ASC, hour ASC
                    """, [start_date, end_date] + iface_params)
                    timeline = [
                        {
                            "label": f"{r['date']} {int(r['hour']):02d}:00",
                            "date": r["date"],
                            "hour": r["hour"],
                            "bytes_in": int(r["bytes_in"]),
                            "bytes_out": int(r["bytes_out"]),
                            "total": int(r["bytes_in"]) + int(r["bytes_out"])
                        }
                        for r in cur.fetchall()
                    ]
                elif group_by == "month":
                    cur.execute(f"""
                        SELECT SUBSTR(date, 1, 7) AS month_label,
                               SUM(bytes_in) AS bytes_in,
                               SUM(bytes_out) AS bytes_out
                        FROM interface_traffic
                        WHERE date >= ? AND date <= ? {iface_clause}
                        GROUP BY month_label
                        ORDER BY month_label ASC
                    """, [start_date, end_date] + iface_params)
                    timeline = [
                        {
                            "label": r["month_label"],
                            "bytes_in": int(r["bytes_in"]),
                            "bytes_out": int(r["bytes_out"]),
                            "total": int(r["bytes_in"]) + int(r["bytes_out"])
                        }
                        for r in cur.fetchall()
                    ]
                else:  # 'day'
                    cur.execute(f"""
                        SELECT date AS day_label,
                               SUM(bytes_in) AS bytes_in,
                               SUM(bytes_out) AS bytes_out
                        FROM interface_traffic
                        WHERE date >= ? AND date <= ? {iface_clause}
                        GROUP BY day_label
                        ORDER BY day_label ASC
                    """, [start_date, end_date] + iface_params)
                    timeline = [
                        {
                            "label": r["day_label"],
                            "bytes_in": int(r["bytes_in"]),
                            "bytes_out": int(r["bytes_out"]),
                            "total": int(r["bytes_in"]) + int(r["bytes_out"])
                        }
                        for r in cur.fetchall()
                    ]

                # 2. Interface breakdown for the range
                cur.execute("""
                    SELECT interface,
                           SUM(bytes_in) AS bytes_in,
                           SUM(bytes_out) AS bytes_out,
                           SUM(packets_in) AS packets_in,
                           SUM(packets_out) AS packets_out
                    FROM interface_traffic
                    WHERE date >= ? AND date <= ?
                    GROUP BY interface
                    ORDER BY (SUM(bytes_in) + SUM(bytes_out)) DESC
                """, [start_date, end_date])
                interfaces = [
                    {
                        "interface": r["interface"],
                        "bytes_in": int(r["bytes_in"]),
                        "bytes_out": int(r["bytes_out"]),
                        "total": int(r["bytes_in"]) + int(r["bytes_out"]),
                        "packets_in": int(r["packets_in"]),
                        "packets_out": int(r["packets_out"]),
                    }
                    for r in cur.fetchall()
                ]

                # 3. Top applications for the range
                cur.execute("""
                    SELECT app_name,
                           SUM(bytes_in) AS bytes_in,
                           SUM(bytes_out) AS bytes_out
                    FROM app_traffic
                    WHERE date >= ? AND date <= ?
                    GROUP BY app_name
                    ORDER BY (SUM(bytes_in) + SUM(bytes_out)) DESC
                    LIMIT 50
                """, [start_date, end_date])
                apps = [
                    {
                        "app_name": r["app_name"],
                        "bytes_in": int(r["bytes_in"]),
                        "bytes_out": int(r["bytes_out"]),
                        "total": int(r["bytes_in"]) + int(r["bytes_out"])
                    }
                    for r in cur.fetchall()
                ]

                # Totals for the queried range
                total_in = sum(item["bytes_in"] for item in timeline)
                total_out = sum(item["bytes_out"] for item in timeline)
                peak_item = max(timeline, key=lambda x: x["total"]) if timeline else None

                return {
                    "start_date": start_date,
                    "end_date": end_date,
                    "group_by": group_by,
                    "interface_filter": interface_filter or "all",
                    "totals": {
                        "bytes_in": total_in,
                        "bytes_out": total_out,
                        "total": total_in + total_out,
                        "days_count": max(1, len(set(x.get("date", x["label"]) for x in timeline))),
                        "peak": peak_item
                    },
                    "timeline": timeline,
                    "interfaces": interfaces,
                    "apps": apps
                }
            finally:
                conn.close()

    def get_settings(self) -> Dict[str, str]:
        with self._lock:
            conn = self._get_conn()
            try:
                cur = conn.cursor()
                cur.execute("SELECT key, value FROM settings")
                return {r["key"]: r["value"] for r in cur.fetchall()}
            finally:
                conn.close()

    def update_settings(self, new_settings: Dict[str, Any]) -> Dict[str, str]:
        with self._lock:
            conn = self._get_conn()
            try:
                cur = conn.cursor()
                for k, v in new_settings.items():
                    cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (str(k), str(v)))
                conn.commit()
            finally:
                conn.close()
        return self.get_settings()
