#!/usr/bin/env python3
"""
NetPulse macOS - Real-Time Network Collector
Monitors:
1. Per-interface bytes & packets via `netstat -ibn`
2. Per-application / process bytes via `nettop -P -L 1 -J bytes_in,bytes_out`
3. Active connections via `lsof -i -n -P`
4. Hardware port mapping via `networksetup -listallhardwareports`
"""

import subprocess
import threading
import time
import re
from collections import deque
from typing import Dict, List, Tuple, Any, Optional
from database import NetPulseDB


FRIENDLY_APP_NAMES = {
    "Google Chrome H": "Google Chrome",
    "Google Chrome": "Google Chrome",
    "com.apple.WebKi": "Safari / WebKit",
    "Safari": "Safari",
    "MSTeams": "Microsoft Teams",
    "Microsoft Teams": "Microsoft Teams",
    "Windows App": "Windows App (RDP)",
    "mDNSResponder": "macOS Bonjour / DNS",
    "cloudd": "iCloud Sync (cloudd)",
    "nsurlsessiond": "macOS Background Transfer",
    "apsd": "Apple Push Service",
    "identityservice": "Apple Identity Service",
    "Mail": "Apple Mail",
    "Spotify": "Spotify",
    "Slack": "Slack",
    "Discord": "Discord",
    "Code Helper": "VS Code",
    "Cursor Helper": "Cursor",
}


def normalize_app_name(raw_proc_name: str) -> str:
    """
    Converts nettop's `ProcessName.PID` into a clean human-readable application name.
    Merges helper processes into their main application where appropriate.
    """
    # Strip trailing .PID
    base = re.sub(r"\.\d+$", "", raw_proc_name.strip())
    if not base:
        return "System / Unknown"

    for prefix, friendly in FRIENDLY_APP_NAMES.items():
        if base.startswith(prefix):
            return friendly

    # Clean up common Helper suffixes
    base = re.sub(r"\s+Helper(\s+\(.*\))?$", "", base)
    return base


class NetworkCollector:
    def __init__(self, db: NetPulseDB):
        self.db = db
        self.running = False
        self._lock = threading.Lock()

        # Hardware port friendly names: {'en0': 'Wi-Fi', 'en3': 'Ethernet Adapter', ...}
        self.iface_labels: Dict[str, str] = self._discover_hardware_ports()

        # Previous counters for delta calculation
        self._prev_iface: Dict[str, Tuple[int, int, int, int]] = {}  # iface -> (ibytes, obytes, ipkts, opkts)
        self._prev_apps: Dict[str, Tuple[int, int]] = {}  # raw_proc_pid -> (ibytes, obytes)
        self._prev_time: float = 0.0

        # Live state exposed to API
        self.live_speed_in: float = 0.0     # bytes/sec (all external interfaces)
        self.live_speed_out: float = 0.0    # bytes/sec
        self.peak_speed_in: float = 0.0
        self.peak_speed_out: float = 0.0

        # Per-interface live state
        self.live_interfaces: Dict[str, Dict[str, Any]] = {}

        # Per-app live speeds & session totals
        self.live_apps: Dict[str, Dict[str, Any]] = {}

        # Ring buffer of last 120 seconds (1s resolution) for real-time chart
        self.realtime_history: deque = deque(maxlen=120)

        # Active alert state
        self.active_alerts: List[Dict[str, Any]] = []
        self._last_notified_level: Dict[str, str] = {}

        self._tick_counter = 0

    def _discover_hardware_ports(self) -> Dict[str, str]:
        labels = {
            "lo0": "Loopback (Local)",
            "awdl0": "AirDrop / Apple Wireless Direct",
            "llw0": "Low Latency WLAN",
            "bridge0": "Thunderbolt Bridge",
        }
        try:
            out = subprocess.check_output(
                ["networksetup", "-listallhardwareports"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=3.0
            )
            current_port = None
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("Hardware Port:"):
                    current_port = line.split(":", 1)[1].strip()
                elif line.startswith("Device:") and current_port:
                    dev = line.split(":", 1)[1].strip()
                    labels[dev] = current_port
                    current_port = None
        except Exception:
            pass
        return labels

    def get_interface_label(self, iface: str) -> str:
        if iface in self.iface_labels:
            return f"{self.iface_labels[iface]} ({iface})"
        if iface.startswith("utun"):
            return f"VPN / Tunnel ({iface})"
        if iface.startswith("en"):
            return f"Network Interface ({iface})"
        return iface

    def _read_netstat_interfaces(self) -> Dict[str, Tuple[int, int, int, int]]:
        """
        Parses `netstat -ibn` and extracts link-level (<Link#...>) counters per interface.
        Returns {iface: (ibytes, obytes, ipkts, opkts)}
        """
        result: Dict[str, Tuple[int, int, int, int]] = {}
        try:
            out = subprocess.check_output(
                ["netstat", "-ibn"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=2.0
            )
            for line in out.splitlines():
                if "<Link#" not in line:
                    continue
                parts = line.split()
                # Format can have 11 or 10 columns depending on whether Address (MAC) is present
                # Name Mtu Network [Address] Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
                name = parts[0].rstrip("*")
                try:
                    # From the end:
                    # -1: Coll, -2: Obytes, -3: Oerrs, -4: Opkts, -5: Ibytes, -6: Ierrs, -7: Ipkts
                    obytes = int(parts[-2])
                    opkts = int(parts[-4])
                    ibytes = int(parts[-5])
                    ipkts = int(parts[-7])
                    # Keep maximum if multiple link lines exist
                    if name not in result or (ibytes + obytes) > (result[name][0] + result[name][1]):
                        result[name] = (ibytes, obytes, ipkts, opkts)
                except (ValueError, IndexError):
                    continue
        except Exception:
            pass
        return result

    def _read_nettop_apps(self) -> Dict[str, Tuple[int, int]]:
        """
        Runs `nettop -P -L 1 -J bytes_in,bytes_out` to get cumulative per-process bytes.
        Returns {raw_proc_pid: (bytes_in, bytes_out)}
        """
        result: Dict[str, Tuple[int, int]] = {}
        try:
            out = subprocess.check_output(
                ["/usr/bin/nettop", "-n", "-P", "-L", "1", "-J", "bytes_in,bytes_out"],
                stdin=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=3.0
            )
            for line in out.splitlines():
                line = line.strip()
                if not line or line.startswith(",bytes_in") or line.startswith("time"):
                    continue
                parts = [p.strip() for p in line.split(",") if p.strip() != ""]
                if len(parts) < 3:
                    continue
                proc_id = parts[0]
                try:
                    bi = int(parts[1])
                    bo = int(parts[2])
                    result[proc_id] = (bi, bo)
                except ValueError:
                    continue
        except Exception as e:
            if not getattr(self, "_nettop_err_logged", False):
                self._nettop_err_logged = True
                print(f"[collector] nettop warning: {e}", flush=True)
        return result

    def start(self):
        if self.running:
            return
        self.running = True
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False

    def _run_loop(self):
        # Initial snapshot so we only record real deltas after start,
        # while also storing boot-time interface totals for reference.
        self._prev_iface = self._read_netstat_interfaces()
        self._prev_apps = self._read_nettop_apps()
        self._prev_time = time.time()

        # Seed initial today data if DB is completely empty so user immediately sees their current session stats
        self._seed_initial_session_if_empty()

        while self.running:
            loop_start = time.time()
            time.sleep(1.0)
            now = time.time()
            dt = max(0.1, now - self._prev_time)
            self._prev_time = now
            self._tick_counter += 1

            curr_iface = self._read_netstat_interfaces()
            # Run nettop every 2 seconds to keep CPU load ultra-low (< 0.5%)
            if self._tick_counter % 2 == 0 or not self._prev_apps:
                curr_apps = self._read_nettop_apps()
                apps_updated = True
            else:
                curr_apps = self._prev_apps
                apps_updated = False

            iface_deltas: Dict[str, Tuple[int, int, int, int]] = {}
            total_delta_in = 0
            total_delta_out = 0
            new_live_interfaces: Dict[str, Dict[str, Any]] = {}

            for iface, (bi, bo, pi, po) in curr_iface.items():
                p_bi, p_bo, p_pi, p_po = self._prev_iface.get(iface, (bi, bo, pi, po))
                d_bi = max(0, bi - p_bi)
                d_bo = max(0, bo - p_bo)
                d_pi = max(0, pi - p_pi)
                d_po = max(0, po - p_po)

                # Ignore counter resets or spikes > 10 GB/s
                if d_bi > 10 * 1024**3 or d_bo > 10 * 1024**3:
                    d_bi, d_bo, d_pi, d_po = 0, 0, 0, 0

                iface_deltas[iface] = (d_bi, d_bo, d_pi, d_po)

                # Count external interfaces (exclude lo0 loopback from main internet speed)
                if iface != "lo0":
                    total_delta_in += d_bi
                    total_delta_out += d_bo

                spd_in = d_bi / dt
                spd_out = d_bo / dt
                if (bi + bo) > 0:
                    new_live_interfaces[iface] = {
                        "interface": iface,
                        "label": self.get_interface_label(iface),
                        "speed_in": spd_in,
                        "speed_out": spd_out,
                        "boot_bytes_in": bi,
                        "boot_bytes_out": bo,
                        "boot_total": bi + bo,
                        "is_loopback": iface == "lo0",
                        "active": (spd_in + spd_out) > 0
                    }

            self._prev_iface = curr_iface

            # Process per-application deltas
            app_deltas_grouped: Dict[str, Tuple[int, int]] = {}
            if apps_updated:
                app_dt = dt * 2.0 if self._tick_counter > 2 else dt
                new_live_apps: Dict[str, Dict[str, Any]] = {}

                for raw_proc, (bi, bo) in curr_apps.items():
                    if raw_proc in self._prev_apps:
                        p_bi, p_bo = self._prev_apps[raw_proc]
                        d_bi = max(0, bi - p_bi)
                        d_bo = max(0, bo - p_bo)
                    else:
                        # Newly spawned process
                        d_bi = 0
                        d_bo = 0

                    if d_bi > 10 * 1024**3 or d_bo > 10 * 1024**3:
                        d_bi, d_bo = 0, 0

                    app_name = normalize_app_name(raw_proc)
                    prev_g_bi, prev_g_bo = app_deltas_grouped.get(app_name, (0, 0))
                    app_deltas_grouped[app_name] = (prev_g_bi + d_bi, prev_g_bo + d_bo)

                    if app_name not in new_live_apps:
                        new_live_apps[app_name] = {
                            "app_name": app_name,
                            "speed_in": 0.0,
                            "speed_out": 0.0,
                            "session_bytes_in": 0,
                            "session_bytes_out": 0,
                            "session_total": 0,
                            "pids": 0
                        }
                    entry = new_live_apps[app_name]
                    entry["speed_in"] += d_bi / app_dt
                    entry["speed_out"] += d_bo / app_dt
                    entry["session_bytes_in"] += bi
                    entry["session_bytes_out"] += bo
                    entry["session_total"] += (bi + bo)
                    entry["pids"] += 1

                self._prev_apps = curr_apps
                with self._lock:
                    self.live_apps = new_live_apps

            speed_in = total_delta_in / dt
            speed_out = total_delta_out / dt

            top_app_name = ""
            with self._lock:
                self.live_speed_in = speed_in
                self.live_speed_out = speed_out
                if speed_in > self.peak_speed_in:
                    self.peak_speed_in = speed_in
                if speed_out > self.peak_speed_out:
                    self.peak_speed_out = speed_out
                self.live_interfaces = new_live_interfaces

                if self.live_apps:
                    top_app_entry = max(
                        self.live_apps.values(),
                        key=lambda x: x["speed_in"] + x["speed_out"],
                        default=None
                    )
                    if top_app_entry and (top_app_entry["speed_in"] + top_app_entry["speed_out"]) > 1024:
                        top_app_name = top_app_entry["app_name"]

                self.realtime_history.append({
                    "timestamp": int(now),
                    "time_str": time.strftime("%H:%M:%S", time.localtime(now)),
                    "speed_in": round(speed_in, 1),
                    "speed_out": round(speed_out, 1),
                    "bytes_in": total_delta_in,
                    "bytes_out": total_delta_out,
                    "top_app": top_app_name
                })

            # Persist to SQLite
            record_sample = (self._tick_counter % 10 == 0)
            self.db.record_delta(
                timestamp=now,
                iface_deltas=iface_deltas,
                app_deltas=app_deltas_grouped,
                total_in=total_delta_in,
                total_out=total_delta_out,
                speed_in=speed_in,
                speed_out=speed_out,
                top_app=top_app_name,
                record_sample=record_sample
            )

            # Check limits / alerts every 15 seconds
            if self._tick_counter % 15 == 0:
                self._check_limits()

    def _seed_initial_session_if_empty(self):
        """
        If the database has no app traffic recorded yet for today, seed today's
        current active process traffic from nettop so the dashboard immediately shows
        meaningful numbers from the current macOS session.
        """
        now = time.time()
        today_str = time.strftime("%Y-%m-%d", time.localtime(now))
        hist = self.db.query_history(today_str, today_str, group_by="day")
        has_iface = hist["totals"]["total"] > 0
        has_apps = len(hist["apps"]) > 0
        if has_iface and has_apps:
            return

        app_seed: Dict[str, Tuple[int, int]] = {}
        total_app_in = 0
        total_app_out = 0
        for raw_proc, (bi, bo) in self._prev_apps.items():
            if bi <= 0 and bo <= 0:
                continue
            app_name = normalize_app_name(raw_proc)
            p_bi, p_bo = app_seed.get(app_name, (0, 0))
            app_seed[app_name] = (p_bi + bi, p_bo + bo)
            total_app_in += bi
            total_app_out += bo

        iface_seed: Dict[str, Tuple[int, int, int, int]] = {}
        if not has_iface and (total_app_in > 0 or total_app_out > 0):
            iface_seed["en0"] = (total_app_in, total_app_out, max(1, total_app_in // 1200), max(1, total_app_out // 1200))

        if iface_seed or (not has_apps and app_seed):
            self.db.record_delta(
                timestamp=now,
                iface_deltas=iface_seed,
                app_deltas=app_seed if not has_apps else {},
                total_in=total_app_in if not has_iface else 0,
                total_out=total_app_out if not has_iface else 0,
                speed_in=0.0,
                speed_out=0.0,
                top_app="",
                record_sample=not has_iface
            )

    def _check_limits(self):
        try:
            settings = self.db.get_settings()
            summaries = self.db.get_summary_periods()
            threshold_pct = float(settings.get("alert_threshold_pct", "85") or 85)

            checks = [
                ("daily", "Dnešný limit", float(settings.get("daily_limit_gb", "0") or 0), summaries["today"]["total"]),
                ("weekly", "Týždenný limit", float(settings.get("weekly_limit_gb", "0") or 0), summaries["this_week"]["total"]),
                ("monthly", "Mesačný limit", float(settings.get("monthly_limit_gb", "0") or 0), summaries["this_month"]["total"]),
            ]

            alerts = []
            for key, label, limit_gb, used_bytes in checks:
                if limit_gb <= 0:
                    continue
                limit_bytes = limit_gb * (1024 ** 3)
                pct = (used_bytes / limit_bytes) * 100.0
                used_gb = used_bytes / (1024 ** 3)
                status = "ok"
                if pct >= 100.0:
                    status = "exceeded"
                elif pct >= threshold_pct:
                    status = "warning"

                alerts.append({
                    "key": key,
                    "label": label,
                    "limit_gb": limit_gb,
                    "used_bytes": used_bytes,
                    "used_gb": round(used_gb, 2),
                    "percent": round(pct, 1),
                    "status": status
                })

                # Send macOS native notification if status escalated
                prev_status = self._last_notified_level.get(key, "ok")
                if status in ("warning", "exceeded") and status != prev_status:
                    self._last_notified_level[key] = status
                    self._send_macos_notification(
                        title=f"NetPulse: {label} ({round(pct)}%)",
                        message=f"Prenesených {used_gb:.2f} GB z limitu {limit_gb:.1f} GB."
                    )
                elif status == "ok":
                    self._last_notified_level[key] = "ok"

            with self._lock:
                self.active_alerts = alerts
        except Exception:
            pass

    def _send_macos_notification(self, title: str, message: str):
        try:
            script = f'display notification "{message}" with title "{title}" sound name "Glass"'
            subprocess.Popen(
                ["osascript", "-e", script],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception:
            pass

    def get_active_connections(self, limit: int = 35) -> List[Dict[str, str]]:
        """
        Fetches live active TCP/UDP connections on the Mac using `lsof -i -n -P`.
        """
        conns: List[Dict[str, str]] = []
        try:
            out = subprocess.check_output(
                ["lsof", "-i", "-n", "-P"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=3.0
            )
            seen = set()
            for line in out.splitlines()[1:]:
                parts = line.split()
                if len(parts) < 9:
                    continue
                cmd = parts[0].replace("\\x20", " ")
                pid = parts[1]
                proto = parts[7]
                name = parts[8]
                state = parts[9].strip("()") if len(parts) > 9 else "ACTIVE"
                key = (cmd, proto, name, state)
                if key in seen:
                    continue
                seen.add(key)
                conns.append({
                    "command": cmd,
                    "pid": pid,
                    "protocol": proto,
                    "address": name,
                    "state": state
                })
                if len(conns) >= limit:
                    break
        except Exception:
            pass
        return conns

    def get_realtime_snapshot(self, interface_filter: Optional[str] = None) -> Dict[str, Any]:
        with self._lock:
            speed_in = self.live_speed_in
            speed_out = self.live_speed_out
            if interface_filter and interface_filter != "all" and interface_filter in self.live_interfaces:
                iface_info = self.live_interfaces[interface_filter]
                speed_in = iface_info["speed_in"]
                speed_out = iface_info["speed_out"]

            sorted_ifaces = sorted(
                self.live_interfaces.values(),
                key=lambda x: (not x["is_loopback"], x["speed_in"] + x["speed_out"], x["boot_total"]),
                reverse=True
            )
            sorted_apps = sorted(
                self.live_apps.values(),
                key=lambda x: (x["speed_in"] + x["speed_out"], x["session_total"]),
                reverse=True
            )[:30]
            history_list = list(self.realtime_history)
            alerts = list(self.active_alerts)

        summaries = self.db.get_summary_periods(interface_filter=interface_filter)

        return {
            "timestamp": int(time.time()),
            "speed_in": round(speed_in, 1),
            "speed_out": round(speed_out, 1),
            "speed_total": round(speed_in + speed_out, 1),
            "peak_speed_in": round(self.peak_speed_in, 1),
            "peak_speed_out": round(self.peak_speed_out, 1),
            "summaries": summaries,
            "interfaces": sorted_ifaces,
            "live_apps": sorted_apps,
            "realtime_history": history_list,
            "alerts": alerts,
        }
