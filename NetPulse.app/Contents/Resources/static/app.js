/**
 * NetPulse macOS — Native Telemetry Frontend Controller (English UI)
 */

const state = {
    selectedInterface: 'all',
    currentPreset: 'today',
    realtimePaused: false,
    appViewMode: 'live',
    wifiViewMode: 'used',
    theme: 'dark',
    realtimeData: null,
    historyData: null,
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

function formatBytes(bytes, decimals = 2) {
    if (!bytes || bytes <= 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.min(sizes.length - 1, Math.floor(Math.log(bytes) / Math.log(k)));
    const val = bytes / Math.pow(k, i);
    const dec = i >= 3 ? decimals : (i === 2 ? 1 : 0);
    return `${val.toFixed(dec)} ${sizes[i]}`;
}

function formatSpeed(bytesPerSec) {
    if (!bytesPerSec || bytesPerSec < 1) return '0 B/s';
    return `${formatBytes(bytesPerSec, 2)}/s`;
}

function toISODate(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

function postNativeAction(payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.netpulseNative) {
        window.webkit.messageHandlers.netpulseNative.postMessage(payload);
    }
}

document.addEventListener('DOMContentLoaded', () => {
    const now = new Date();
    const todayStr = toISODate(now);
    document.getElementById('filterStartDate').value = todayStr;
    document.getElementById('filterEndDate').value = todayStr;
    document.getElementById('todayDateLabel').textContent = now.toLocaleDateString('en-US', {
        month: 'short', day: '2-digit', year: 'numeric'
    });

    document.getElementById('globalInterfaceSelect').addEventListener('change', (e) => {
        state.selectedInterface = e.target.value;
        fetchRealtime();
        fetchHistory();
    });

    document.getElementById('openLimitsModalBtn').addEventListener('click', openLimitsModal);

    loadSettings();
    fetchRealtime();
    fetchHistory();
    fetchConnections();
    setTimeout(fetchConnections, 1500);
    setTimeout(fetchConnections, 3200);

    setInterval(fetchRealtime, 1000);
    setInterval(fetchHistory, 10000);
    setInterval(fetchConnections, 4500);

    const redrawCharts = () => {
        if (state.realtimeData && !state.realtimePaused) {
            drawRealtimeChart(state.realtimeData.realtime_history || []);
        }
        if (state.historyData) {
            drawHistoryChart('historyCanvas', state.historyData.timeline || []);
        }
    };

    window.addEventListener('resize', redrawCharts);
    if (window.ResizeObserver) {
        const ro = new ResizeObserver(() => requestAnimationFrame(redrawCharts));
        const rtWrap = document.querySelector('.realtime-frame');
        const hsWrap = document.querySelector('.history-frame');
        if (rtWrap) ro.observe(rtWrap);
        if (hsWrap) ro.observe(hsWrap);
    }
});

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
        renderConnectionsTable(data.connections || []);
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
        lbl.textContent = state.theme === 'light' ? 'Dark Mode' : 'Light Mode';
    }
    if (state.realtimeData && !state.realtimePaused) {
        drawRealtimeChart(state.realtimeData.realtime_history || []);
    }
    if (state.historyData) {
        drawHistoryChart('historyCanvas', state.historyData.timeline || []);
    }
}

function toggleTheme() {
    const next = state.theme === 'light' ? 'dark' : 'light';
    applyTheme(next);
    state.settings.theme = next;
    postNativeAction({ action: 'set_theme', theme: next });
}

function updateRealtimeUI(data) {
    document.getElementById('headerSpeedIn').textContent = formatSpeed(data.speed_in);
    document.getElementById('headerSpeedOut').textContent = formatSpeed(data.speed_out);
    document.getElementById('peakSpeedIn').textContent = formatSpeed(data.peak_speed_in);
    document.getElementById('peakSpeedOut').textContent = formatSpeed(data.peak_speed_out);

    if (data.diagnostics) {
        const d = data.diagnostics;
        document.getElementById('diagProfile').textContent = d.network_profile + (d.vpn_active ? ' [VPN]' : '');
        document.getElementById('diagLocalIP').textContent = `Local IP: ${d.local_ip} (Gateway: ${d.router_ip})`;
        const wifiUsageEl = document.getElementById('diagWiFiUsage');
        if (wifiUsageEl && Array.isArray(data.wifi_usage)) {
            const activeWifi = data.wifi_usage.find(w => w.is_active);
            if (activeWifi) {
                wifiUsageEl.textContent = `On this Wi-Fi: Today ${formatBytes(activeWifi.today_total)} · Total ${formatBytes(activeWifi.all_total)}`;
            } else {
                wifiUsageEl.textContent = `On this Wi-Fi: Today 0 B · Total 0 B`;
            }
        }
        document.getElementById('diagPublicIP').textContent = d.public_ip || '—';
        document.getElementById('diagISP').textContent = d.isp_org || '—';
        document.getElementById('diagLocation').textContent = `Location: ${d.country_city || '—'}`;
        document.getElementById('diagPingRouter').textContent = d.ping_router_ms >= 0 ? `${d.ping_router_ms.toFixed(1)} ms` : '—';
        document.getElementById('diagPingInternet').textContent = d.ping_internet_ms >= 0 ? `${d.ping_internet_ms.toFixed(1)} ms` : '—';
        document.getElementById('diagDbSize').textContent = `SQLite DB: ${d.db_size_kb} KB`;

        if (d.db_path) {
            document.getElementById('modalDbPath').textContent = d.db_path;
        }

        const stBtn = document.getElementById('runSpeedtestBtn');
        const stVal = document.getElementById('diagSpeedtestVal');
        if (d.speedtest_running) {
            stVal.textContent = d.speedtest_down_mbps > 0
                ? `Testing: ${d.speedtest_down_mbps.toFixed(1)} Mbps...`
                : 'Running benchmark...';
            stBtn.textContent = 'Testing...';
            stBtn.disabled = true;
        } else {
            stBtn.textContent = 'Run Speedtest';
            stBtn.disabled = false;
            if (d.speedtest_down_mbps > 0) {
                stVal.textContent = `Download: ${d.speedtest_down_mbps.toFixed(1)} Mbps`;
            }
        }

        // Software Update UI synchronization
        const topUpdateLabel = document.getElementById('topUpdateLabel');
        const topUpdateBtn = document.getElementById('topUpdateBtn');
        const modalUpdateStatus = document.getElementById('modalUpdateStatus');
        const banner = document.getElementById('updateNotificationBanner');
        const bannerTitle = document.getElementById('updateBannerTitle');
        const bannerNotes = document.getElementById('updateBannerNotes');

        if (modalUpdateStatus && d.update_status) {
            modalUpdateStatus.textContent = d.update_status + (d.update_notes ? ` — ${d.update_notes}` : '');
        }
        if (topUpdateLabel) {
            if (d.update_installing) {
                topUpdateLabel.textContent = 'Updating...';
            } else if (d.update_available) {
                topUpdateLabel.textContent = `Update Available (v${d.latest_version})`;
                if (topUpdateBtn) topUpdateBtn.style.borderColor = '#10b981';
            } else if (d.update_checking) {
                topUpdateLabel.textContent = 'Checking...';
            } else {
                topUpdateLabel.textContent = `v${d.app_version || '2.2.0'} · Update`;
                if (topUpdateBtn) topUpdateBtn.style.borderColor = '';
            }
        }
        if (banner) {
            if (d.update_available) {
                banner.classList.remove('hidden');
                if (bannerTitle) bannerTitle.textContent = `New NetPulse v${d.latest_version} is available on GitHub`;
                if (bannerNotes) bannerNotes.textContent = d.update_notes || '';
            } else {
                banner.classList.add('hidden');
            }
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

    renderInterfacesList(data.interfaces || []);
    renderWiFiUsageTable(data.wifi_usage || []);

    if (state.appViewMode === 'live') {
        renderAppTable();
    }

    if (!state.realtimePaused) {
        drawRealtimeChart(data.realtime_history || []);
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

    drawHistoryChart('historyCanvas', data.timeline || []);
    renderTimelineTable(data.timeline || [], t.total);

    if (state.appViewMode === 'history') {
        renderAppTable();
    }
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

function setAppViewMode(mode) {
    state.appViewMode = mode;
    document.getElementById('appModeLiveBtn').classList.toggle('active', mode === 'live');
    document.getElementById('appModeHistBtn').classList.toggle('active', mode === 'history');
    document.getElementById('appColSpeed').textContent = mode === 'live' ? 'Rate' : 'Share';
    renderAppTable();
}

function setWiFiViewMode(mode) {
    state.wifiViewMode = mode;
    const usedBtn = document.getElementById('wifiModeUsedBtn');
    const allBtn = document.getElementById('wifiModeAllBtn');
    if (usedBtn) usedBtn.classList.toggle('active', mode === 'used');
    if (allBtn) allBtn.classList.toggle('active', mode === 'all');
    if (state.realtimeData && state.realtimeData.wifi_usage) {
        renderWiFiUsageTable(state.realtimeData.wifi_usage);
    }
}

function renderWiFiUsageTable(wifiRows) {
    const tbody = document.getElementById('wifiUsageTableBody');
    if (!tbody) return;

    let rows = Array.isArray(wifiRows) ? [...wifiRows] : [];
    if (state.wifiViewMode === 'used') {
        rows = rows.filter(r => r.is_active || !r.is_saved_only || r.all_total > 0);
    }

    if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="9" style="text-align:center;color:#71717a;">No Wi-Fi usage data recorded yet</td></tr>`;
        return;
    }

    const grandTotal = rows.reduce((acc, r) => acc + (r.all_total || 0), 0);

    tbody.innerHTML = rows.map(r => {
        const pct = grandTotal > 0 ? ((r.all_total / grandTotal) * 100).toFixed(1) : '0.0';
        const statusBadge = r.is_active
            ? `<span class="wifi-status-badge wifi-active-badge"><span class="live-dot"></span>CONNECTED</span>`
            : (r.all_total > 0
                ? `<span class="wifi-status-badge wifi-recorded-badge">Last: ${escapeHtml(r.last_seen)}</span>`
                : `<span class="wifi-status-badge wifi-saved-badge">Saved on Mac</span>`);

        const rowClass = r.is_active ? 'wifi-active-row' : '';
        return `
            <tr class="${rowClass}">
                <td>
                    <div class="wifi-ssid-cell">
                        <strong style="color:var(--text-primary);">${escapeHtml(r.ssid)}</strong>
                    </div>
                </td>
                <td>${statusBadge}</td>
                <td class="num-col">
                    <strong style="color:var(--text-primary);">${formatBytes(r.today_total)}</strong>
                    <div style="font-size:10px;color:var(--text-muted);">↓ ${formatBytes(r.today_in)} · ↑ ${formatBytes(r.today_out)}</div>
                </td>
                <td class="num-col">${formatBytes(r.week_total)}</td>
                <td class="num-col">${formatBytes(r.month_total)}</td>
                <td class="num-col down-text">${formatBytes(r.all_in)}</td>
                <td class="num-col up-text">${formatBytes(r.all_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);font-size:13px;">${formatBytes(r.all_total)}</strong></td>
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

function renderTimelineTable(timeline, grandTotal) {
    const tbody = document.getElementById('timelineTableBody');
    document.getElementById('timelineRowCount').textContent = timeline.length;

    if (!timeline.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:#71717a;">No records for selected interval</td></tr>`;
        return;
    }

    const sorted = [...timeline].reverse();
    tbody.innerHTML = sorted.map(row => {
        const pct = grandTotal > 0 ? ((row.total / grandTotal) * 100).toFixed(1) : '0.0';
        return `
            <tr>
                <td>${row.label}</td>
                <td class="num-col down-text">${formatBytes(row.bytes_in)}</td>
                <td class="num-col up-text">${formatBytes(row.bytes_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(row.total)}</strong></td>
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

function renderAppTable() {
    const tbody = document.getElementById('appTableBody');
    const query = (document.getElementById('appSearchInput').value || '').toLowerCase().trim();

    let rows = [];
    if (state.appViewMode === 'live' && state.realtimeData) {
        rows = (state.realtimeData.live_apps || []).map(a => ({
            name: a.app_name,
            speed: a.speed_in + a.speed_out,
            bytes_in: a.bytes_in,
            bytes_out: a.bytes_out,
            total: a.total
        }));
    } else if (state.historyData) {
        const grandTotal = (state.historyData.apps || []).reduce((acc, x) => acc + x.total, 0);
        rows = (state.historyData.apps || []).map(a => ({
            name: a.app_name,
            pct: grandTotal > 0 ? (a.total / grandTotal) * 100 : 0,
            bytes_in: a.bytes_in,
            bytes_out: a.bytes_out,
            total: a.total
        }));
    }

    if (query) {
        rows = rows.filter(r => r.name.toLowerCase().includes(query));
    }

    if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;color:#71717a;">No matching processes</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(r => {
        let secondCol = '';
        if (state.appViewMode === 'live') {
            if (r.speed > 50) {
                secondCol = `<span style="color:var(--text-primary);font-weight:600;">${formatSpeed(r.speed)}</span>`;
            } else {
                secondCol = `<span style="color:#52525b;">0 B/s</span>`;
            }
        } else {
            const pctStr = r.pct.toFixed(1);
            secondCol = `
                <div class="share-bar-cell" style="justify-content:flex-end;">
                    <div class="mini-bar"><div class="mini-bar-fill" style="width:${Math.min(100, pctStr)}%"></div></div>
                    <span>${pctStr}%</span>
                </div>
            `;
        }

        const safeName = escapeHtml(r.name).replace(/'/g, "\\'");
        return `
            <tr>
                <td><a class="app-link" onclick="openAppInspector('${safeName}')">${escapeHtml(r.name)}</a></td>
                <td class="num-col">${secondCol}</td>
                <td class="num-col down-text">${formatBytes(r.bytes_in)}</td>
                <td class="num-col up-text">${formatBytes(r.bytes_out)}</td>
                <td class="num-col"><strong style="color:var(--text-primary);">${formatBytes(r.total)}</strong></td>
                <td class="num-col">
                    <button class="btn btn-ghost btn-xs" onclick="openAppInspector('${safeName}')">Inspect</button>
                </td>
            </tr>
        `;
    }).join('');
}

function renderInterfacesList(interfaces) {
    const container = document.getElementById('interfacesList');
    if (!interfaces.length) {
        container.innerHTML = `<div style="color:#71717a;font-size:0.8rem;">No active network interfaces</div>`;
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
    const tbody = document.getElementById('connectionsTableBody');
    if (!connections.length) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:#71717a;">No active connections</td></tr>`;
        return;
    }

    tbody.innerHTML = connections.map(c => {
        const codeTag = c.country_code ? `[${escapeHtml(c.country_code)}] ` : '';
        const country = c.country_name || 'External';
        const asn = c.asn_isp || c.geo_org || '—';
        const portTxt = c.service_port || '';
        return `
            <tr>
                <td><strong>${escapeHtml(c.command)}</strong> <span style="color:#71717a;font-size:0.7rem;">#${c.pid}</span></td>
                <td>
                    <span class="proto-badge">${escapeHtml(c.proto)}</span>
                    <div style="font-size:0.68rem;color:#71717a;margin-top:2px;">${escapeHtml(portTxt)}</div>
                </td>
                <td style="font-size:0.72rem;word-break:break-all;font-family:'JetBrains Mono',monospace;">${escapeHtml(c.remote_addr !== '—' ? c.remote_addr : c.local_addr)}</td>
                <td style="font-size:0.73rem;">
                    <div><span style="color:var(--text-muted);font-family:'JetBrains Mono',monospace;font-size:0.68rem;">${codeTag}</span><strong>${escapeHtml(country)}</strong></div>
                    <div style="font-size:0.69rem;color:#a1a1aa;">${escapeHtml(asn)}</div>
                </td>
                <td>${renderSecurityBadge(c.security_status, c.security_label)}</td>
            </tr>
        `;
    }).join('');
}

let inspectorRefreshTimer = null;
let currentInspectedApp = null;

// --- App Inspector Modal ---
async function openAppInspector(appName) {
    currentInspectedApp = appName;
    document.getElementById('inspectorAppTitle').textContent = `Process Profile: ${appName}`;
    document.getElementById('appDetailModal').classList.remove('hidden');

    const killBtn = document.getElementById('inspectorKillBtn');
    killBtn.onclick = () => {
        postNativeAction({ action: 'kill_app', app_name: appName });
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
            drawHistoryChart('appDetailCanvas', data.hourly || []);
        }

        const tbody = document.getElementById('inspectorConnBody');
        const conns = data.connections || [];

        // Populate GeoIP & Security Summary Strip
        const socketCountEl = document.getElementById('inspSocketCount');
        const countryListEl = document.getElementById('inspCountryList');
        const orgCountEl = document.getElementById('inspOrgCount');
        const secStatusEl = document.getElementById('inspSecurityStatus');

        if (socketCountEl) socketCountEl.textContent = `${conns.length} Active`;

        const countrySet = new Set();
        const orgSet = new Set();
        let suspiciousCount = 0;
        let warningCount = 0;

        conns.forEach(c => {
            const cc = c.country_code || 'EXT';
            if (cc !== 'LO' && cc !== 'LAN') {
                countrySet.add(cc);
            } else {
                countrySet.add('Local');
            }
            if (c.asn_isp && c.asn_isp !== '—') orgSet.add(c.asn_isp);
            if (c.security_status === 'suspicious') suspiciousCount++;
            else if (c.security_status === 'warning') warningCount++;
        });

        if (countryListEl) {
            countryListEl.textContent = countrySet.size ? Array.from(countrySet).slice(0, 5).join(' · ') : '—';
        }
        if (orgCountEl) {
            orgCountEl.textContent = `${orgSet.size} Provider${orgSet.size === 1 ? '' : 's'}`;
        }
        if (secStatusEl) {
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
        }

        if (!conns.length) {
            tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:#71717a;">No open sockets for this process right now</td></tr>`;
        } else {
            tbody.innerHTML = conns.map(c => `
                <tr>
                    <td>
                        <span class="proto-badge">${escapeHtml(c.proto)}</span>
                        <div style="font-size:0.68rem;color:#71717a;margin-top:2px;">${escapeHtml(c.service_port || '')}</div>
                    </td>
                    <td style="font-family:'JetBrains Mono',monospace;font-size:0.74rem;">${escapeHtml(c.remote_addr !== '—' ? c.remote_addr : c.local_addr)}</td>
                    <td><strong>${escapeHtml(c.country_name || 'External')}</strong></td>
                    <td style="color:#a1a1aa;font-size:0.74rem;">${escapeHtml(c.asn_isp || c.geo_org)}</td>
                    <td>
                        <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
                            ${renderSecurityBadge(c.security_status, c.security_label)}
                            <span class="state-pill">${escapeHtml(c.state)}</span>
                        </div>
                    </td>
                </tr>
            `).join('');
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
}

function triggerSpeedtest() {
    const stBtn = document.getElementById('runSpeedtestBtn');
    const stVal = document.getElementById('diagSpeedtestVal');
    if (stVal) stVal.textContent = 'Running benchmark...';
    if (stBtn) {
        stBtn.textContent = 'Testing...';
        stBtn.disabled = true;
    }
    postNativeAction({ action: 'run_speedtest' });
    fetch('netpulse://app/api/speedtest').catch(() => {});
    setTimeout(fetchRealtime, 500);
}

function revealDatabase() {
    postNativeAction({ action: 'reveal_db' });
}

// --- Charts ---
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
    const pad = { top: 14, right: 28, bottom: 26, left: 72 };
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
        ctx.lineWidth = 1.75;
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

    drawSeries('speed_in', '#10b981', 'rgba(16, 185, 129, 0.20)');
    drawSeries('speed_out', '#3b82f6', 'rgba(59, 130, 246, 0.18)');

    ctx.fillStyle = isLight ? '#475569' : '#71717a';
    ctx.font = '10px "JetBrains Mono", monospace';
    ctx.textAlign = 'center';
    let lastDrawnX = -999;
    const minLabelGap = 85;
    for (let i = 0; i < points.length; i++) {
        const isLast = (i === points.length - 1);
        const isTick = (i % 20 === 0) || isLast;
        if (!isTick) continue;
        const x = getX(i);
        if (x - lastDrawnX >= minLabelGap) {
            ctx.fillText(points[i].time_str, x, h - 6);
            lastDrawnX = x;
        }
    }
}

function drawHistoryChart(canvasId, timeline) {
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
    const pad = { top: 16, right: 20, bottom: 28, left: 72 };
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
    const barW = Math.max(4, Math.min(34, slotW * 0.56));
    let lastLabelX = -999;
    const minHistGap = n === 24 ? 36 : 54;

    timeline.forEach((item, idx) => {
        const centerX = pad.left + slotW * idx + slotW / 2;
        const x = centerX - barW / 2;

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
            ctx.fillText(shortLabel, centerX, h - 8);
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

function escapeHtml(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}
