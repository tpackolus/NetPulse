#!/usr/bin/env python3
"""
NetPulse macOS - Web Server & REST API
Serves the interactive Web Dashboard and provides JSON/CSV endpoints for real-time & historical data.
"""

import json
import os
import sys
import csv
import io
import webbrowser
from datetime import datetime, timedelta
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

from database import NetPulseDB
from collector import NetworkCollector

PORT = int(os.environ.get("NETPULSE_PORT", "8765"))
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

db = NetPulseDB()
collector = NetworkCollector(db)


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class NetPulseHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress noisy per-second polling logs
        pass

    def _send_json(self, data: dict, status: int = 200):
        raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/api/realtime":
            iface = qs.get("interface", ["all"])[0]
            data = collector.get_realtime_snapshot(interface_filter=iface)
            return self._send_json(data)

        if path == "/api/history":
            now = datetime.now()
            preset = qs.get("preset", ["custom"])[0]
            iface = qs.get("interface", ["all"])[0]
            group_by = qs.get("group_by", ["auto"])[0]

            if preset == "today":
                start_date = now.strftime("%Y-%m-%d")
                end_date = start_date
                if group_by == "auto":
                    group_by = "hour"
            elif preset == "yesterday":
                yd = (now - timedelta(days=1)).strftime("%Y-%m-%d")
                start_date, end_date = yd, yd
                if group_by == "auto":
                    group_by = "hour"
            elif preset == "this_week":
                start_date = (now - timedelta(days=now.weekday())).strftime("%Y-%m-%d")
                end_date = now.strftime("%Y-%m-%d")
                if group_by == "auto":
                    group_by = "day"
            elif preset == "last_7_days":
                start_date = (now - timedelta(days=6)).strftime("%Y-%m-%d")
                end_date = now.strftime("%Y-%m-%d")
                if group_by == "auto":
                    group_by = "day"
            elif preset == "this_month":
                start_date = now.strftime("%Y-%m-01")
                end_date = now.strftime("%Y-%m-%d")
                if group_by == "auto":
                    group_by = "day"
            elif preset == "last_30_days":
                start_date = (now - timedelta(days=29)).strftime("%Y-%m-%d")
                end_date = now.strftime("%Y-%m-%d")
                if group_by == "auto":
                    group_by = "day"
            elif preset == "this_year":
                start_date = now.strftime("%Y-01-01")
                end_date = now.strftime("%Y-%m-%d")
                if group_by == "auto":
                    group_by = "month"
            else:
                start_date = qs.get("start", [(now - timedelta(days=6)).strftime("%Y-%m-%d")])[0]
                end_date = qs.get("end", [now.strftime("%Y-%m-%d")])[0]
                if group_by == "auto":
                    group_by = "hour" if start_date == end_date else "day"

            data = db.query_history(
                start_date=start_date,
                end_date=end_date,
                group_by=group_by,
                interface_filter=iface
            )
            return self._send_json(data)

        if path == "/api/connections":
            limit = int(qs.get("limit", ["40"])[0])
            conns = collector.get_active_connections(limit=limit)
            return self._send_json({"connections": conns})

        if path == "/api/settings":
            return self._send_json({"settings": db.get_settings()})

        if path == "/api/export":
            fmt = qs.get("format", ["csv"])[0].lower()
            start_date = qs.get("start", ["2000-01-01"])[0]
            end_date = qs.get("end", [datetime.now().strftime("%Y-%m-%d")])[0]
            group_by = qs.get("group_by", ["day"])[0]
            iface = qs.get("interface", ["all"])[0]

            hist = db.query_history(
                start_date=start_date,
                end_date=end_date,
                group_by=group_by,
                interface_filter=iface
            )

            if fmt == "json":
                raw = json.dumps(hist, indent=2, ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header(
                    "Content-Disposition",
                    f'attachment; filename="netpulse_export_{start_date}_{end_date}.json"'
                )
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return

            # Default CSV export
            out = io.StringIO()
            writer = csv.writer(out)
            writer.writerow(["# NetPulse macOS Export", f"Od: {start_date}", f"Do: {end_date}", f"Filter: {iface}"])
            writer.writerow([])
            writer.writerow(["--- CASOVA OS (TIMELINE) ---"])
            writer.writerow(["Obdobie", "Download (Bytes)", "Upload (Bytes)", "Spolu (Bytes)", "Download (GB)", "Upload (GB)", "Spolu (GB)"])
            for row in hist["timeline"]:
                bi, bo, tot = row["bytes_in"], row["bytes_out"], row["total"]
                writer.writerow([
                    row["label"],
                    bi,
                    bo,
                    tot,
                    f"{bi / (1024**3):.4f}",
                    f"{bo / (1024**3):.4f}",
                    f"{tot / (1024**3):.4f}",
                ])

            writer.writerow([])
            writer.writerow(["--- PODLA APLIKACII ---"])
            writer.writerow(["Aplikacia", "Download (Bytes)", "Upload (Bytes)", "Spolu (Bytes)", "Spolu (MB)", "Spolu (GB)"])
            for app in hist["apps"]:
                bi, bo, tot = app["bytes_in"], app["bytes_out"], app["total"]
                writer.writerow([
                    app["app_name"],
                    bi,
                    bo,
                    tot,
                    f"{tot / (1024**2):.2f}",
                    f"{tot / (1024**3):.4f}",
                ])

            raw = out.getvalue().encode("utf-8-sig")
            self.send_response(200)
            self.send_header("Content-Type", "text/csv; charset=utf-8")
            self.send_header(
                "Content-Disposition",
                f'attachment; filename="netpulse_export_{start_date}_{end_date}.csv"'
            )
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        # Serve static frontend files
        if path == "/" or path == "":
            path = "/index.html"

        file_path = os.path.normpath(os.path.join(STATIC_DIR, path.lstrip("/")))
        if not file_path.startswith(STATIC_DIR) or not os.path.isfile(file_path):
            self.send_error(404, "File not found")
            return

        ext = os.path.splitext(file_path)[1].lower()
        content_types = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".svg": "image/svg+xml",
            ".png": "image/png",
            ".ico": "image/x-icon",
        }
        ctype = content_types.get(ext, "application/octet-stream")
        with open(file_path, "rb") as f:
            content = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(content)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"

        if path == "/api/settings":
            try:
                payload = json.loads(body)
                updated = db.update_settings(payload)
                collector._check_limits()
                return self._send_json({"status": "ok", "settings": updated})
            except Exception as e:
                return self._send_json({"status": "error", "message": str(e)}, status=400)

        self.send_error(404, "Endpoint not found")


def main():
    collector.start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), NetPulseHandler)
    url = f"http://127.0.0.1:{PORT}"
    print("====================================================")
    print(f" [NetPulse] Server:   {url}")
    print(f" [NetPulse] Database: {db.db_path}")
    print("====================================================", flush=True)

    if "--no-browser" not in sys.argv:
        try:
            webbrowser.open(url)
        except Exception:
            pass

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nUkončujem NetPulse macOS Monitor...")
        collector.stop()
        server.server_close()


if __name__ == "__main__":
    main()
