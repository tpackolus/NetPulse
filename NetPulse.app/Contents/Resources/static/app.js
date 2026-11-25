/**
 * NetPulse macOS v2.4.0 — Native Telemetry Studio Frontend Controller
 */

const VIEW_META = {
    overview: {
        title: 'Live Telemetry Overview',
        subtitle: 'Real-time throughput, active Wi-Fi & top processes'
    },
    wifi: {
        title: 'Wi-Fi Networks',
        subtitle: 'Data consumption tracked automatically per Wi-Fi SSID'
    },
    history: {
        title: 'History & Analytics',
        subtitle: 'Hourly, daily & monthly transfer logs with CSV/JSON export'
    },
    apps: {
        title: 'Applications & Processes',
        subtitle: 'Per-process bandwidth matrix, open sockets & 24h profiles'
    },
    network: {
        title: 'Sockets, GeoIP & LAN Scanner',
        subtitle: 'Live endpoint security audit, subnet device discovery & hardware adapters'
    },
    speedtest: {
        title: 'Speedtest & Connection Outages',
        subtitle: 'Bidirectional multi-CDN benchmark, per-Wi-Fi speed history & outage log'
    },
    tools: {
        title: 'DNS Benchmark & Visual Traceroute',
        subtitle: 'Compare DNS resolver speed on your Wi-Fi & inspect packet hop path'
    }
};

const state = {
    activeView: 'overview',
    selectedInterface: 'all',
    currentPreset: 'today',
    realtimePaused: false,
    appViewMode: 'live',
    wifiViewMode: 'used',
    socketFilter: 'all',
    wifiSortCol: 'all_total',
    wifiSortDir: 'desc',
    appSortCol: 'metric',
    appSortDir: 'desc',
    theme: 'dark',
    isPointerDown: false,
    realtimeData: null,
    historyData: null,
    connectionsData: [],
    latestDiagnostics: null,
    hoverRealtimeIdx: -1,
    hoverBarCanvas: null,
    hoverBarIdx: -1,
    barChartCache: {},
    settings: {
        daily_limit_gb: '0',
        weekly_limit_gb: '0',
        monthly_limit_gb: '500',
        alert_threshold_pct: '85',
        launch_at_login: '0',
        theme: 'dark'
    },
    knownInterfaces: new Set(['all'])
};

let toastTimer = null;
let inspectorRefreshTimer = null;
let currentInspectedApp = null;
let currentInspectedWifi = null;
let wasSpeedtestRunning = false;
let lanPollTimer = null;
let dnsPollTimer = null;
let tracePollTimer = null;

function formatBytes(bytes, decimals = 2) {
    if (!bytes || bytes <= 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.min(sizes.length - 1, Math.floor(Math.log(bytes) / Math.log(k)));
    const val = bytes / Math.pow(k, i);
    const dec = i >= 3 ? decimals : (i === 2 ? 1 : 0);
    return `${val.toFixed(dec)} ${sizes[i]}`;
}

function formatBytesOrDash(bytes) {
    if (!bytes || bytes <= 0) return '<span class="muted-dash">—</span>';
    return formatBytes(bytes);
}

function formatSpeed(bytesPerSec) {
    if (!bytesPerSec || bytesPerSec < 1) return '0 B/s';
    return `${formatBytes(bytesPerSec, 2)}/s`;
}

function formatSpeedFixed(bytesPerSec) {
    if (!bytesPerSec || bytesPerSec < 102.4) return '0.0 KB/s';
    if (bytesPerSec >= 1024 * 1024 * 1024) {
        return `${(bytesPerSec / (1024 * 1024 * 1024)).toFixed(2)} GB/s`;
    }
    if (bytesPerSec >= 1024 * 1024) {
        return `${(bytesPerSec / (1024 * 1024)).toFixed(2)} MB/s`;
    }
    const kb = bytesPerSec / 1024;
    return kb >= 100 ? `${kb.toFixed(0)} KB/s` : `${kb.toFixed(1)} KB/s`;
}

function toISODate(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

function escapeHtml(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function postNativeAction(payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.netpulseNative) {
        window.webkit.messageHandlers.netpulseNative.postMessage(payload);
    }
}

function showToast(msg) {
    const el = document.getElementById('toastBanner');
    if (!el) return;
    el.textContent = msg;
    el.classList.remove('hidden');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
        el.classList.add('hidden');
    }, 2400);
}

document.addEventListener('DOMContentLoaded', () => {
    const now = new Date();
    const todayStr = toISODate(now);
    document.getElementById('filterStartDate').value = todayStr;
    document.getElementById('filterEndDate').value = todayStr;
    document.getElementById('todayDateLabel').textContent = now.toLocaleDateString('en-US', {
        month: 'short', day: '2-digit'
    });

    // Prevent DOM re-render from swallowing clicks during 1s polling
    document.addEventListener('pointerdown', () => { state.isPointerDown = true; });
    document.addEventListener('pointerup', () => { state.isPointerDown = false; });
    document.addEventListener('pointercancel', () => { state.isPointerDown = false; });

    // Delegated click handlers on dynamic tables so clicks always fire cleanly
    bindTableDelegation('overviewAppsBody', 'data-app', openAppInspector);
    bindTableDelegation('appTableBody', 'data-app', openAppInspector);
    bindTableDelegation('historyTopAppsBody', 'data-app', openAppInspector);
    bindTableDelegation('overviewWifiBody', 'data-ssid', openWifiInspector);
    bindTableDelegation('wifiUsageTableBody', 'data-ssid', openWifiInspector);

    // Keyboard shortcuts: 1-5 to switch views, Escape to close modals
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            closeAppInspector();
            closeWifiInspector();
            closeLimitsModal();
            return;
        }
        const tag = (e.target && e.target.tagName) ? e.target.tagName.toLowerCase() : '';
        if (tag === 'input' || tag === 'select' || tag === 'textarea' || e.metaKey || e.ctrlKey || e.altKey) return;
        const viewMap = { '1': 'overview', '2': 'wifi', '3': 'history', '4': 'apps', '5': 'network', '6': 'speedtest', '7': 'tools' };
        if (viewMap[e.key]) {
            switchView(viewMap[e.key]);
        }
    });

    document.getElementById('globalInterfaceSelect').addEventListener('change', (e) => {
        state.selectedInterface = e.target.value;
        fetchRealtime();
        fetchHistory();
    });

    document.getElementById('openLimitsModalBtn').addEventListener('click', openLimitsModal);

    setupChartHover('realtimeCanvas', 'realtime');
    setupChartHover('historyCanvas', 'bar');
    setupChartHover('appDetailCanvas', 'bar');
    setupChartHover('wifiDetailCanvas', 'bar');

    loadSettings();
    fetchRealtime();
    fetchHistory();
    fetchConnections();
    fetchSpeedtestAndOutages();
    fetchLanDevices(false);
    setTimeout(fetchConnections, 1500);
    setTimeout(fetchConnections, 3200);

    setInterval(fetchRealtime, 1000);
    setInterval(fetchHistory, 10000);
    setInterval(fetchConnections, 4500);
    setInterval(fetchSpeedtestAndOutages, 8000);

    window.addEventListener('resize', redrawVisibleCharts);
    if (window.ResizeObserver) {
        const ro = new ResizeObserver(() => requestAnimationFrame(redrawVisibleCharts));
        document.querySelectorAll('.chart-frame').forEach(frame => ro.observe(frame));
    }
});

function bindTableDelegation(tbodyId, attrName, callback) {
    const tbody = document.getElementById(tbodyId);
    if (!tbody) return;
    tbody.addEventListener('click', (e) => {
        const row = e.target.closest(`tr[${attrName}]`);
        if (row) {
            const val = row.getAttribute(attrName);
            if (val) callback(val);
        }
    });
}

function switchView(viewName) {
    if (!VIEW_META[viewName]) return;
    state.activeView = viewName;
    hideChartTooltip();

    document.querySelectorAll('#mainSidebarNav .nav-item').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.view === viewName);
    });
    document.querySelectorAll('.view-pane').forEach(pane => {
        pane.classList.toggle('active', pane.id === `view-${viewName}`);
    });

    document.getElementById('currentViewTitle').textContent = VIEW_META[viewName].title;
    document.getElementById('currentViewSubtitle').textContent = VIEW_META[viewName].subtitle;

    if (viewName === 'network') {
        fetchConnections();
        fetchLanDevices(false);
    } else if (viewName === 'speedtest') {
        fetchSpeedtestAndOutages();
    } else if (viewName === 'tools') {
        fetchDnsBenchmark(false);
        fetchTraceroute(false, '');
    }
    requestAnimationFrame(redrawVisibleCharts);
}

function jumpToPeriod(preset) {
    selectPreset(preset);
    switchView('history');
}

function redrawVisibleCharts() {
    if (state.activeView === 'overview' && state.realtimeData && !state.realtimePaused) {
        drawRealtimeChart(state.realtimeData.realtime_history || []);
    }
    if (state.activeView === 'history' && state.historyData) {
        drawHistoryChart('historyCanvas', state.historyData.timeline || []);
    }
    if (!document.getElementById('appDetailModal').classList.contains('hidden') && state.barChartCache['appDetailCanvas']) {
        drawHistoryChart('appDetailCanvas', state.barChartCache['appDetailCanvas']);
    }
    if (!document.getElementById('wifiDetailModal').classList.contains('hidden') && state.barChartCache['wifiDetailCanvas']) {
        drawHistoryChart('wifiDetailCanvas', state.barChartCache['wifiDetailCanvas']);
    }
}

async function fetchRealtime() {
    try {
        const res = await fetch(`netpulse://app/api/realtime?interface=${encodeURIComponent(state.selectedInterface)}`);
        if (!res.ok) return;
        const data = await res.json();
        state.realtimeData = data;
        updateRealtimeUI(data);
    } catch (err) {
        console.error('Realtime error:', err);
    }
}

async function fetchHistory() {
    try {
        const groupBy = document.getElementById('filterGroupBy').value;
        let url = `netpulse://app/api/history?interface=${encodeURIComponent(state.selectedInterface)}&group_by=${encodeURIComponent(groupBy)}`;
        if (state.currentPreset === 'custom') {
            const s = document.getElementById('filterStartDate').value;
            const e = document.getElementById('filterEndDate').value;
            url += `&preset=custom&start=${encodeURIComponent(s)}&end=${encodeURIComponent(e)}`;
        } else {
            url += `&preset=${encodeURIComponent(state.currentPreset)}`;
        }
        const res = await fetch(url);
        if (!res.ok) return;
        const data = await res.json();
        state.historyData = data;
        updateHistoryUI(data);
    } catch (err) {
        console.error('History error:', err);
    }
}

async function fetchConnections() {
    try {
        const res = await fetch('netpulse://app/api/connections');
        if (!res.ok) return;
        const data = await res.json();
        state.connectionsData = data.connections || [];
        const badge = document.getElementById('navConnBadge');
        if (badge) badge.textContent = state.connectionsData.length;
        if (!state.isPointerDown) {
            renderConnectionsTable(state.connectionsData);
        }
    } catch (err) {
        console.error('Connections error:', err);
    }
}

async function loadSettings() {
    try {
        const res = await fetch('netpulse://app/api/settings');
        if (!res.ok) return;
        const data = await res.json();
        if (data.settings) {
            state.settings = data.settings;
            applyTheme(state.settings.theme || 'dark');
        }
    } catch (err) {
        console.error('Settings error:', err);
    }
}

function applyTheme(theme) {
    state.theme = theme === 'light' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', state.theme);
    const lbl = document.getElementById('themeToggleLabel');
    if (lbl) {
        lbl.textContent = state.theme === 'light' ? 'Dark' : 'Light';
    }
    redrawVisibleCharts();
}

function toggleTheme() {
    const next = state.theme === 'light' ? 'dark' : 'light';
    applyTheme(next);
    state.settings.theme = next;
    postNativeAction({ action: 'set_theme', theme: next });
}

function copyPublicIP() {
    const ip = state.latestDiagnostics && state.latestDiagnostics.public_ip;
    if (!ip || ip === '—' || ip === 'Resolving...') return;
    postNativeAction({ action: 'copy_text', text: ip });
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(ip).catch(() => {});
    }
    showToast(`Copied Public IP: ${ip}`);
}

function updateRealtimeUI(data) {
    document.getElementById('headerSpeedIn').textContent = formatSpeedFixed(data.speed_in);
    document.getElementById('headerSpeedOut').textContent = formatSpeedFixed(data.speed_out);
    document.getElementById('peakSpeedIn').textContent = formatSpeedFixed(data.peak_speed_in);
    document.getElementById('peakSpeedOut').textContent = formatSpeedFixed(data.peak_speed_out);

    const wifiList = Array.isArray(data.wifi_usage) ? data.wifi_usage : [];
    const activeWifi = wifiList.find(w => w.is_active);
    const usedWifiCount = wifiList.filter(w => w.all_total > 0 || w.is_active).length;

    const navWifiBadge = document.getElementById('navWifiBadge');
    if (navWifiBadge) navWifiBadge.textContent = usedWifiCount;

    const navAppsBadge = document.getElementById('navAppsBadge');
    if (navAppsBadge) navAppsBadge.textContent = (data.live_apps || []).length;

    if (data.diagnostics) {
        const d = data.diagnostics;
        const profText = d.network_profile + (d.vpn_active ? ' [VPN]' : '');
        document.getElementById('diagProfile').textContent = profText;
        document.getElementById('sidebarActiveSSID').textContent = profText;
        document.getElementById('diagLocalIP').textContent = `IP: ${d.local_ip} · GW: ${d.router_ip}`;
        document.getElementById('sidebarActiveIP').textContent = `Local IP: ${d.local_ip}`;

        const usageStr = activeWifi
            ? `Today: ${formatBytes(activeWifi.today_total)} · Total: ${formatBytes(activeWifi.all_total)}`
            : 'Today: 0 B · Total: 0 B';
        document.getElementById('diagWiFiUsage').textContent = usageStr;
        document.getElementById('sidebarActiveUsage').textContent = usageStr;

        const netOnline = d.network_profile !== 'Disconnected';
        document.getElementById('sidebarNetDot').className = `status-dot ${netOnline ? 'online' : ''}`;

        // Live CoreWLAN Wi-Fi Radio Quality
        const radioChip = document.getElementById('diagRadioChip');
        if (d.wifi_rssi && d.wifi_rssi < 0) {
            if (radioChip) {
                radioChip.textContent = `${d.wifi_band} · ${d.wifi_rssi} dBm (${d.wifi_quality_pct}%)`;
                radioChip.style.opacity = '1';
            }
            document.getElementById('wifiRadioRssi').textContent = `${d.wifi_rssi} dBm`;
            const qualLabel = d.wifi_rssi >= -60 ? 'Excellent' : (d.wifi_rssi >= -70 ? 'Good' : (d.wifi_rssi >= -80 ? 'Fair' : 'Weak'));
            document.getElementById('wifiRadioQuality').textContent = `Signal quality: ${d.wifi_quality_pct}% (${qualLabel})`;
            document.getElementById('wifiRadioSnr').textContent = `${d.wifi_snr} dB SNR`;
            document.getElementById('wifiRadioNoise').textContent = `Noise floor: ${d.wifi_noise} dBm`;
            document.getElementById('wifiRadioBand').textContent = d.wifi_band;
            document.getElementById('wifiRadioChannel').textContent = `Channel ${d.wifi_channel} (${d.wifi_width})`;
            document.getElementById('wifiRadioTx').textContent = `${Math.round(d.wifi_tx_rate)} Mbps`;
            document.getElementById('wifiRadioStd').textContent = d.wifi_standard;
        } else {
            if (radioChip) radioChip.textContent = '';
            document.getElementById('wifiRadioRssi').textContent = '— dBm';
            document.getElementById('wifiRadioQuality').textContent = 'Wi-Fi radio inactive';
            document.getElementById('wifiRadioSnr').textContent = '—';
            document.getElementById('wifiRadioNoise').textContent = 'Noise floor: —';
            document.getElementById('wifiRadioBand').textContent = '—';
            document.getElementById('wifiRadioChannel').textContent = 'Channel: —';
            document.getElementById('wifiRadioTx').textContent = '— Mbps';
            document.getElementById('wifiRadioStd').textContent = '—';
        }

        document.getElementById('diagPublicIP').textContent = d.public_ip || '—';
        document.getElementById('diagISP').textContent = d.isp_org || '—';
        document.getElementById('diagLocation').textContent = `Location: ${d.country_city || '—'}`;

        const rMs = d.ping_router_ms >= 0 ? `${d.ping_router_ms.toFixed(1)} ms` : '—';
        const iMs = d.ping_internet_ms >= 0 ? `${d.ping_internet_ms.toFixed(1)} ms` : '—';
        document.getElementById('diagPingRouter').textContent = rMs;
        document.getElementById('diagPingInternet').textContent = iMs;
        document.getElementById('headerPingVal').textContent = iMs;

        const pingDot = document.getElementById('headerPingDot');
        const healthLbl = document.getElementById('diagHealthLabel');
        if (d.ping_internet_ms < 0) {
            pingDot.className = 'status-dot';
            healthLbl.textContent = 'Connection quality: Measuring...';
        } else if (d.ping_internet_ms < 35) {
            pingDot.className = 'status-dot online';
            healthLbl.textContent = 'Connection quality: Excellent (Low Latency)';
        } else if (d.ping_internet_ms < 85) {
            pingDot.className = 'status-dot online';
            healthLbl.textContent = 'Connection quality: Good';
        } else {
            pingDot.className = 'status-dot warn';
            healthLbl.textContent = 'Connection quality: Elevated Latency';
        }

        document.getElementById('diagDbSize').textContent = `SQLite DB: ${d.db_size_kb} KB`;
        if (d.db_path) {
            document.getElementById('modalDbPath').textContent = d.db_path;
        }

        const stBtn = document.getElementById('runSpeedtestBtn');
        const fullStBtn = document.getElementById('fullSpeedtestBtn');
        const stVal = document.getElementById('diagSpeedtestVal');
        const stPhase = document.getElementById('speedtestPhaseLabel');

        if (d.speedtest_down_mbps > 0) {
            document.getElementById('stCardDown').textContent = `${d.speedtest_down_mbps.toFixed(1)} Mbps`;
        }
        if (d.speedtest_up_mbps > 0) {
            document.getElementById('stCardUp').textContent = `${d.speedtest_up_mbps.toFixed(1)} Mbps`;
        }
        if (d.speedtest_ping_ms > 0) {
            document.getElementById('stCardPing').textContent = `${d.speedtest_ping_ms.toFixed(1)} ms`;
            document.getElementById('stCardJitter').textContent = `${d.speedtest_jitter_ms.toFixed(1)} ms`;
        }

        if (d.speedtest_running) {
            wasSpeedtestRunning = true;
            const liveTxt = d.speedtest_up_mbps > 0
                ? `↓ ${d.speedtest_down_mbps.toFixed(1)} · ↑ ${d.speedtest_up_mbps.toFixed(1)} Mbps`
                : (d.speedtest_down_mbps > 0 ? `↓ ${d.speedtest_down_mbps.toFixed(1)} Mbps...` : (d.speedtest_phase || 'Benchmarking...'));
            stVal.textContent = liveTxt;
            stBtn.textContent = 'Testing...';
            stBtn.disabled = true;
            if (fullStBtn) { fullStBtn.textContent = d.speedtest_phase || 'Testing...'; fullStBtn.disabled = true; }
            if (stPhase && d.speedtest_phase) stPhase.textContent = d.speedtest_phase;
        } else {
            if (wasSpeedtestRunning) {
                wasSpeedtestRunning = false;
                fetchSpeedtestAndOutages();
            }
            stBtn.textContent = 'Run Test';
            stBtn.disabled = false;
            if (fullStBtn) { fullStBtn.textContent = 'Start Full Speedtest'; fullStBtn.disabled = false; }
            if (stPhase) stPhase.textContent = 'Measures ICMP latency, jitter, multi-stream CDN download & upload throughput';
            if (d.speedtest_down_mbps > 0) {
                stVal.textContent = d.speedtest_up_mbps > 0
                    ? `↓ ${d.speedtest_down_mbps.toFixed(1)} / ↑ ${d.speedtest_up_mbps.toFixed(1)} Mbps`
                    : `${d.speedtest_down_mbps.toFixed(1)} Mbps`;
            }
        }

        // Version & Update UI sync
        const verStr = `v${d.app_version || '2.5.0'}`;
        document.getElementById('sidebarVersionLabel').textContent = `macOS Engine ${verStr}`;
        const topUpdateLabel = document.getElementById('topUpdateLabel');
        const topUpdateBtn = document.getElementById('topUpdateBtn');
        const sidebarDot = document.getElementById('sidebarUpdateDot');
        const modalUpdateStatus = document.getElementById('modalUpdateStatus');
        const banner = document.getElementById('updateNotificationBanner');

        if (modalUpdateStatus && d.update_status) {
            modalUpdateStatus.textContent = d.update_status + (d.update_notes ? ` — ${d.update_notes}` : '');
        }
        if (d.update_installing) {
            topUpdateLabel.textContent = 'Updating...';
        } else if (d.update_available) {
            topUpdateLabel.textContent = `Update v${d.latest_version}`;
            topUpdateBtn.style.borderColor = '#10b981';
            sidebarDot.classList.remove('hidden');
            banner.classList.remove('hidden');
            document.getElementById('updateBannerTitle').textContent = `New NetPulse v${d.latest_version} is available on GitHub`;
            document.getElementById('updateBannerNotes').textContent = d.update_notes || '';
        } else if (d.update_checking) {
            topUpdateLabel.textContent = 'Checking...';
        } else {
            topUpdateLabel.textContent = verStr;
            topUpdateBtn.style.borderColor = '';
            sidebarDot.classList.add('hidden');
            banner.classList.add('hidden');
        }
        state.latestDiagnostics = d;
    }

    const s = data.summaries;
    if (s) {
        document.getElementById('sumTodayTotal').textContent = formatBytes(s.today.total);
        document.getElementById('sumTodayIn').textContent = formatBytes(s.today.bytes_in);
        document.getElementById('sumTodayOut').textContent = formatBytes(s.today.bytes_out);

        document.getElementById('sumWeekTotal').textContent = formatBytes(s.this_week.total);
        document.getElementById('sumWeekIn').textContent = formatBytes(s.this_week.bytes_in);
        document.getElementById('sumWeekOut').textContent = formatBytes(s.this_week.bytes_out);
        document.getElementById('sum7dTotal').textContent = formatBytes(s.last_7_days.total);

        document.getElementById('sumMonthTotal').textContent = formatBytes(s.this_month.total);
        document.getElementById('sumMonthIn').textContent = formatBytes(s.this_month.bytes_in);
        document.getElementById('sumMonthOut').textContent = formatBytes(s.this_month.bytes_out);
        document.getElementById('sum30dTotal').textContent = formatBytes(s.last_30_days.total);

        document.getElementById('sumYearTotal').textContent = formatBytes(s.this_year.total);
        document.getElementById('sumYearIn').textContent = formatBytes(s.this_year.bytes_in);
        document.getElementById('sumYearOut').textContent = formatBytes(s.this_year.bytes_out);
        document.getElementById('sumYesterdayTotal').textContent = formatBytes(s.yesterday.total);

        updateLimitBars(s);
    }

    const ifaceSelect = document.getElementById('globalInterfaceSelect');
    (data.interfaces || []).forEach(item => {
        if (!state.knownInterfaces.has(item.interface)) {
            state.knownInterfaces.add(item.interface);
            const opt = document.createElement('option');
            opt.value = item.interface;
            opt.textContent = item.label;
            ifaceSelect.appendChild(opt);
        }
    });

    if (!state.isPointerDown) {
        renderOverviewGlance(data);
        renderWiFiSummaryAndTable(wifiList);
        renderInterfacesList(data.interfaces || []);
        if (state.appViewMode === 'live') {
            renderAppTable();
        }
    }

    if (state.activeView === 'overview' && !state.realtimePaused) {
        drawRealtimeChart(data.realtime_history || []);
    }
}

function renderOverviewGlance(data) {
    // Top 8 Active Processes
    const appsBody = document.getElementById('overviewAppsBody');
    const apps = (data.live_apps || []).slice(0, 8);
    if (!apps.length) {
        appsBody.innerHTML = `<tr><td colspan="3" style="text-align:center;color:var(--text-muted);">Collecting active processes...</td></tr>`;
    } else {
        appsBody.innerHTML = apps.map(a => {
            const spd = a.speed_in + a.speed_out;
            const rateHtml = spd > 50
                ? `<strong style="color:var(--down-color);">${formatSpeed(spd)}</strong>`
                : `<span class="muted-dash">Idle</span>`;
            return `
                <tr class="clickable-row" data-app="${escapeHtml(a.app_name)}">
                    <td><strong>${escapeHtml(a.app_name)}</strong></td>
                    <td class="num-col">${rateHtml}</td>
                    <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(a.total)}</strong></td>
                </tr>
            `;
        }).join('');
    }

    // Top 6 Wi-Fi Networks with recorded data
    const wifiBody = document.getElementById('overviewWifiBody');
    const wifiAll = (data.wifi_usage || []).filter(w => w.all_total > 0 || w.is_active);
    const grandTotal = wifiAll.reduce((acc, w) => acc + (w.all_total || 0), 0);
    const topWifi = [...wifiAll].sort((a, b) => {
        if (a.is_active !== b.is_active) return a.is_active ? -1 : 1;
        return b.all_total - a.all_total;
    }).slice(0, 6);

    if (!topWifi.length) {
        wifiBody.innerHTML = `<tr><td colspan="4" style="text-align:center;color:var(--text-muted);">No Wi-Fi usage recorded yet</td></tr>`;
    } else {
        wifiBody.innerHTML = topWifi.map(w => {
            const pct = grandTotal > 0 ? ((w.all_total / grandTotal) * 100).toFixed(1) : '0.0';
            const activeDot = w.is_active ? `<span class="status-dot online" title="Connected"></span>` : '';
            return `
                <tr class="clickable-row ${w.is_active ? 'wifi-active-row' : ''}" data-ssid="${escapeHtml(w.ssid)}">
                    <td><div class="wifi-ssid-cell">${activeDot}<strong>${escapeHtml(w.ssid)}</strong></div></td>
                    <td class="num-col">${formatBytesOrDash(w.today_total)}</td>
                    <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(w.all_total)}</strong></td>
                    <td>
                        <div class="share-bar-cell">
                            <div class="mini-bar"><div class="mini-bar-fill" style="width:${Math.min(100, pct)}%"></div></div>
                            <span>${pct}%</span>
                        </div>
                    </td>
                </tr>
            `;
        }).join('');
    }
}

function updateLimitBars(summaries) {
    const dailyGb = parseFloat(state.settings.daily_limit_gb || '0');
    const weeklyGb = parseFloat(state.settings.weekly_limit_gb || '0');
    const monthlyGb = parseFloat(state.settings.monthly_limit_gb || '0');
    const warnPct = parseFloat(state.settings.alert_threshold_pct || '85');

    const applyBar = (wrapId, fillId, textId, usedBytes, limitGb) => {
        const wrap = document.getElementById(wrapId);
        if (!limitGb || limitGb <= 0) {
            wrap.classList.add('hidden');
            return;
        }
        wrap.classList.remove('hidden');
        const limitBytes = limitGb * Math.pow(1024, 3);
        const pct = Math.min(100, (usedBytes / limitBytes) * 100);
        const fill = document.getElementById(fillId);
        fill.style.width = `${pct.toFixed(1)}%`;
        fill.className = 'quota-fill';
        if (pct >= 100) fill.classList.add('danger');
        else if (pct >= warnPct) fill.classList.add('warn');

        document.getElementById(textId).textContent = `${((usedBytes / limitBytes) * 100).toFixed(1)}% of ${limitGb} GB quota`;
    };

    applyBar('limitWrapDaily', 'limitFillDaily', 'limitTextDaily', summaries.today.total, dailyGb);
    applyBar('limitWrapWeekly', 'limitFillWeekly', 'limitTextWeekly', summaries.this_week.total, weeklyGb);
    applyBar('limitWrapMonthly', 'limitFillMonthly', 'limitTextMonthly', summaries.this_month.total, monthlyGb);
}

// --- Wi-Fi Networks View, Sorting & 30-Day Inspector ---
function setWiFiViewMode(mode) {
    state.wifiViewMode = mode;
    document.getElementById('wifiModeUsedBtn').classList.toggle('active', mode === 'used');
    document.getElementById('wifiModeAllBtn').classList.toggle('active', mode === 'all');
    if (state.realtimeData) {
        renderWiFiSummaryAndTable(state.realtimeData.wifi_usage || []);
    }
}

function onWifiSearchInput() {
    const val = document.getElementById('wifiSearchInput').value;
    document.getElementById('wifiSearchClear').classList.toggle('hidden', !val);
    if (val && state.wifiViewMode === 'used') {
        // Automatically search across all saved networks when typing a query
        setWiFiViewMode('all');
        return;
    }
    if (state.realtimeData) {
        renderWiFiSummaryAndTable(state.realtimeData.wifi_usage || []);
    }
}

function clearWifiSearch() {
    document.getElementById('wifiSearchInput').value = '';
    document.getElementById('wifiSearchClear').classList.add('hidden');
    if (state.realtimeData) {
        renderWiFiSummaryAndTable(state.realtimeData.wifi_usage || []);
    }
}

function setWifiSort(col) {
    if (state.wifiSortCol === col) {
        state.wifiSortDir = state.wifiSortDir === 'desc' ? 'asc' : 'desc';
    } else {
        state.wifiSortCol = col;
        state.wifiSortDir = col === 'ssid' ? 'asc' : 'desc';
    }
    ['ssid', 'today_total', 'week_total', 'month_total', 'all_in', 'all_out', 'all_total'].forEach(c => {
        const el = document.getElementById(`wifiSort_${c}`);
        if (el) el.textContent = c === state.wifiSortCol ? (state.wifiSortDir === 'desc' ? '▼' : '▲') : '';
    });
    if (state.realtimeData) {
        renderWiFiSummaryAndTable(state.realtimeData.wifi_usage || []);
    }
}

function renderWiFiSummaryAndTable(wifiRows) {
    const allRows = Array.isArray(wifiRows) ? [...wifiRows] : [];
    const activeRow = allRows.find(r => r.is_active);
    const withTraffic = allRows.filter(r => r.all_total > 0);
    const topWifi = [...withTraffic].sort((a, b) => b.all_total - a.all_total)[0];

    document.getElementById('wifiSumActiveName').textContent = activeRow ? activeRow.ssid : 'Not Connected';
    document.getElementById('wifiSumActiveToday').textContent = activeRow
        ? `Today: ${formatBytes(activeRow.today_total)} · Total: ${formatBytes(activeRow.all_total)}`
        : 'Today: 0 B';

    document.getElementById('wifiSumTopName').textContent = topWifi ? topWifi.ssid : '—';
    document.getElementById('wifiSumTopVal').textContent = topWifi ? `All-Time: ${formatBytes(topWifi.all_total)}` : 'All-Time: 0 B';
    document.getElementById('wifiSumCounts').textContent = `${withTraffic.length} Used · ${allRows.length} Total`;

    const query = (document.getElementById('wifiSearchInput').value || '').toLowerCase().trim();
    let rows = allRows;
    if (state.wifiViewMode === 'used') {
        rows = rows.filter(r => r.is_active || r.all_total > 0);
    }
    if (query) {
        rows = rows.filter(r => (r.ssid || '').toLowerCase().includes(query));
    }

    const dir = state.wifiSortDir === 'desc' ? -1 : 1;
    rows.sort((a, b) => {
        if (!query && state.wifiSortCol === 'all_total' && state.wifiSortDir === 'desc') {
            if (a.is_active !== b.is_active) return a.is_active ? -1 : 1;
        }
        const col = state.wifiSortCol;
        if (col === 'ssid') {
            return a.ssid.localeCompare(b.ssid) * dir;
        }
        const diff = ((a[col] || 0) - (b[col] || 0)) * dir;
        if (diff !== 0) return diff;
        return 0;
    });

    document.getElementById('wifiCountLabel').textContent = rows.length;
    const tbody = document.getElementById('wifiUsageTableBody');
    if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="10" style="text-align:center;color:var(--text-muted);">No matching Wi-Fi networks</td></tr>`;
        return;
    }

    const grandTotal = allRows.reduce((acc, r) => acc + (r.all_total || 0), 0);

    tbody.innerHTML = rows.map((r, idx) => {
        const pct = grandTotal > 0 ? ((r.all_total / grandTotal) * 100).toFixed(1) : '0.0';
        const isWired = r.ssid === 'Wired / Hotspot';
        let statusBadge = '';
        if (r.is_active) {
            statusBadge = `<span class="wifi-status-badge wifi-active-badge"><span class="live-dot"></span>CONNECTED</span>`;
        } else if (isWired) {
            statusBadge = `<span class="wifi-status-badge wifi-wired-badge">WIRED / HOTSPOT</span>`;
        } else if (r.all_total > 0) {
            statusBadge = `<span class="wifi-status-badge wifi-recorded-badge">Last: ${escapeHtml(r.last_seen)}</span>`;
        } else {
            statusBadge = `<span class="wifi-status-badge wifi-saved-badge">${escapeHtml(r.last_seen || 'Saved on Mac')}</span>`;
        }

        if (r.is_metered) {
            const capTxt = r.limit_gb > 0
                ? `HOTSPOT · ${Math.min(999, Math.round((r.month_total / (r.limit_gb * 1073741824)) * 100))}% of ${r.limit_gb} GB`
                : 'HOTSPOT';
            statusBadge += ` <span class="wifi-status-badge wifi-hotspot-badge">${capTxt}</span>`;
        }

        const todayCell = r.today_total > 0
            ? `<strong style="color:var(--text-primary);">${formatBytes(r.today_total)}</strong>
               <div style="font-size:10px;color:var(--text-muted);">IN ${formatBytes(r.today_in)} · OUT ${formatBytes(r.today_out)}</div>`
            : `<span class="muted-dash">—</span>`;

        return `
            <tr class="clickable-row ${r.is_active ? 'wifi-active-row' : ''}" data-ssid="${escapeHtml(r.ssid)}">
                <td style="color:var(--text-muted);">${idx + 1}</td>
                <td><div class="wifi-ssid-cell"><strong style="color:var(--text-primary);">${escapeHtml(r.ssid)}</strong></div></td>
                <td>${statusBadge}</td>
                <td class="num-col">${todayCell}</td>
                <td class="num-col">${formatBytesOrDash(r.week_total)}</td>
                <td class="num-col">${formatBytesOrDash(r.month_total)}</td>
                <td class="num-col down-text">${formatBytesOrDash(r.all_in)}</td>
                <td class="num-col up-text">${formatBytesOrDash(r.all_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);">${formatBytesOrDash(r.all_total)}</strong></td>
                <td>
                    <div class="share-bar-cell">
                        <div class="mini-bar"><div class="mini-bar-fill" style="width:${Math.min(100, pct)}%"></div></div>
                        <span>${pct}%</span>
                    </div>
                </td>
            </tr>
        `;
    }).join('');
}

async function openWifiInspector(ssid) {
    currentInspectedWifi = ssid;
    document.getElementById('inspectorWifiTitle').textContent = `Wi-Fi Network: ${ssid}`;
    document.getElementById('wifiDetailModal').classList.remove('hidden');
    try {
        const res = await fetch(`netpulse://app/api/wifi_detail?ssid=${encodeURIComponent(ssid)}`);
        if (!res.ok) return;
        const data = await res.json();
        document.getElementById('wifiInspTotal').textContent = formatBytes(data.total);
        document.getElementById('wifiInspIn').textContent = formatBytes(data.total_in);
        document.getElementById('wifiInspOut').textContent = formatBytes(data.total_out);

        document.getElementById('wifiModalMeteredCheck').checked = !!data.is_metered;
        document.getElementById('wifiModalLimitGb').value = data.limit_gb > 0 ? data.limit_gb : '';

        const daily = data.daily || [];
        state.barChartCache['wifiDetailCanvas'] = daily;
        drawHistoryChart('wifiDetailCanvas', daily);
        setTimeout(() => drawHistoryChart('wifiDetailCanvas', daily), 60);

        const apps = data.apps || [];
        const appsBody = document.getElementById('wifiInspectorAppsBody');
        if (!apps.length) {
            appsBody.innerHTML = `<tr><td colspan="3" style="text-align:center;color:var(--text-muted);">No per-app data recorded on this Wi-Fi yet</td></tr>`;
        } else {
            appsBody.innerHTML = apps.slice(0, 25).map(a => `
                <tr>
                    <td><strong>${escapeHtml(a.app_name)}</strong></td>
                    <td class="num-col down-text">${formatBytes(a.bytes_in)}</td>
                    <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(a.total)}</strong></td>
                </tr>
            `).join('');
        }

        const activeDays = [...daily].filter(d => d.total > 0).reverse();
        const tbody = document.getElementById('wifiInspectorBody');
        if (!activeDays.length) {
            tbody.innerHTML = `<tr><td colspan="4" style="text-align:center;color:var(--text-muted);">No bandwidth recorded in the last 30 days</td></tr>`;
        } else {
            tbody.innerHTML = activeDays.map(d => `
                <tr>
                    <td><strong>${escapeHtml(d.label)}</strong></td>
                    <td class="num-col down-text">${formatBytes(d.bytes_in)}</td>
                    <td class="num-col up-text">${formatBytes(d.bytes_out)}</td>
                    <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(d.total)}</strong></td>
                </tr>
            `).join('');
        }
    } catch (err) {
        console.error('Wi-Fi inspector error:', err);
    }
}

async function saveCurrentWifiLimit() {
    if (!currentInspectedWifi) return;
    const isMet = document.getElementById('wifiModalMeteredCheck').checked;
    const limGb = parseFloat(document.getElementById('wifiModalLimitGb').value || '0') || 0;
    postNativeAction({
        action: 'save_wifi_limit',
        ssid: currentInspectedWifi,
        is_metered: isMet,
        limit_gb: limGb
    });
    await fetch(`netpulse://app/api/save_wifi_limit?ssid=${encodeURIComponent(currentInspectedWifi)}&metered=${isMet ? '1' : '0'}&limit_gb=${encodeURIComponent(limGb)}`).catch(() => {});
    showToast(`Saved Hotspot / Quota settings for ${currentInspectedWifi}`);
    fetchRealtime();
}

function closeWifiInspector() {
    currentInspectedWifi = null;
    document.getElementById('wifiDetailModal').classList.add('hidden');
    hideChartTooltip();
}

// --- History & Analytics View ---
function updateHistoryUI(data) {
    if (state.currentPreset !== 'custom') {
        document.getElementById('filterStartDate').value = data.start_date;
        document.getElementById('filterEndDate').value = data.end_date;
    }

    const t = data.totals;
    document.getElementById('rangeTotalValue').textContent = formatBytes(t.total);
    document.getElementById('rangeInValue').textContent = formatBytes(t.bytes_in);
    document.getElementById('rangeOutValue').textContent = formatBytes(t.bytes_out);

    if (t.peak && t.peak.total > 0) {
        document.getElementById('rangePeakValue').textContent = `${formatBytes(t.peak.total)} (${t.peak.label})`;
    } else {
        document.getElementById('rangePeakValue').textContent = 'No traffic in period';
    }

    state.barChartCache['historyCanvas'] = data.timeline || [];
    if (state.activeView === 'history') {
        drawHistoryChart('historyCanvas', data.timeline || []);
    }
    renderTimelineTable(data.timeline || [], t.total);
    renderHistoryTopApps(data.apps || []);

    if (state.appViewMode === 'history') {
        renderAppTable();
    }
}

function renderHistoryTopApps(apps) {
    const tbody = document.getElementById('historyTopAppsBody');
    if (!apps.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">No application traffic recorded in period</td></tr>`;
        return;
    }
    const grandTotal = apps.reduce((acc, a) => acc + (a.total || 0), 0);
    tbody.innerHTML = apps.slice(0, 25).map(a => {
        const pct = grandTotal > 0 ? ((a.total / grandTotal) * 100).toFixed(1) : '0.0';
        return `
            <tr class="clickable-row" data-app="${escapeHtml(a.app_name)}">
                <td><strong>${escapeHtml(a.app_name)}</strong></td>
                <td class="num-col down-text">${formatBytesOrDash(a.bytes_in)}</td>
                <td class="num-col up-text">${formatBytesOrDash(a.bytes_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(a.total)}</strong></td>
                <td>
                    <div class="share-bar-cell">
                        <div class="mini-bar"><div class="mini-bar-fill" style="width:${Math.min(100, pct)}%"></div></div>
                        <span>${pct}%</span>
                    </div>
                </td>
            </tr>
        `;
    }).join('');
}

function selectPreset(preset) {
    state.currentPreset = preset;
    document.querySelectorAll('#presetTabs .seg-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.preset === preset);
    });
    document.querySelectorAll('.kpi-card').forEach(card => {
        card.classList.toggle('active-period', card.dataset.preset === preset);
    });
    if (preset === 'custom') {
        document.getElementById('filterStartDate').focus();
        return;
    }
    fetchHistory();
}

function applyCustomFilter() {
    state.currentPreset = 'custom';
    document.querySelectorAll('#presetTabs .seg-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.preset === 'custom');
    });
    document.querySelectorAll('.kpi-card').forEach(card => {
        card.classList.remove('active-period');
    });
    fetchHistory();
}

function toggleRealtimePause() {
    state.realtimePaused = !state.realtimePaused;
    const btn = document.getElementById('pauseRealtimeBtn');
    btn.textContent = state.realtimePaused ? 'Resume' : 'Pause';
    btn.classList.toggle('active', state.realtimePaused);
}

function renderTimelineTable(timeline, grandTotal) {
    const tbody = document.getElementById('timelineTableBody');
    document.getElementById('timelineRowCount').textContent = timeline.length;

    const nonZero = [...timeline].reverse();
    if (!nonZero.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">No records for selected interval</td></tr>`;
        return;
    }

    tbody.innerHTML = nonZero.map(row => {
        const pct = grandTotal > 0 ? ((row.total / grandTotal) * 100).toFixed(1) : '0.0';
        return `
            <tr>
                <td>${escapeHtml(row.label)}</td>
                <td class="num-col down-text">${formatBytesOrDash(row.bytes_in)}</td>
                <td class="num-col up-text">${formatBytesOrDash(row.bytes_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);">${formatBytesOrDash(row.total)}</strong></td>
                <td>
                    <div class="share-bar-cell">
                        <div class="mini-bar"><div class="mini-bar-fill" style="width:${Math.min(100, pct)}%"></div></div>
                        <span>${pct}%</span>
                    </div>
                </td>
            </tr>
        `;
    }).join('');
}

// --- Applications Matrix & Sorting ---
function setAppViewMode(mode) {
    state.appViewMode = mode;
    document.getElementById('appModeLiveBtn').classList.toggle('active', mode === 'live');
    document.getElementById('appModeHistBtn').classList.toggle('active', mode === 'history');
    document.getElementById('appColSpeed').textContent = mode === 'live' ? 'Live Rate' : 'Period Share';
    renderAppTable();
}

function onAppSearchInput() {
    const val = document.getElementById('appSearchInput').value;
    document.getElementById('appSearchClear').classList.toggle('hidden', !val);
    renderAppTable();
}

function clearAppSearch() {
    document.getElementById('appSearchInput').value = '';
    document.getElementById('appSearchClear').classList.add('hidden');
    renderAppTable();
}

function setAppSort(col) {
    if (state.appSortCol === col) {
        state.appSortDir = state.appSortDir === 'desc' ? 'asc' : 'desc';
    } else {
        state.appSortCol = col;
        state.appSortDir = col === 'name' ? 'asc' : 'desc';
    }
    ['name', 'metric', 'bytes_in', 'bytes_out', 'total'].forEach(c => {
        const el = document.getElementById(`appSort_${c}`);
        if (el) el.textContent = c === state.appSortCol ? (state.appSortDir === 'desc' ? '▼' : '▲') : '';
    });
    renderAppTable();
}

function renderAppTable() {
    const tbody = document.getElementById('appTableBody');
    const query = (document.getElementById('appSearchInput').value || '').toLowerCase().trim();

    let rows = [];
    if (state.appViewMode === 'live' && state.realtimeData) {
        rows = (state.realtimeData.live_apps || []).map(a => ({
            name: a.app_name,
            metric: a.speed_in + a.speed_out,
            bytes_in: a.bytes_in,
            bytes_out: a.bytes_out,
            total: a.total
        }));
    } else if (state.historyData) {
        const grandTotal = (state.historyData.apps || []).reduce((acc, x) => acc + x.total, 0);
        rows = (state.historyData.apps || []).map(a => ({
            name: a.app_name,
            metric: grandTotal > 0 ? (a.total / grandTotal) * 100 : 0,
            bytes_in: a.bytes_in,
            bytes_out: a.bytes_out,
            total: a.total
        }));
    }

    if (query) {
        rows = rows.filter(r => r.name.toLowerCase().includes(query));
    }

    const dir = state.appSortDir === 'desc' ? -1 : 1;
    rows.sort((a, b) => {
        if (state.appSortCol === 'name') {
            return a.name.localeCompare(b.name) * dir;
        }
        const diff = ((a[state.appSortCol] || 0) - (b[state.appSortCol] || 0)) * dir;
        if (diff !== 0) return diff;
        return (b.total - a.total);
    });

    if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="7" style="text-align:center;color:var(--text-muted);">No matching processes</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map((r, idx) => {
        let secondCol = '';
        if (state.appViewMode === 'live') {
            secondCol = r.metric > 50
                ? `<strong style="color:var(--down-color);">${formatSpeed(r.metric)}</strong>`
                : `<span class="muted-dash">Idle</span>`;
        } else {
            const pctStr = r.metric.toFixed(1);
            secondCol = `
                <div class="share-bar-cell" style="justify-content:flex-end;">
                    <div class="mini-bar"><div class="mini-bar-fill" style="width:${Math.min(100, pctStr)}%"></div></div>
                    <span>${pctStr}%</span>
                </div>
            `;
        }

        return `
            <tr class="clickable-row" data-app="${escapeHtml(r.name)}">
                <td style="color:var(--text-muted);">${idx + 1}</td>
                <td><span class="app-link">${escapeHtml(r.name)}</span></td>
                <td class="num-col">${secondCol}</td>
                <td class="num-col down-text">${formatBytesOrDash(r.bytes_in)}</td>
                <td class="num-col up-text">${formatBytesOrDash(r.bytes_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(r.total)}</strong></td>
                <td class="num-col">
                    <button class="btn btn-ghost btn-xs">Inspect</button>
                </td>
            </tr>
        `;
    }).join('');
}

// --- Sockets, GeoIP & Hardware Interfaces ---
function setSocketFilter(sec) {
    state.socketFilter = sec;
    document.querySelectorAll('[data-sec]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.sec === sec);
    });
    renderConnectionsTable(state.connectionsData || []);
}

function renderInterfacesList(interfaces) {
    const container = document.getElementById('interfacesList');
    if (!interfaces.length) {
        container.innerHTML = `<div style="color:var(--text-muted);font-size:0.8rem;">No active network interfaces</div>`;
        return;
    }

    container.innerHTML = interfaces.map(item => {
        const isActive = (item.speed_in + item.speed_out) > 10;
        return `
            <div class="iface-row ${isActive ? 'is-active' : ''}">
                <div>
                    <div class="iface-title">
                        <span class="status-dot ${isActive ? 'online' : ''}"></span>
                        <span>${escapeHtml(item.label)}</span>
                    </div>
                    <div class="iface-meta">
                        Since boot: <strong>${formatBytes(item.boot_total)}</strong>
                        (IN ${formatBytes(item.boot_bytes_in)} / OUT ${formatBytes(item.boot_bytes_out)})
                    </div>
                </div>
                <div class="iface-rates">
                    <div class="down-text">IN ${formatSpeed(item.speed_in)}</div>
                    <div class="up-text">OUT ${formatSpeed(item.speed_out)}</div>
                </div>
            </div>
        `;
    }).join('');
}

function renderSecurityBadge(status, label) {
    const cls = status === 'suspicious' ? 'sec-suspicious'
              : status === 'warning' ? 'sec-warning'
              : status === 'local' ? 'sec-local'
              : 'sec-verified';
    return `<span class="sec-badge ${cls}">${escapeHtml(label || 'Verified')}</span>`;
}

function renderConnectionsTable(connections) {
    const all = Array.isArray(connections) ? connections : [];
    const verifiedCount = all.filter(c => c.security_status === 'verified' || c.security_status === 'local').length;
    const warnCount = all.filter(c => c.security_status === 'warning' || c.security_status === 'suspicious').length;
    const countries = new Set();
    all.forEach(c => {
        if (c.country_code && c.country_code !== 'LO' && c.country_code !== 'LAN') {
            countries.add(c.country_code);
        }
    });

    document.getElementById('netSumSockets').textContent = all.length;
    document.getElementById('netSumVerified').textContent = verifiedCount;
    const warnEl = document.getElementById('netSumWarnings');
    warnEl.textContent = warnCount;
    warnEl.className = `strip-val ${warnCount > 0 ? 'sec-text-warn' : ''}`;
    document.getElementById('netSumCountries').textContent = countries.size ? Array.from(countries).slice(0, 6).join(', ') : 'Local Only';

    const query = (document.getElementById('connSearchInput').value || '').toLowerCase().trim();
    let filtered = all;
    if (state.socketFilter === 'verified') {
        filtered = filtered.filter(c => c.security_status === 'verified');
    } else if (state.socketFilter === 'warning') {
        filtered = filtered.filter(c => c.security_status === 'warning' || c.security_status === 'suspicious');
    } else if (state.socketFilter === 'local') {
        filtered = filtered.filter(c => c.security_status === 'local');
    }
    if (query) {
        filtered = filtered.filter(c =>
            (c.command || '').toLowerCase().includes(query) ||
            (c.remote_addr || '').toLowerCase().includes(query) ||
            (c.hostname || '').toLowerCase().includes(query) ||
            (c.country_name || '').toLowerCase().includes(query) ||
            (c.asn_isp || '').toLowerCase().includes(query)
        );
    }

    const tbody = document.getElementById('connectionsTableBody');
    if (!filtered.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">No matching active sockets</td></tr>`;
        return;
    }

    tbody.innerHTML = filtered.map(c => {
        const codeTag = c.country_code ? `[${escapeHtml(c.country_code)}] ` : '';
        const country = c.country_name || 'External';
        const asn = c.asn_isp || c.geo_org || '—';
        const portTxt = c.service_port || '';
        const hostHtml = c.hostname ? `<div style="font-size:0.66rem;color:var(--down-color);margin-top:1px;">${escapeHtml(c.hostname)}</div>` : '';
        return `
            <tr>
                <td><strong>${escapeHtml(c.command)}</strong> <span style="color:var(--text-muted);font-size:0.68rem;">#${escapeHtml(c.pid)}</span></td>
                <td>
                    <span class="proto-badge">${escapeHtml(c.proto)}</span>
                    <div style="font-size:0.66rem;color:var(--text-muted);margin-top:2px;">${escapeHtml(portTxt)}</div>
                </td>
                <td style="font-size:0.71rem;word-break:break-all;">
                    <div>${escapeHtml(c.remote_addr !== '—' ? c.remote_addr : c.local_addr)}</div>
                    ${hostHtml}
                </td>
                <td style="font-size:0.72rem;">
                    <div><span style="color:var(--text-muted);font-size:0.67rem;">${codeTag}</span><strong style="color:var(--text-primary);">${escapeHtml(country)}</strong></div>
                    <div style="font-size:0.68rem;color:var(--text-secondary);">${escapeHtml(asn)}</div>
                </td>
                <td>${renderSecurityBadge(c.security_status, c.security_label)}</td>
            </tr>
        `;
    }).join('');
}

// --- Process Inspector Modal ---
async function openAppInspector(appName) {
    currentInspectedApp = appName;
    document.getElementById('inspectorAppTitle').textContent = `Process Profile: ${appName}`;
    document.getElementById('appDetailModal').classList.remove('hidden');

    const killBtn = document.getElementById('inspectorKillBtn');
    killBtn.onclick = () => {
        postNativeAction({ action: 'kill_app', app_name: appName });
        showToast(`Sent SIGTERM to ${appName}`);
        closeAppInspector();
    };

    await loadAppInspectorData(appName, true);
    if (inspectorRefreshTimer) clearInterval(inspectorRefreshTimer);
    inspectorRefreshTimer = setInterval(() => {
        if (currentInspectedApp) loadAppInspectorData(currentInspectedApp, false);
    }, 2500);
}

async function loadAppInspectorData(appName, redrawChart) {
    try {
        const res = await fetch(`netpulse://app/api/app_detail?app=${encodeURIComponent(appName)}`);
        if (!res.ok) return;
        const data = await res.json();
        if (redrawChart) {
            state.barChartCache['appDetailCanvas'] = data.hourly || [];
            drawHistoryChart('appDetailCanvas', data.hourly || []);
        }

        const tbody = document.getElementById('inspectorConnBody');
        const conns = data.connections || [];

        document.getElementById('inspSocketCount').textContent = `${conns.length} Active`;

        const countrySet = new Set();
        const orgSet = new Set();
        let suspiciousCount = 0;
        let warningCount = 0;

        conns.forEach(c => {
            const cc = c.country_code || 'EXT';
            countrySet.add((cc !== 'LO' && cc !== 'LAN') ? cc : 'Local');
            if (c.asn_isp && c.asn_isp !== '—') orgSet.add(c.asn_isp);
            if (c.security_status === 'suspicious') suspiciousCount++;
            else if (c.security_status === 'warning') warningCount++;
        });

        document.getElementById('inspCountryList').textContent = countrySet.size ? Array.from(countrySet).slice(0, 5).join(' · ') : '—';
        document.getElementById('inspOrgCount').textContent = `${orgSet.size} Provider${orgSet.size === 1 ? '' : 's'}`;

        const secStatusEl = document.getElementById('inspSecurityStatus');
        if (suspiciousCount > 0) {
            secStatusEl.textContent = `${suspiciousCount} Suspicious Endpoint${suspiciousCount > 1 ? 's' : ''}`;
            secStatusEl.className = 'sec-text-danger';
        } else if (warningCount > 0) {
            secStatusEl.textContent = `${warningCount} Unencrypted / Custom Port`;
            secStatusEl.className = 'sec-text-warn';
        } else {
            secStatusEl.textContent = conns.length ? 'All Sockets Verified (TLS/Local)' : 'Idle / No External Sockets';
            secStatusEl.className = 'sec-text-ok';
        }

        if (!conns.length) {
            tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">No open sockets for this process right now</td></tr>`;
        } else {
            tbody.innerHTML = conns.map(c => {
                const hostSub = c.hostname ? `<div style="font-size:0.66rem;color:var(--down-color);margin-top:1px;">${escapeHtml(c.hostname)}</div>` : '';
                return `
                <tr>
                    <td>
                        <span class="proto-badge">${escapeHtml(c.proto)}</span>
                        <div style="font-size:0.66rem;color:var(--text-muted);margin-top:2px;">${escapeHtml(c.service_port || '')}</div>
                    </td>
                    <td style="font-size:0.73rem;">
                        <div>${escapeHtml(c.remote_addr !== '—' ? c.remote_addr : c.local_addr)}</div>
                        ${hostSub}
                    </td>`;
            }).map((headHtml, i) => {
                const c = conns[i];
                return `${headHtml}
                    <td><strong>${escapeHtml(c.country_name || 'External')}</strong></td>
                    <td style="color:var(--text-secondary);font-size:0.73rem;">${escapeHtml(c.asn_isp || c.geo_org)}</td>
                    <td>
                        <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
                            ${renderSecurityBadge(c.security_status, c.security_label)}
                            <span class="state-pill">${escapeHtml(c.state)}</span>
                        </div>
                    </td>
                </tr>`;
            }).join('');
        }
    } catch (err) {
        console.error('Inspector error:', err);
    }
}

function closeAppInspector() {
    currentInspectedApp = null;
    if (inspectorRefreshTimer) {
        clearInterval(inspectorRefreshTimer);
        inspectorRefreshTimer = null;
    }
    document.getElementById('appDetailModal').classList.add('hidden');
    hideChartTooltip();
}

function triggerSpeedtest() {
    const stBtn = document.getElementById('runSpeedtestBtn');
    const fullStBtn = document.getElementById('fullSpeedtestBtn');
    const stVal = document.getElementById('diagSpeedtestVal');
    if (stVal) stVal.textContent = 'Measuring Latency...';
    if (stBtn) { stBtn.textContent = 'Testing...'; stBtn.disabled = true; }
    if (fullStBtn) { fullStBtn.textContent = 'Testing...'; fullStBtn.disabled = true; }
    wasSpeedtestRunning = true;
    postNativeAction({ action: 'run_speedtest' });
    fetch('netpulse://app/api/speedtest').catch(() => {});
    showToast('Started Bidirectional Speedtest (Ping + Download + Upload)');
    setTimeout(fetchRealtime, 500);
}

async function fetchSpeedtestAndOutages() {
    try {
        const res = await fetch('netpulse://app/api/speedtest_history');
        if (!res.ok) return;
        const data = await res.json();
        renderSpeedtestHistory(data.history || []);
        renderOutageLog(data.outages || []);
    } catch (err) {
        console.error('Speedtest history error:', err);
    }
}

function renderSpeedtestHistory(rows) {
    const countEl = document.getElementById('stHistCount');
    if (countEl) countEl.textContent = rows.length;
    const tbody = document.getElementById('speedtestHistoryBody');
    if (!tbody) return;

    if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">No speedtest runs saved yet — click "Start Full Speedtest" above</td></tr>`;
        return;
    }

    // Populate latest cards if not currently running
    if (!wasSpeedtestRunning && rows[0]) {
        const latest = rows[0];
        if (document.getElementById('stCardDown').textContent.startsWith('—')) {
            document.getElementById('stCardDown').textContent = `${latest.down_mbps.toFixed(1)} Mbps`;
            document.getElementById('stCardUp').textContent = `${latest.up_mbps.toFixed(1)} Mbps`;
            document.getElementById('stCardPing').textContent = `${latest.ping_ms.toFixed(1)} ms`;
            document.getElementById('stCardJitter').textContent = `${latest.jitter_ms.toFixed(1)} ms`;
        }
    }

    tbody.innerHTML = rows.map(r => `
        <tr>
            <td>${escapeHtml(r.date_str)}</td>
            <td><strong style="color:var(--text-primary);">${escapeHtml(r.ssid)}</strong></td>
            <td class="num-col down-text"><strong>${r.down_mbps.toFixed(1)} Mbps</strong></td>
            <td class="num-col up-text"><strong>${r.up_mbps.toFixed(1)} Mbps</strong></td>
            <td class="num-col">${r.ping_ms.toFixed(1)} ms <span style="color:var(--text-muted);">(${r.jitter_ms.toFixed(1)} ms)</span></td>
        </tr>
    `).join('');
}

function formatDurationSec(sec) {
    if (sec < 60) return `${sec}s`;
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    if (m < 60) return `${m}m ${s}s`;
    const h = Math.floor(m / 60);
    return `${h}h ${m % 60}m`;
}

function renderOutageLog(rows) {
    const countEl = document.getElementById('outageCount');
    if (countEl) countEl.textContent = rows.length;
    const tbody = document.getElementById('outageLogBody');
    if (!tbody) return;

    if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">Zero connection outages recorded — connection has been stable</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(r => `
        <tr>
            <td>${escapeHtml(r.start_str)}</td>
            <td>${escapeHtml(r.end_str.split(' ')[1] || r.end_str)}</td>
            <td class="num-col"><strong class="sec-text-warn">${formatDurationSec(r.duration_sec)}</strong></td>
            <td><strong>${escapeHtml(r.ssid)}</strong></td>
            <td style="color:var(--text-secondary);">${escapeHtml(r.reason)}</td>
        </tr>
    `).join('');
}

function triggerLanScan() {
    const btn = document.getElementById('lanScanBtn');
    if (btn) { btn.textContent = 'Scanning...'; btn.disabled = true; }
    showToast('Scanning local Wi-Fi subnet for active devices...');
    fetchLanDevices(true);
    if (lanPollTimer) clearInterval(lanPollTimer);
    lanPollTimer = setInterval(() => fetchLanDevices(false), 900);
}

async function fetchLanDevices(startScan) {
    try {
        const res = await fetch(`netpulse://app/api/lan_scan${startScan ? '?start=1' : ''}`);
        if (!res.ok) return;
        const data = await res.json();
        const btn = document.getElementById('lanScanBtn');
        if (data.scanning) {
            if (btn) { btn.textContent = 'Scanning...'; btn.disabled = true; }
        } else {
            if (btn) { btn.textContent = 'Scan Subnet'; btn.disabled = false; }
            if (lanPollTimer) { clearInterval(lanPollTimer); lanPollTimer = null; }
        }
        if (Array.isArray(data.devices) && data.devices.length > 0) {
            renderLanDevices(data.devices);
        }
    } catch (err) {
        console.error('LAN scan error:', err);
    }
}

function renderLanDevices(devices) {
    document.getElementById('lanDeviceCount').textContent = devices.length;
    const tbody = document.getElementById('lanDevicesBody');
    tbody.innerHTML = devices.map(d => {
        const pingStr = d.latency_ms >= 0 ? `${d.latency_ms.toFixed(1)} ms` : 'ARP Active';
        const tag = d.is_gateway ? `<span class="sec-badge sec-local" style="margin-left:5px;">GW</span>`
                  : (d.is_self ? `<span class="sec-badge sec-verified" style="margin-left:5px;">THIS MAC</span>` : '');
        const subHost = (d.hostname && d.hostname !== '—') ? `<div style="font-size:0.65rem;color:var(--text-muted);">${escapeHtml(d.hostname)}</div>` : '';
        return `
            <tr>
                <td><strong>${escapeHtml(d.ip)}</strong>${tag}</td>
                <td>
                    <div style="color:var(--text-primary);font-weight:500;">${escapeHtml(d.vendor)}</div>
                    ${subHost}
                </td>
                <td style="font-size:0.69rem;color:var(--text-muted);">${escapeHtml(d.mac)}</td>
                <td class="num-col down-text">${pingStr}</td>
            </tr>
        `;
    }).join('');
}

function revealDatabase() {
    postNativeAction({ action: 'reveal_db' });
}

function backupDatabase() {
    postNativeAction({ action: 'backup_db' });
}

function restoreDatabase() {
    postNativeAction({ action: 'restore_db' });
}

// --- DNS Benchmark & Visual Traceroute ---
function triggerDnsBenchmark() {
    const btn = document.getElementById('dnsBenchBtn');
    if (btn) { btn.textContent = 'Benchmarking DNS...'; btn.disabled = true; }
    showToast('Benchmarking DNS resolvers on active Wi-Fi...');
    fetchDnsBenchmark(true);
    if (dnsPollTimer) clearInterval(dnsPollTimer);
    dnsPollTimer = setInterval(() => fetchDnsBenchmark(false), 800);
}

async function fetchDnsBenchmark(start) {
    try {
        const res = await fetch(`netpulse://app/api/dns_benchmark${start ? '?start=1' : ''}`);
        if (!res.ok) return;
        const data = await res.json();
        const btn = document.getElementById('dnsBenchBtn');
        if (data.running) {
            if (btn) { btn.textContent = 'Benchmarking DNS...'; btn.disabled = true; }
        } else {
            if (btn) { btn.textContent = 'Run DNS Benchmark'; btn.disabled = false; }
            if (dnsPollTimer) { clearInterval(dnsPollTimer); dnsPollTimer = null; }
        }
        if (Array.isArray(data.results) && data.results.length > 0) {
            renderDnsBenchmark(data.results);
        }
    } catch (err) {
        console.error('DNS benchmark error:', err);
    }
}

function renderDnsBenchmark(rows) {
    const tbody = document.getElementById('dnsBenchmarkBody');
    if (!tbody) return;
    const validMax = Math.max(20, ...rows.filter(r => r.avg_ms < 9000).map(r => r.avg_ms));
    tbody.innerHTML = rows.map((r, idx) => {
        const ok = r.avg_ms < 9000;
        const fastestBadge = r.is_fastest ? ` <span class="wifi-status-badge wifi-active-badge">FASTEST</span>` : '';
        const timeStr = ok ? `<strong>${r.avg_ms.toFixed(1)} ms</strong> <span style="color:var(--text-muted);font-size:0.68rem;">(min ${r.min_ms.toFixed(1)})</span>` : `<span class="sec-text-danger">${escapeHtml(r.status)}</span>`;
        const barPct = ok ? Math.max(8, Math.min(100, (r.avg_ms / validMax) * 100)) : 0;
        return `
            <tr class="${r.is_fastest ? 'wifi-active-row' : ''}">
                <td style="color:var(--text-muted);">${idx + 1}</td>
                <td><strong style="color:var(--text-primary);">${escapeHtml(r.provider)}</strong>${fastestBadge}</td>
                <td>${escapeHtml(r.server_ip)}</td>
                <td class="num-col">${timeStr}</td>
                <td>
                    <div class="share-bar-cell">
                        <div class="mini-bar" style="width:95px;"><div class="mini-bar-fill" style="width:${barPct}%"></div></div>
                    </div>
                </td>
            </tr>
        `;
    }).join('');
}

function setTraceTarget(target) {
    const input = document.getElementById('tracerouteTargetInput');
    if (input) input.value = target;
    triggerTraceroute();
}

function triggerTraceroute() {
    const target = (document.getElementById('tracerouteTargetInput').value || '1.1.1.1').trim();
    const btn = document.getElementById('tracerouteRunBtn');
    if (btn) { btn.textContent = 'Tracing...'; btn.disabled = true; }
    document.getElementById('tracerouteBody').innerHTML = `<tr><td colspan="4" style="text-align:center;color:var(--text-muted);">Tracing hops to ${escapeHtml(target)}...</td></tr>`;
    fetchTraceroute(true, target);
    if (tracePollTimer) clearInterval(tracePollTimer);
    tracePollTimer = setInterval(() => fetchTraceroute(false, ''), 900);
}

async function fetchTraceroute(start, target) {
    try {
        const q = start ? `?start=1&target=${encodeURIComponent(target)}` : '';
        const res = await fetch(`netpulse://app/api/traceroute${q}`);
        if (!res.ok) return;
        const data = await res.json();
        const btn = document.getElementById('tracerouteRunBtn');
        if (data.running) {
            if (btn) { btn.textContent = 'Tracing...'; btn.disabled = true; }
        } else {
            if (btn) { btn.textContent = 'Trace Route'; btn.disabled = false; }
            if (tracePollTimer) { clearInterval(tracePollTimer); tracePollTimer = null; }
        }
        if (Array.isArray(data.hops) && data.hops.length > 0) {
            renderTraceroute(data.hops);
        }
    } catch (err) {
        console.error('Traceroute error:', err);
    }
}

function renderTraceroute(hops) {
    const tbody = document.getElementById('tracerouteBody');
    if (!tbody) return;
    tbody.innerHTML = hops.map(h => {
        if (h.timed_out) {
            return `
                <tr>
                    <td style="color:var(--text-muted);">${h.hop}</td>
                    <td style="color:var(--text-muted);">* (No ICMP reply)</td>
                    <td style="color:var(--text-muted);">—</td>
                    <td class="num-col muted-dash">Timeout</td>
                </tr>
            `;
        }
        const hostLine = (h.hostname && h.hostname !== '—') ? `<div style="font-size:0.66rem;color:var(--down-color);">${escapeHtml(h.hostname)}</div>` : '';
        const msStr = h.latency_ms >= 0 ? `${h.latency_ms.toFixed(1)} ms` : '—';
        return `
            <tr>
                <td style="color:var(--text-muted);">${h.hop}</td>
                <td>
                    <strong>${escapeHtml(h.ip)}</strong>
                    ${hostLine}
                </td>
                <td style="font-size:0.72rem;">
                    <div><strong style="color:var(--text-primary);">${escapeHtml(h.country)}</strong></div>
                    <div style="font-size:0.67rem;color:var(--text-secondary);">${escapeHtml(h.asn_isp)}</div>
                </td>
                <td class="num-col down-text"><strong>${msStr}</strong></td>
            </tr>
        `;
    }).join('');
}

// --- Interactive Canvas Charts & Crosshair Tooltips ---
function setupChartHover(canvasId, type) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;

    canvas.addEventListener('mousemove', (e) => {
        const rect = canvas.getBoundingClientRect();
        const mx = e.clientX - rect.left;
        const padLeft = 72;
        const padRight = type === 'realtime' ? 24 : 20;
        const plotW = rect.width - padLeft - padRight;
        if (mx < padLeft || mx > rect.width - padRight || plotW <= 0) {
            hideChartTooltip();
            return;
        }

        if (type === 'realtime') {
            const history = (state.realtimeData && state.realtimeData.realtime_history) ? state.realtimeData.realtime_history.slice(-120) : [];
            if (history.length < 2) return;
            const ratio = Math.max(0, Math.min(1, (mx - padLeft) / plotW));
            const idx = Math.round(ratio * 119) - (120 - history.length);
            if (idx >= 0 && idx < history.length) {
                state.hoverRealtimeIdx = idx;
                const pt = history[idx];
                showChartTooltip(e.clientX, e.clientY, `
                    <div class="tt-head">${escapeHtml(pt.time_str)}</div>
                    <div class="tt-row"><span class="down-text">Download</span><strong>${formatSpeed(pt.speed_in)}</strong></div>
                    <div class="tt-row"><span class="up-text">Upload</span><strong>${formatSpeed(pt.speed_out)}</strong></div>
                `);
                drawRealtimeChart(history);
            }
        } else {
            const timeline = state.barChartCache[canvasId] || [];
            if (!timeline.length) return;
            const slotW = plotW / timeline.length;
            const idx = Math.min(timeline.length - 1, Math.max(0, Math.floor((mx - padLeft) / slotW)));
            state.hoverBarCanvas = canvasId;
            state.hoverBarIdx = idx;
            const item = timeline[idx];
            showChartTooltip(e.clientX, e.clientY, `
                <div class="tt-head">${escapeHtml(item.label)}</div>
                <div class="tt-row"><span class="down-text">Download</span><strong>${formatBytes(item.bytes_in)}</strong></div>
                <div class="tt-row"><span class="up-text">Upload</span><strong>${formatBytes(item.bytes_out)}</strong></div>
                <div class="tt-row"><span>Total</span><strong>${formatBytes(item.total)}</strong></div>
            `);
            drawHistoryChart(canvasId, timeline);
        }
    });

    canvas.addEventListener('mouseleave', () => {
        state.hoverRealtimeIdx = -1;
        state.hoverBarCanvas = null;
        state.hoverBarIdx = -1;
        hideChartTooltip();
        if (type === 'realtime' && state.realtimeData) {
            drawRealtimeChart(state.realtimeData.realtime_history || []);
        } else if (state.barChartCache[canvasId]) {
            drawHistoryChart(canvasId, state.barChartCache[canvasId]);
        }
    });
}

function showChartTooltip(cx, cy, html) {
    const tt = document.getElementById('chartTooltip');
    tt.innerHTML = html;
    tt.classList.remove('hidden');
    const w = tt.offsetWidth || 170;
    const h = tt.offsetHeight || 80;
    let left = cx + 14;
    let top = cy - h - 10;
    if (left + w > window.innerWidth - 12) left = cx - w - 14;
    if (top < 12) top = cy + 14;
    tt.style.left = `${left}px`;
    tt.style.top = `${top}px`;
}

function hideChartTooltip() {
    const tt = document.getElementById('chartTooltip');
    if (tt) tt.classList.add('hidden');
}

function drawRealtimeChart(history) {
    const canvas = document.getElementById('realtimeCanvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;

    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    const w = rect.width;
    const h = rect.height;
    const pad = { top: 12, right: 24, bottom: 24, left: 72 };
    const plotW = w - pad.left - pad.right;
    const plotH = h - pad.top - pad.bottom;

    ctx.clearRect(0, 0, w, h);

    const maxPoints = 120;
    const points = history.slice(-maxPoints);

    let maxSpeed = 1024 * 10;
    points.forEach(p => {
        if (p.speed_in > maxSpeed) maxSpeed = p.speed_in;
        if (p.speed_out > maxSpeed) maxSpeed = p.speed_out;
    });
    maxSpeed *= 1.15;

    const isLight = state.theme === 'light';
    ctx.strokeStyle = isLight ? 'rgba(15, 23, 42, 0.08)' : 'rgba(255, 255, 255, 0.05)';
    ctx.fillStyle = isLight ? '#475569' : '#71717a';
    ctx.font = '10px "JetBrains Mono", monospace';
    ctx.textAlign = 'right';
    const gridSteps = 4;
    for (let i = 0; i <= gridSteps; i++) {
        const y = pad.top + (plotH / gridSteps) * i;
        const val = maxSpeed * (1 - i / gridSteps);
        ctx.beginPath();
        ctx.moveTo(pad.left, y);
        ctx.lineTo(w - pad.right, y);
        ctx.stroke();
        ctx.fillText(formatSpeed(val), pad.left - 8, y + 3);
    }

    if (points.length < 2) return;

    const getX = (idx) => {
        const offset = maxPoints - points.length;
        return pad.left + ((idx + offset) / (maxPoints - 1)) * plotW;
    };
    const getY = (val) => pad.top + plotH - (Math.min(val, maxSpeed) / maxSpeed) * plotH;

    const drawSeries = (key, strokeColor, fillTopColor) => {
        ctx.beginPath();
        points.forEach((p, idx) => {
            const x = getX(idx);
            const y = getY(p[key]);
            if (idx === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.strokeStyle = strokeColor;
        ctx.lineWidth = 1.85;
        ctx.stroke();

        const grad = ctx.createLinearGradient(0, pad.top, 0, pad.top + plotH);
        grad.addColorStop(0, fillTopColor);
        grad.addColorStop(1, 'rgba(0, 0, 0, 0)');
        ctx.lineTo(getX(points.length - 1), pad.top + plotH);
        ctx.lineTo(getX(0), pad.top + plotH);
        ctx.closePath();
        ctx.fillStyle = grad;
        ctx.fill();
    };

    drawSeries('speed_in', '#10b981', 'rgba(16, 185, 129, 0.22)');
    drawSeries('speed_out', '#3b82f6', 'rgba(59, 130, 246, 0.18)');

    // Hover Crosshair
    if (state.hoverRealtimeIdx >= 0 && state.hoverRealtimeIdx < points.length) {
        const hx = getX(state.hoverRealtimeIdx);
        const pt = points[state.hoverRealtimeIdx];
        ctx.save();
        ctx.strokeStyle = isLight ? 'rgba(15, 23, 42, 0.3)' : 'rgba(255, 255, 255, 0.25)';
        ctx.setLineDash([3, 3]);
        ctx.beginPath();
        ctx.moveTo(hx, pad.top);
        ctx.lineTo(hx, pad.top + plotH);
        ctx.stroke();
        ctx.setLineDash([]);

        ctx.fillStyle = '#10b981';
        ctx.beginPath();
        ctx.arc(hx, getY(pt.speed_in), 4, 0, Math.PI * 2);
        ctx.fill();

        ctx.fillStyle = '#3b82f6';
        ctx.beginPath();
        ctx.arc(hx, getY(pt.speed_out), 4, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
    }

    ctx.fillStyle = isLight ? '#475569' : '#71717a';
    ctx.font = '10px "JetBrains Mono", monospace';
    ctx.textAlign = 'center';
    let lastDrawnX = -999;
    const minLabelGap = 85;
    for (let i = 0; i < points.length; i++) {
        const isLast = (i === points.length - 1);
        if ((i % 20 === 0) || isLast) {
            const x = getX(i);
            if (x - lastDrawnX >= minLabelGap) {
                ctx.fillText(points[i].time_str, x, h - 6);
                lastDrawnX = x;
            }
        }
    }
}

function drawHistoryChart(canvasId, timeline) {
    state.barChartCache[canvasId] = timeline;
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;

    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    const w = rect.width;
    const h = rect.height;
    const pad = { top: 14, right: 20, bottom: 26, left: 72 };
    const plotW = w - pad.left - pad.right;
    const plotH = h - pad.top - pad.bottom;

    ctx.clearRect(0, 0, w, h);

    const isLight = state.theme === 'light';
    if (!timeline.length) {
        ctx.fillStyle = isLight ? '#475569' : '#71717a';
        ctx.font = '12px Inter, sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText('No recorded data for the selected interval', w / 2, h / 2);
        return;
    }

    let maxVal = 1024 * 1024;
    timeline.forEach(item => {
        if (item.total > maxVal) maxVal = item.total;
    });
    maxVal *= 1.15;

    ctx.strokeStyle = isLight ? 'rgba(15, 23, 42, 0.08)' : 'rgba(255, 255, 255, 0.05)';
    ctx.fillStyle = isLight ? '#475569' : '#71717a';
    ctx.font = '10px "JetBrains Mono", monospace';
    ctx.textAlign = 'right';
    const gridSteps = 4;
    for (let i = 0; i <= gridSteps; i++) {
        const y = pad.top + (plotH / gridSteps) * i;
        const val = maxVal * (1 - i / gridSteps);
        ctx.beginPath();
        ctx.moveTo(pad.left, y);
        ctx.lineTo(w - pad.right, y);
        ctx.stroke();
        ctx.fillText(formatBytes(val, 1), pad.left - 8, y + 3);
    }

    const n = timeline.length;
    const slotW = plotW / n;
    const barW = Math.max(4, Math.min(32, slotW * 0.58));
    let lastLabelX = -999;
    const minHistGap = n === 24 ? 36 : 52;

    timeline.forEach((item, idx) => {
        const centerX = pad.left + slotW * idx + slotW / 2;
        const x = centerX - barW / 2;

        if (state.hoverBarCanvas === canvasId && state.hoverBarIdx === idx) {
            ctx.fillStyle = isLight ? 'rgba(15, 23, 42, 0.05)' : 'rgba(255, 255, 255, 0.05)';
            ctx.fillRect(pad.left + slotW * idx, pad.top, slotW, plotH);
        }

        if (item.total > 0) {
            const inH = (item.bytes_in / maxVal) * plotH;
            const outH = (item.bytes_out / maxVal) * plotH;

            const inY = pad.top + plotH - inH;
            ctx.fillStyle = '#10b981';
            ctx.fillRect(x, inY, barW, Math.max(2, inH));

            if (item.bytes_out > 0) {
                const outY = inY - outH;
                ctx.fillStyle = '#3b82f6';
                ctx.fillRect(x, outY, barW, Math.max(1.5, outH));
            }
        } else {
            ctx.fillStyle = isLight ? 'rgba(15, 23, 42, 0.10)' : 'rgba(255, 255, 255, 0.08)';
            ctx.fillRect(x, pad.top + plotH - 2, barW, 2);
        }

        if (centerX - lastLabelX >= minHistGap) {
            ctx.fillStyle = isLight ? '#475569' : '#71717a';
            ctx.font = '10px "JetBrains Mono", monospace';
            ctx.textAlign = 'center';
            let shortLabel = item.label;
            if (shortLabel.length > 10 && shortLabel.includes(' ')) {
                shortLabel = shortLabel.split(' ')[1];
            } else if (shortLabel.length === 10) {
                shortLabel = shortLabel.slice(5);
            }
            ctx.fillText(shortLabel, centerX, h - 7);
            lastLabelX = centerX;
        }
    });
}

function exportData(format) {
    const start = document.getElementById('filterStartDate').value;
    const end = document.getElementById('filterEndDate').value;
    const groupBy = document.getElementById('filterGroupBy').value === 'auto' ? 'day' : document.getElementById('filterGroupBy').value;
    postNativeAction({
        action: 'export',
        format: format,
        start: start,
        end: end,
        group_by: groupBy,
        interface: state.selectedInterface
    });
}

function openLimitsModal() {
    document.getElementById('inputDailyLimit').value = state.settings.daily_limit_gb || '0';
    document.getElementById('inputWeeklyLimit').value = state.settings.weekly_limit_gb || '0';
    document.getElementById('inputMonthlyLimit').value = state.settings.monthly_limit_gb || '500';
    document.getElementById('inputAlertPct').value = state.settings.alert_threshold_pct || '85';
    document.getElementById('inputLaunchAtLogin').checked = state.settings.launch_at_login === '1';
    document.getElementById('limitsModal').classList.remove('hidden');
}

function closeLimitsModal() {
    document.getElementById('limitsModal').classList.add('hidden');
}

function saveSettings() {
    const newSettings = {
        daily_limit_gb: document.getElementById('inputDailyLimit').value || '0',
        weekly_limit_gb: document.getElementById('inputWeeklyLimit').value || '0',
        monthly_limit_gb: document.getElementById('inputMonthlyLimit').value || '0',
        alert_threshold_pct: document.getElementById('inputAlertPct').value || '85',
        launch_at_login: document.getElementById('inputLaunchAtLogin').checked ? '1' : '0',
        theme: state.theme || 'dark'
    };
    state.settings = newSettings;
    postNativeAction({
        action: 'save_settings',
        settings: newSettings
    });
    fetchRealtime();
    closeLimitsModal();
    showToast('Saved Quotas & System Configuration');
}

function checkUpdates() {
    const modalUpdateStatus = document.getElementById('modalUpdateStatus');
    if (modalUpdateStatus) modalUpdateStatus.textContent = 'Checking GitHub for updates...';
    postNativeAction({ action: 'check_updates' });
    fetch('netpulse://app/api/check_updates').catch(() => {});
    setTimeout(fetchRealtime, 800);
    setTimeout(fetchRealtime, 2000);
}

function installUpdate() {
    const modalUpdateStatus = document.getElementById('modalUpdateStatus');
    if (modalUpdateStatus) modalUpdateStatus.textContent = 'Downloading & installing latest build from GitHub...';
    const topUpdateLabel = document.getElementById('topUpdateLabel');
    if (topUpdateLabel) topUpdateLabel.textContent = 'Updating...';
    postNativeAction({ action: 'install_update' });
    fetch('netpulse://app/api/install_update').catch(() => {});
}

function handleTopUpdateBtn() {
    if (state.latestDiagnostics && state.latestDiagnostics.update_available) {
        installUpdate();
    } else {
        checkUpdates();
        openLimitsModal();
    }
}
