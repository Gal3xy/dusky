# 🚀 The Ultimate btop Mastery Guide

> [!abstract] Overview
> `btop` is a highly optimized C++ system resource monitor. It provides total visibility into system execution without the heavy overhead of GUI monitors. This guide breaks down the interface, the keyboard shortcuts, and the mental models required to use it for high-level system diagnostics in an Arch Linux/Hyprland environment.

---

## 🏗️ The Four Domains (Layout & Toggles)

`btop` is divided into four distinct boxes. You can toggle them individually or cycle through predefined "Presets" to change your dashboard on the fly.

- **`1` (CPU):** Core utilization, temperatures, frequency, and system load averages. *(Press `5`, `6`, `7` to display your GPUs here as well).*
- **`2` (MEM):** Physical RAM, Swap space, and Disk I/O.
- **`3` (NET):** Global network traffic (Upload/Download bandwidth).
- **`4` (PROC):** The process list. Your diagnostic hunting ground.
- **`p` / `Shift + p`:** Cycle forward/backward through your Presets (e.g., from a 4-box layout to a CPU/PROC-only layout).

> [!tip] Clean the View
> If your Disks are taking up too much room in the Memory box, press **`d`** to toggle them off and expand your RAM graphs.

---

## 🕵️‍♂️ Process Box Mastery (PROC)

This is where you will spend 90% of your time diagnosing issues. The top right of the Process box contains several sorting and viewing modes.

### 1. The Tree View (`e`)
> [!info] Analogy: The Corporate Hierarchy
> In **Normal Mode**, processes are sorted purely by metric (who is using the most CPU/RAM). It’s like looking at a crowded room of employees sorted by who is talking the loudest. It's chaotic, and you don't know who works for who. 
> 
> Pressing **`e` (Tree View)** organizes them by hierarchy. You see the CEO (`systemd`), the Managers (a master `python3` script), and their Subordinates (worker threads). If a specific thread is consuming 100% CPU, Tree view lets you instantly trace it back to the parent script that spawned it.

### 2. CPU Lazy vs. Direct (`c`)
CPU usage updates in milliseconds, which makes a standard process list jump around violently, making it impossible to highlight the rogue application you want to kill.
- **CPU Direct:** Raw, instantaneous data. The list is highly volatile.
- **CPU Lazy (Press `c`):** Runs a smoothing algorithm over the CPU usage over a short time window. It keeps the list stable so you can actually read it and target the right process.

### 3. Sorting & Filtering
- **Left / Right Arrows (`<` / `>`):** Shifts the active sorting column. Move the highlight from `Cpu%` to `MemB` (to find RAM hogs) or `Threads` (to debug multi-threading scripts).
- **Reverse (`r`):** Flips the active sort from Highest-to-Lowest to Lowest-to-Highest.
- **Filter (`f`):** The sniper rifle. Press `f`, type `waybar` or `bash`, and hit `Enter`. The list will instantly isolate only those processes. Delete the text and press `Enter` to clear it.

### 4. Interrogation & Execution
Once you have highlighted a suspect process using the Up/Down arrows (or vim keys `j`/`k`):
- **Deep Dive (`Enter`):** Opens a massive, dedicated sub-dashboard for *only* that process. It reveals its exact Disk Read/Write speeds, specific network connections, and a dedicated memory graph.
- **Terminate (`t`):** Sends a graceful `SIGTERM`. It politely asks the application to save its data, clean up its memory, and shut down.
- **Kill (`k` / `Shift+K`):** Sends a ruthless `SIGKILL`. The Linux kernel instantly destroys the process without letting it clean up. Use this for completely frozen Wayland/Hyprland zombies.

---

## ⌨️ The Definitive Keybind Cheat Sheet

> [!note] Vim Keys Support
> If enabled in `btop.conf` (`vim_keys = true`), you can use `h, j, k, l` for directional control and navigation.

### Global Interface & Navigation
| Key | Action |
| :--- | :--- |
| **`m`** | Open Main Menu |
| **`o`** / **`F2`** | Open Options / Config Menu |
| **`h`** / **`F1`** | Open Help Menu |
| **`q`** / **`Esc`** | Quit `btop` |
| **`+`** / **`-`** | Increase / Decrease update speed (Update Interval) |
| **`p`** / **`Shift+p`** | Cycle Layout Presets forward / backward |
| **`1`, `2`, `3`, `4`** | Toggle CPU, MEM, NET, and PROC boxes on/off |
| **`5`, `6`, `7`...** | Toggle GPU 1, GPU 2, GPU 3 monitoring |
| **`0`** | Toggle ALL GPU boxes simultaneously |

### Box-Specific Controls
| Key | Target Box | Action |
| :--- | :--- | :--- |
| **`b`** | *CPU/Global* | Toggle Battery meter on/off |
| **`d`** | *Memory* | Toggle Disks view on/off inside the Memory box |
| **`y`** | *Network* | Sync network graphs (forces Upload/Download to share the exact same Y-axis scale for accurate visual comparison) |
| **`z`** | *Network* | Zero out the network traffic counters (useful when starting a script to see exactly how much data it transfers) |

### Process Box (PROC) Controls
| Key | Action |
| :--- | :--- |
| **`Up` / `Down`** | Navigate the process list |
| **`<` / `>`** | Change sorting column (e.g., switch from CPU to Memory) |
| **`f`** | Filter the process list by string |
| **`e`** | Toggle Tree View (Parent/Child hierarchy) |
| **`r`** | Reverse sorting order |
| **`c`** | Toggle CPU Lazy / Direct sorting mode |
| **`Enter`** | Open detailed dashboard for selected process |
| **`t`** | Terminate selected process (SIGTERM) |
| **`k`** | Kill selected process (SIGKILL) |

---

## ⚙️ Core Configuration (`btop.conf`)
As a Systems Architect, you should manage your defaults via the configuration file rather than the UI.
**Path:** `~/.config/btop/btop.conf`

**Critical DevOps Tweaks:**
1. `proc_per_core = false` -> Set to `true` if you want multi-threaded processes on your i7-12700H to display up to 1400% CPU usage (100% per core) instead of normalizing to 100% total system limit.
2. `vim_keys = true` -> Keeps your hands on the home row.
3. `update_ms = 2000` -> The default is 2000ms. Dropping this to `500` gives real-time tracing but consumes slightly more CPU to render.