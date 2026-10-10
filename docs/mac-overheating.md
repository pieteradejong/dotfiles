# Mac overheating & BTLEServer

Notes from diagnosing this Apple Silicon MacBook running ~100°C on all CPU cores with fans near
max (2026-10-10): what the temperature means, how to find the process responsible, what
`BTLEServer` is and why it spikes, and the shape of a watchdog that would restart it.

**Status: notes and roadmap, not yet automated.** The planned additions to `scripts/mac-maintenance.sh`
and the watchdog agent are tracked in [`TODO.md`](../TODO.md) § Roadmap. The script itself is
documented in [`maintenance.md`](maintenance.md#mac-maintenance-manual).

---

## 1. Is ~100°C dangerous?

**Not immediately.** Apple Silicon is designed to run up to roughly 100–105°C under load. At that
point the chip throttles its own clock speed to protect itself, and in extreme cases macOS shuts
down. You won't damage the chip this way.

What *is* abnormal: **all CPU cores and the GPU pinned at full load at once**, which means
something is pegging the machine.

- **"Memory Bank" sensors** sit on the same package as the CPU on Apple Silicon (unified memory),
  so they read hot because the CPU is hot. They don't indicate a separate RAM problem.
- **Battery temperature** matters most for long-term health. Mid-30s °C is fine.
- **Charging adds heat.** Unplugging helps a little under sustained load.

---

## 2. Finding the culprit

Quick snapshot, sorted by CPU:

```bash
ps -Ao pid,pcpu,pmem,comm -r | head -15
```

> ⚠️ `ps` shows CPU **averaged over each process's lifetime**, so it can hide fresh spikes and
> inflate stale ones.

Accurate live reading (takes two samples and prints only the second):

```bash
top -o cpu -l 2 -n 12 -stats pid,cpu,command | tail -13
```

Or open **Activity Monitor → CPU tab → sort by % CPU**. 100% equals one full core.

### Common causes

| Process / source | What it means |
|---|---|
| Local LLM / Docker / builds / dev servers | Your own workload; legitimately heavy on CPU+GPU |
| Chrome Helper (Renderer) | A tab with video or animation. Check Chrome's Task Manager (⋮ → More tools → Task Manager) |
| `mds_stores` / `mdworker` / `photoanalysisd` | Spotlight/Photos indexing; usually settles on its own |
| `kernel_task` | macOS *deliberately throttling* due to heat. A symptom, not a cause |
| `WindowServer` | Draws everything on screen. High usage means something is forcing constant repaints (busy terminal output, overlay/menu-bar apps, animated tabs). Also heats the GPU |
| `BTLEServer` | Bluetooth LE daemon stuck in a loop (see below) |

### What this session's snapshot showed

- `WindowServer` ~83%: constant redraws, which is why the GPU was hot
- `BTLEServer` ~82%: abnormal, should be near 0%
- `iTerm2` ~40%: probably a tab with fast-scrolling output or a TUI refreshing nonstop
- Unfamiliar app at ~35%: quit it to see if `WindowServer` drops
- Codex helpers ~35% combined, plus several Chrome renderers

**Order to try:** kill `BTLEServer` → quit unfamiliar or overlay apps → close busy terminal tabs
→ watch temperatures for a minute.

If nothing obvious shows up and it stays hot at idle: reboot. If it persists after that, run
**Apple Diagnostics** (hold power at startup, then press ⌘D).

---

## 3. What is `BTLEServer`?

`BTLEServer` is the macOS system daemon that handles **Bluetooth Low Energy** connections. It
lives at `/usr/sbin/BTLEServer` and is part of macOS, so it isn't malware.

**What it handles:**
- BLE devices: AirPods, Apple Watch (including Auto Unlock), Magic Keyboard/Mouse/Trackpad,
  AirTags, fitness trackers, smart-home gadgets
- Continuity: Handoff, Universal Clipboard, AirDrop discovery, Instant Hotspot, iPhone proximity
  detection
- Constant background scanning and advertising to nearby Apple devices

**Why it spikes:** normally it uses almost no CPU. High usage usually means it's stuck in a loop,
often because of:
- A flaky or half-paired device that keeps connecting and disconnecting
- A crowded BLE environment, such as lots of nearby devices or AirTags
- A macOS bug, since it shows up after some updates

**Safe to kill?** Yes. launchd restarts it immediately:

```bash
sudo killall BTLEServer
```

Bluetooth accessories drop briefly and reconnect within seconds.

**If it keeps coming back:** toggle Bluetooth off for a minute to confirm it's the cause, then
unpair devices one at a time to find the culprit.

---

## 4. Automating it in a cleanup script

Only restart the daemon when it's actually misbehaving, so a healthy daemon (and AirPods mid-call)
is left alone:

```bash
# Restart a process only if its current CPU usage exceeds a threshold.
restart_if_hot() {
  local name="$1" threshold="${2:-50}"
  local pid cpu

  pid=$(pgrep -x "$name" | head -1) || return 0   # not running → nothing to do

  # Take two samples and keep the second: that's current usage, not a lifetime average
  cpu=$(top -l 2 -pid "$pid" -stats cpu | tail -1 | cut -d. -f1)

  if (( cpu > threshold )); then
    echo "$(date '+%F %T') $name at ${cpu}% CPU, restarting"
    sudo -n /usr/bin/killall "$name"   # launchd restarts it automatically
  fi
}

restart_if_hot BTLEServer 50
```

### Why it's written this way

- **Threshold check, not a blind kill:** killing Bluetooth unconditionally drops audio and
  accessories for no reason.
- **`top -l 2` instead of `ps`:** `ps` reports CPU averaged over the process's whole life. A daemon
  that has been fine for a week and then spiked would get diluted below the threshold. The two
  samples take about a second.
- **`sudo -n`:** fails immediately instead of hanging on a password prompt when the script runs
  unattended.
- **Absolute path `/usr/bin/killall`:** must exactly match the sudoers rule below.

**Where it would go:** `scripts/mac-maintenance.sh`, where every mutating step runs through the
`act` helper so `--dry-run` prints the kill instead of doing it
([D29](design-decisions.md#d29--mac-maintenancesh-stays-at-the-cleanups-standard-and-under-test--2026-10-10)).
It would be that script's first step that touches a running process, and the first `sudo` in any
maintenance script here, so it gets its own decision entry when built.

---

## 5. Passwordless sudo for just this command

Create a narrow sudoers rule that allows only this one command:

```bash
sudo visudo -f /etc/sudoers.d/btleserver
```

Contents:

```
pieterdejong ALL=(root) NOPASSWD: /usr/bin/killall BTLEServer
```

> ⚠️ Always edit sudoers with `visudo`. It checks the syntax before saving, and a syntax error in
> sudoers can lock you out of `sudo` entirely.

This file lives outside the repo; once added, record it in
[`reinstall-commands.md`](reinstall-commands.md) so a rebuild of the Mac restores it.

---

## 6. Scheduling

If your cleanup script already runs from launchd or cron, you're done.

**Caveat:** a daily check won't catch a spike when it happens. If it recurs, run the check every
15–30 minutes with a launchd agent instead. It would be the sixth `com.pieterdejong.*` agent and
the first on an interval rather than a calendar; the shape below follows
`macos/com.pieterdejong.securityaudit.plist` (program through `$HOME`, its own `PATH`, logs under
`~/Library/Logs`). Nothing is installed yet, so there is no copy under `macos/`.

`~/Library/LaunchAgents/com.pieterdejong.btlewatchdog.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.pieterdejong.btlewatchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>exec "$HOME/dev/dotfiles/scripts/btle-watchdog.sh" &gt;&gt; "$HOME/Library/Logs/btle-watchdog/launchd.out" 2&gt;&amp;1</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartInterval</key>
  <integer>1800</integer>                          <!-- every 30 min -->
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
```

Load it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pieterdejong.btlewatchdog.plist
```

Unload it:

```bash
launchctl bootout gui/$(id -u)/com.pieterdejong.btlewatchdog
```

> If the spikes keep recurring, the script only treats the symptom. Tracking down the misbehaving
> Bluetooth device is the real fix.
