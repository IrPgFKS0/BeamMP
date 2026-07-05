## Recommendation

Use **CachyOS KDE Desktop Edition**, installed on a **second physical SSD** when possible.

CachyOS is the best fit for this experiment because it directly packages `scx_lavd`, `scx_loader`, and `scxctl`, and lets you switch between LAVD and the kernel’s normal scheduler without rebooting. Its `game-performance` wrapper also switches an active sched-ext scheduler into its gaming profile while the game runs. LAVD’s gaming profile uses its `--performance` behavior. ([CachyOS][1])

This is preferable to installing Valve’s SteamOS recovery image on a general desktop because your goal is controlled scheduler testing rather than reproducing the full Steam Deck environment.

## Recommended disk layout

Use approximately:

```text
Windows SSD:
    Existing Windows installation — unchanged

Linux SSD:
    4 GiB   FAT32   /boot   boot flag
    Rest    Btrfs   /
```

I recommend at least a **250 GB Linux SSD or partition**. BeamNG alone requires about 60 GB, and mods, shader caches, Steam files, logs, and alternative Proton prefixes can consume considerably more. ([Steam Store][2])

A second drive gives each OS its own EFI partition. CachyOS specifically notes that Windows updates can interfere with a shared EFI setup and recommends separate drives as mitigation. ([CachyOS][3])

---

# Step-by-step installation

These instructions assume Windows 10 or 11 is already installed in UEFI/GPT mode.

## 1. Back up Windows

Before touching partitions:

1. Back up important files.
2. Create or verify a Windows recovery drive.
3. Save your BitLocker recovery key somewhere outside the PC.
4. Open **Terminal or PowerShell as Administrator** and inspect your disks:

```powershell
Get-Disk |
    Format-Table Number, FriendlyName, SerialNumber, PartitionStyle,
        OperationalStatus, Size
```

Record which physical disk contains Windows and which is the intended Linux disk.

Do not identify disks solely as “Disk 0” or “Disk 1”; firmware and Linux may enumerate them differently. Use their **model and capacity**.

## 2. Prepare Windows for dual boot

Open **PowerShell as Administrator**:

```powershell
powercfg /H off
manage-bde -status C:
```

`powercfg /H off` disables Windows hibernation and Fast Startup. This prevents Windows from leaving NTFS volumes in a hibernated state when Linux boots.

CachyOS’s official dual-boot instructions require Fast Startup, hibernation, BitLocker, and Secure Boot to be disabled during installation. ([CachyOS][3])

If BitLocker or Windows Device Encryption is enabled, turn it off:

```powershell
manage-bde -off C:
```

Monitor decryption:

```powershell
manage-bde -status C:
```

Continue only after it reports that encryption is fully disabled. You can re-enable it after both systems boot reliably.

### When using the same physical SSD

Open Windows Disk Management:

```text
Win+R → diskmgmt.msc
```

Right-click the Windows `C:` partition, select **Shrink Volume**, and shrink it by approximately:

```text
204800 MiB = 200 GiB
256000 MiB = 250 GiB
```

Leave the resulting space **unallocated**. Do not create or format a Windows volume in it.

## 3. Disable Secure Boot

Enter the motherboard or laptop UEFI setup and:

* Disable **Secure Boot**.
* Disable **CSM/Legacy Boot**, if enabled.
* Keep the system in **UEFI mode**.
* Do not change AHCI, RAID, Intel RST, or VMD settings as part of this procedure.

Changing the storage-controller mode can make the existing Windows installation unbootable without additional preparation.

## 4. Create the installer USB

Download the current **CachyOS Desktop Edition ISO** and use an 8 GB or larger USB drive.

With Rufus on Windows:

1. Select the correct USB device.
2. Select the CachyOS ISO.
3. Click **Start**.
4. Accept the image-writing defaults.

These are the current CachyOS USB preparation steps. ([CachyOS][4])

## 5. Boot the USB in UEFI mode

Use your motherboard’s one-time boot menu and select the entry beginning with `UEFI:`.

In the CachyOS live environment, open a terminal:

```bash
efibootmgr -v
```

If this reports that EFI variables are unsupported, you booted the USB in Legacy/CSM mode. Reboot and select the UEFI USB entry. CachyOS recommends manual partitioning and requires a proper UEFI boot for this layout. ([CachyOS][3])

Identify all drives carefully:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
```

An example might look like:

```text
nvme0n1  1.8T  Samsung SSD 990 PRO   # Windows
nvme1n1  931G  WD_BLACK SN850X       # Linux target
sda       29G  USB Flash Drive        # Installer
```

## 6. Launch the CachyOS installer

Choose:

```text
Desktop environment: KDE Plasma
Boot manager:         Limine
Filesystem:           Btrfs
Partitioning:         Manual partitioning
```

CachyOS explicitly states that manual partitioning is more reliable than its “Install alongside” and “Replace partition” options. ([CachyOS][3])

### Path A: second SSD — strongly recommended

Select only the intended Linux SSD.

If the drive is blank:

1. Create a new GPT partition table on the **Linux SSD only**.
2. Create:

```text
Partition 1
    Size:        4096 MiB
    Filesystem:  FAT32
    Mount point: /boot
    Flag:        boot

Partition 2
    Size:        Remaining space
    Filesystem:  Btrfs
    Mount point: /
```

3. Set **Install bootloader on** to the entire Linux disk, for example:

```text
/dev/nvme1n1
```

Do not select an individual partition such as `/dev/nvme1n1p1`.

CachyOS specifies a minimum 4096 MiB FAT32 `/boot` partition for Limine. ([CachyOS][3])

For maximum protection on a desktop, you can power down and temporarily disconnect the Windows SSD before installing. Reconnect it after CachyOS boots successfully.

### Path B: same SSD

In the unallocated space created from Windows:

1. Create a 4096 MiB FAT32 partition mounted at `/boot`, with the boot flag.
2. Create a Btrfs partition using the remainder, mounted at `/`.
3. Do **not** format or modify the existing:

   * Windows EFI partition
   * Microsoft Reserved partition
   * Windows NTFS partition
   * Windows recovery partition
4. Set the bootloader target to the entire physical disk.

Review the installer’s final summary carefully. The only partitions marked for formatting should be the newly created Linux partitions.

## 7. Complete the installation

Create your user account and finish installation. Reboot and remove the USB drive.

Your UEFI firmware may initially boot directly into Windows or CachyOS. Set the Linux SSD or `CachyOS/Limine` entry first in the firmware boot order.

If Windows does not appear in Limine after both disks are connected, boot CachyOS and run:

```bash
sudo limine-scan
```

CachyOS documents `limine-scan` as the first recovery step for Windows detection. ([CachyOS][3])

You can always use the motherboard’s one-time UEFI boot menu to select the Windows SSD independently.

---

# Configure CachyOS for BeamNG

## 8. Update the system

CachyOS is rolling-release, so perform complete upgrades rather than partial package upgrades:

```bash
sudo pacman -Syu
sudo reboot
```

## 9. Install the gaming and scheduler packages

```bash
sudo pacman -S --needed \
    cachyos-gaming-meta \
    cachyos-gaming-applications \
    scx-scheds \
    scx-tools \
    vulkan-tools
```

The gaming applications package includes Steam, MangoHud, GOverlay, Gamescope, and other launchers and tools. ([CachyOS][5])

Validate graphics and Vulkan:

```bash
vulkaninfo --summary
```

Inspect the active graphics driver:

```bash
lspci -k |
    grep -EA3 'VGA compatible controller|3D controller|Display controller'
```

For NVIDIA:

```bash
nvidia-smi
```

Do not benchmark until `vulkaninfo` detects the intended discrete GPU without loader or driver errors.

## 10. Confirm that LAVD is available

Enable the scheduler loader:

```bash
sudo systemctl enable --now scx_loader.service
```

List available schedulers:

```bash
sudo scxctl list
```

You should see `lavd` or `scx_lavd`.

Start LAVD in gaming mode:

```bash
sudo scxctl start --sched lavd --mode gaming
```

Check the current scheduler:

```bash
sudo scxctl get
```

If another sched-ext scheduler is already running, switch instead:

```bash
sudo scxctl switch --sched lavd --mode gaming
```

CachyOS documents `scxctl start`, `switch`, `stop`, `restore`, `get`, and `list`; its LAVD gaming mode maps to performance-oriented operation. ([CachyOS][1])

To return to the kernel’s built-in scheduler:

```bash
sudo scxctl stop
```

Stopping a sched-ext scheduler automatically returns control to the kernel’s normal scheduler. ([CachyOS][1])

---

# Install and configure BeamNG

## 11. Install BeamNG on the Linux filesystem

Open Steam and install BeamNG into the default Linux Steam library on Btrfs.

Avoid using a shared Windows NTFS Steam library for this experiment. In particular, CachyOS warns that running Proton games from NTFS is unsupported by Valve and can cause unpredictable behavior. ([CachyOS][5])

## 12. Use BeamNG’s native Linux build first

In Steam:

```text
BeamNG.drive
  → Properties
  → Compatibility
  → Uncheck “Force the use of a specific Steam Play compatibility tool”
```

BeamNG changed Linux systems to the native Linux binary by default in January 2026. BeamNG states that the native build may perform better than the Proton version. ([BeamNG Documentation][6])

Under **Launch Options**, enter:

```text
game-performance mangohud %command%
```

`game-performance` temporarily selects the system performance power profile and puts an active sched-ext scheduler into gaming mode. It restores the previous profile when the game exits. ([CachyOS][5])

If MangoHud prevents the game from launching, simplify it to:

```text
game-performance %command%
```

### Proton fallback

Only use Proton after testing the native build. BeamNG currently specifies:

```text
Proton 10.0-4
or
Proton Experimental
```

Other Proton versions may not work correctly with its current Steamworks SDK. ([BeamNG Documentation][6])

---

# Correctly test whether LAVD helps

Do not initially compare only Linux against Windows. That changes the OS, graphics stack, filesystem, game build, and scheduler simultaneously.

First perform a controlled comparison **inside CachyOS**.

## Built-in scheduler test

```bash
sudo scxctl stop
```

Run BeamNG with:

```text
game-performance mangohud %command%
```

## LAVD test

```bash
sudo scxctl start --sched lavd --mode gaming
```

Run the identical test again.

Keep constant:

* Resolution and graphics settings
* Native Linux versus Proton selection
* Map and spawn location
* Vehicle
* Traffic and AI vehicle count
* Camera
* Weather and time
* Power profile
* Background applications

Do one warm-up run to populate shader caches, followed by at least three measured runs per scheduler. Compare:

```text
Average FPS
1% low FPS
0.1% low FPS
99th-percentile frame time
Maximum frame-time spikes
CPU and GPU utilization
```

The CachyOS benchmarking guide likewise recommends consistent settings, repeatable actions, multiple runs, and frame-time monitoring with MangoHud or GOverlay. ([CachyOS][1])

The most meaningful likely result is not a large average-FPS increase. Look for:

* Fewer large frame-time spikes
* Improved 1% or 0.1% lows
* Better responsiveness with multiple traffic vehicles
* Better behavior while background tasks are active

After determining the better Linux scheduler, compare that result against Windows.

---

# Make LAVD persistent after testing

Do this only after completing the built-in-versus-LAVD comparison:

```bash
sudo mkdir -p /etc/scx_loader
sudo cp -n \
    /usr/share/scx_loader/config.toml \
    /etc/scx_loader/config.toml

sudoedit /etc/scx_loader/config.toml
```

Set:

```toml
default_sched = "scx_lavd"
default_mode = "Gaming"
```

Then:

```bash
sudo systemctl enable --now scx_loader.service
sudo systemctl restart scx_loader.service
sudo scxctl get
```

CachyOS uses `/etc/scx_loader/config.toml` as the preferred configuration and supports `Gaming` as a default mode. ([CachyOS][1])

To disable persistent LAVD:

```bash
sudo scxctl stop
sudo systemctl disable --now scx_loader.service
```

**Expected outcome:** CachyOS with LAVD may improve BeamNG’s frame-time consistency, particularly with traffic or competing CPU workloads. It is unlikely to produce a dramatic increase in average FPS when BeamNG is limited by a saturated main simulation thread.

[1]: https://wiki.cachyos.org/configuration/sched-ext/ "sched-ext Tutorial | CachyOS"
[2]: https://store.steampowered.com/app/284160/BeamNGdrive/?utm_source=chatgpt.com "BeamNG.drive on Steam"
[3]: https://wiki.cachyos.org/installation/installation_on_root/ "CachyOS Installation Desktop/Laptop | CachyOS"
[4]: https://wiki.cachyos.org/installation/installation_prepare/ "Preparation steps | CachyOS"
[5]: https://wiki.cachyos.org/configuration/gaming/ "Gaming with CachyOS Guide | CachyOS"
[6]: https://documentation.beamng.com/support/troubleshooting/steamdeck_linux/ "Steam Deck and Linux Issues"

Good question — almost none of those go on your Windows machine. They run **on the CachyOS box itself (LAN2)**, and they split into three places depending on the type:

## 1. In BeamNG itself (no terminal — and the biggest FPS win)
The graphics + traffic + car-count changes are all in **BeamNG's in-game Options → Graphics** menu, right there on the CachyOS machine. Start here: Dynamic Reflections **off**, shadows low, fewer cars/traffic. No commands needed.

## 2. Steam / launcher (no terminal)
- **GameMode:** right-click BeamNG in Steam → **Properties → Launch Options**, add:
  ```
  gamemoderun %command%
  ```
  That auto-sets the performance CPU governor + GPU perf mode while the game runs — so you can **skip the manual `cpupower` governor command entirely.**

## 3. A terminal on the CachyOS machine (for the rest)
Open the terminal app on CachyOS — on the default KDE Plasma desktop that's **Konsole** (press the **Super/Windows key**, type "Konsole" or "Terminal", Enter). Then:
- Check the active scheduler (no password needed):
  ```bash
  cat /sys/kernel/sched_ext/root/ops
  ```
- Commands with `sudo` (e.g. `sudo cpupower …`) will ask for your password — it's typed **invisibly** (no characters show), then Enter.

## The two GUI-is-easier ones
- **Switching schedulers (LAVD / bpfland / default):** easiest via the **CachyOS Settings app** (it has a scheduler picker via `scx_loader`) rather than hand-launching `scx_lavd`. Look in your app menu for "CachyOS" settings/hello.
- **`mitigations=off`:** that's *not* a command you run — it's a **kernel boot parameter**, set in the **CachyOS Kernel Manager** GUI (or by editing the bootloader and rebooting). It's the most advanced/optional one; skip it unless you want the extra few %.

**So the easy, high-impact path with zero terminal:** lower the in-game graphics, add `gamemoderun %command%` in Steam, and pick the scheduler in the CachyOS settings app. The terminal is only needed to *check* the scheduler or for the optional governor/mitigations tweaks — and GameMode already covers the governor.

If you tell me which desktop you picked during CachyOS install (KDE, GNOME, etc.) I'll point you to the exact terminal app and settings location.