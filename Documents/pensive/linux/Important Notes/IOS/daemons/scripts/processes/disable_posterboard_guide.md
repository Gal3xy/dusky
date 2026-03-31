# Disabling Resource-Heavy Processes on iOS 16 (Rootless Jailbreak)

## Overview

This guide covers disabling RAM-heavy iOS daemons and processes on jailbroken devices (tested on Dopamine/iOS 16.7, iPhone 8 Plus with 2GB RAM).

---

## Dependencies

Before using these scripts, install on your device:

1. **Python 3.14+** - via Cydia/Sileo package manager
2. **gawk** - via Cydia/Sileo (iOS doesn't include awk by default)

---

## Tools

### processkiller
Continuously kills processes that restart automatically. **Install auto-start to persist after reboot!**

```bash
/var/jb/basebin/processkiller start    # Start
/var/jb/basebin/processkiller stop     # Stop
/var/jb/basebin/processkiller status   # Check
/var/jb/basebin/processkiller list     # List monitored processes
/var/jb/basebin/processkiller install  # Auto-start on boot (IMPORTANT!)
/var/jb/basebin/processkiller uninstall # Remove auto-start
```

### daemonmanager (v7)
Disables/enables launchd daemons. **No respring needed!**

```bash
/var/jb/basebin/daemonmanager list                   # Show disabled
/var/jb/basebin/daemonmanager disable <name>          # Quick disable
/var/jb/basebin/daemonmanager enable <name>           # Quick enable
/var/jb/basebin/daemonmanager apply <name> yes        # Disable
/var/jb/basebin/daemonmanager apply <name> no         # Enable
/var/jb/basebin/daemonmanager reset                   # Enable ALL disabled by this script
```

**Examples:**
```bash
/var/jb/basebin/daemonmanager disable tipsd
/var/jb/basebin/daemonmanager enable gamed
/var/jb/basebin/daemonmanager disable AssistiveTouch
/var/jb/basebin/daemonmanager reset    # Restore everything
```

**Special:** `AssistiveTouch` (case-insensitive) also controls the on-screen UI button and plist.

---

## How It Works

### Regular Daemons (tipsd, gamed, etc.)
- **Disable:** `launchctl disable` + `launchctl bootout`
- **Enable:** `launchctl enable` + `launchctl bootstrap` + `launchctl kickstart`
- No respring needed!

### AssistiveTouch
- **Disable:** Daemon bootout + modify Accessibility.plist
- **Enable:** Daemon enable + modify plist
- No respring needed!

### State Tracking
- daemonmanager v7 tracks its own changes in a TSV file
- `reset` only enables what THIS script disabled (scoped undo)
- Other tools' changes are preserved

---

## Common Daemons to Disable

| Daemon | Purpose | RAM Saved |
|--------|---------|-----------|
| com.apple.assistivetouchd | AssistiveTouch | ~10-20MB |
| com.apple.tipsd | Tips app | ~10-20MB |
| com.apple.gamed | Game Center | ~15-30MB |
| com.apple.UsageTrackingAgent | Usage tracking | ~10MB |
| com.apple.bookassetd | Apple Books | ~15-30MB |
| com.apple.itunesstored | App Store | ~20-30MB |

---

## SSH Connection

```bash
IP: 192.168.29.75
User: root
Password: alpine
```

---

## File Locations

| File | Path |
|------|------|
| processkiller | `/var/jb/basebin/processkiller` |
| daemonmanager | `/var/jb/basebin/daemonmanager` |
| State file | `/var/mobile/Library/Preferences/com.daemonmanager.state.tsv` |
| Accessibility plist | `/var/mobile/Library/Preferences/com.apple.Accessibility.plist` |

---

## Tested On

- iPhone 8 Plus (iOS 16.7)
- Dopamine (rootless) jailbreak
- Python 3.14.3
- gawk installed

---

*Last updated: 2026-03-31*
