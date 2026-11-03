# NetPulse — Native macOS Network Telemetry & Bandwidth Analyzer

Samostatná natívna macOS aplikácia (`Universal Binary: Apple Silicon arm64 + Intel x86_64`) na meranie sieťovej prevádzky v reálnom čase, sledovanie spotreby jednotlivých aplikácií a ukladanie dlhodobej histórie do lokálnej SQLite databázy.

---

## Hlavné funkcie

- **Meranie v reálnom čase (Real-Time Stream + macOS Menu Bar)**:
  - Živý 120-sekundový graf so sekundovým vzorkovaním pre **Download (Ingress)** a **Upload (Egress)**.
  - Kompaktný indikátor priamo v hornej lište macOS (`↓ ... ↑ ...`) s rýchlym prehľadom dňa, týždňa, mesiaca, odozvy a top 3 procesov.
- **Dlhodobá história a analytické filtre (SQLite)**:
  - Automatické ukladanie prenesených dát po hodinách (`00:00 – 23:00`), dňoch a mesiacoch do `~/Library/Application Support/NetPulse/netpulse_data.db`.
  - Predvoľby (*Dnes*, *Včera*, *Tento týždeň*, *7 dní*, *Tento mesiac*, *30 dní*, *Tento rok*) aj **vlastný filter dátumov (`Od` – `Do`)**.
- **Spotreba podľa aplikácií a procesov + Detailný inšpektor**:
  - Presný prehľad, koľko MB/GB preniesla každá aplikácia v reálnom čase aj vo zvolenom historickom období.
  - Rozklikávací **Inšpektor aplikácie** s hodinovým grafom procesu, zoznamom jeho otvorených spojení a možnosťou ukončiť proces (`SIGTERM`).
- **Sieťová diagnostika, Ping a Speedtest**:
  - Zobrazenie aktívneho profilu/Wi-Fi, lokálnej IP, brány (Router), verejnej IP adresy, poskytovateľa (ISP), živej odozvy (`Ping` na router a internet `1.1.1.1`) a vstavaný **Speedtest**.
  - Automatická identifikácia krajiny a organizácie cieľových serverov pri aktívnych TCP/UDP spojeniach.
- **Nízka spotreba batérie (Eco-Mode) & Svetlý / Tmavý režim**:
  - Čítanie počítadiel adaptérov priamo z jadra macOS cez C volanie `getifaddrs()` (< 0,05 ms) a automatické zníženie frekvencie dotazovania pri zatvorenom okne (`Cmd + W`).
  - Plná podpora **Tmavého** aj **Svetlého** režimu a dynamické prispôsobenie veľkosti akémukoľvek monitoru.

---

## Rýchla inštalácia na Mac

1. Stiahnite si **`NetPulse-Mac-Installer.zip`** (alebo naklonujte tento repozitár).
2. Spustite **`Instalovat_NetPulse.command`** (prípadne presuňte **`NetPulse.app`** priamo do `/Applications`).

---

## Kompilácia zo zdrojového kódu (Swift + SQLite3 + WebKit)

```bash
swiftc CoreStorage.swift TelemetryEngine.swift main.swift \
  -framework Cocoa -framework WebKit -lsqlite3 \
  -o NetPulse.app/Contents/MacOS/NetPulse
```
