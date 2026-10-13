# NTFSMount User Manual

## 1. What This Tool Does and Does Not Do

macOS can **read** NTFS out of the box, but it cannot write. NTFSMount fills in the writing half: it calls `ntfs-3g`, a mature open-source NTFS driver, and pairs it with the user-space filesystem framework provided by `macFUSE` to remount an NTFS volume as read-write, so it can hold files in Finder just like an ordinary disk.

Just as important is what it does **not** do. It does none of the following:

- It does not format, partition, or convert filesystem formats;
- It does not modify the partition table or touch the boot record;
- It does not touch Windows access control lists (ACLs) or encryption schemes;
- It does not perform data recovery. The `ntfsfix` behind the "Reset" feature only clears the "dirty partition" flag; it does not repair file contents;
- It does not keep any third-party process resident in the background, does not go online, and uploads no information.

> [!WARN]
> Any operation that writes to NTFS carries risk, and that is true regardless of which tool you use. Before you write to a given disk for the first time, back up the important files on it separately. This tool is provided "as is" and accepts no responsibility for data loss.

> [!IMPORTANT]
> Data integrity depends in large part on the hardware itself. A USB flash drive with low-quality flash memory will slow down, throw errors, or even drop off under sustained writes, yet it looks like a software problem. For heavy read-write work, use a portable hard drive or an SSD-based USB drive with guaranteed throughput.

## 2. System Requirements and Dependencies

| Item | Requirement |
| --- | --- |
| Operating system | macOS 14.0 or later |
| Processor | Installers are available for both Apple Silicon and Intel |
| Required dependencies | macFUSE, ntfs-3g |
| Disk usage | About 30 MB (the app itself is around 4 MB) |

The dependencies are not two parallel items but a chain:

```
NTFSMount        ->  ntfs-3g        ->  macFUSE        ->  macOS kernel
  (UI)                 (driver)           (framework)        (system)
```

`ntfs-3g` understands the NTFS on-disk structures, but it cannot talk to the macOS kernel by itself — it needs an intermediate "user-space filesystem" layer to hand the kernel's file requests to it, and that layer is `macFUSE`. If any link in the chain is missing, the mount cannot succeed.

> [!NOTE]
> This is a fully native implementation: the interface, device detection and the mounting pipeline all use system frameworks — no third-party runtime and no resident helper process. Device attach and detach events come from the native IOKit and DiskArbitration notifications, with no polling; idle CPU usage is close to 0.

## 3. Preparing the System Dependencies

### 3.1 First, Let the App Tell You What Is Missing

Open the app, go to the "System Dependencies" page, and click "Check Dependencies" in the upper-right corner. This page lists the actual status of four items:

1. Whether the macOS version meets the minimum requirement;
2. Whether Xcode Command Line Tools is installed (it may be needed when you install ntfs-3g);
3. Whether macFUSE is in place;
4. Whether ntfs-3g is in place.

Each entry can be expanded, and expanding it shows what to install for that item and which command to use. Each command has a copy button beside it. Missing items are marked red, installed items green.

> [!TIP]
> After installing the dependencies you do not need to restart the app, nor to click "Check Dependencies" again. This page rechecks automatically every three seconds (a pure filesystem check that starts no processes), so once you finish `brew install` or `port install` in the terminal, switching back to the window shows the status turn green on its own.

### 3.2 MacPorts (Preferred on Intel Macs)

```bash
sudo port install macfuse
```

```bash
sudo port install ntfs-3g
```

MacPorts installs everything under `/opt/local`. This app includes `/opt/local/bin` in its search path, so anything you install is recognized right away; you do not need to set up `PATH`, nor to tell the app where to look.

### 3.3 Homebrew (Preferred on Apple Silicon)

```bash
brew install --cask macfuse
```

```bash
brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac
```

The `ntfs-3g-mac` tap provides a build tuned for Apple Silicon.

### 3.4 Installing Manually from the Release Pages

You can also skip the package managers and download the installers from the project release pages:

- macFUSE: https://macfuse.github.io
- ntfs-3g: https://github.com/tuxera/ntfs-3g

When you install manually, the usual pitfall is a path problem: install to a non-standard location and the app cannot find it. If that happens, confirm that the executable lands in one of `/usr/local/bin`, `/opt/local/bin`, or `/opt/homebrew/bin`.

### 3.5 Install Order and Verification

Install `macFUSE` first, then `ntfs-3g`. In the reverse order, the latter fails to install because it cannot find the framework.

After installing, verify once in the terminal:

```bash
ntfs-3g --version
```

If it prints a version number, the path is fine — the app looks for exactly this executable.

> [!IMPORTANT]
> After you install macFUSE, macOS blocks its system extension and shows a prompt. You must go to "System Settings → Privacy & Security", find the entry from macFUSE in the section below, and click "Allow", then restart the computer when prompted. Skip this step and the mount fails with what looks like a permission problem — it has nothing to do with NTFS itself.

### 3.6 About Versions

The app checks the `ntfs-3g` version once: if it is below the recommended version, the Dependencies page suggests an upgrade; for versions with a known regression (one that prevents creating new files and directories), it shows an explicit warning. It will not upgrade anything for you; it only tells you that an upgrade is due.

## 4. Your First Read-Write Mount

1. Plug in an NTFS-formatted removable disk. macOS first mounts it **read-only**, so you can see the volume in Finder but cannot save anything to it.
2. Open NTFSMount, switch to the "NTFS Devices" page, and click "Refresh" or wait for it to refresh automatically.
3. Find the target device in the list and check whether the "Device Mount Point" column shows a read-only state.
4. Click the "Read/Write" button on the right side of that row.
5. The system shows an authorization dialog; enter your Mac login password (if "Save Administrator Password" is enabled, this step does not appear).
6. Once the mount succeeds, the row's status becomes "Read/Write", and the volume in Finder accepts writes normally.

You can now write files to the volume. When you are done and want the system's default read-only state back, click "Restore to Read-Only" on this row; to disconnect the disk completely, click "Eject".

> [!NOTE]
> The window in step 5 is macOS's own authorization dialog, not an interface drawn by this app. It supports Touch ID and Apple Watch, the password is verified directly by the system's `securityd`, and this app never receives what you type. This is the default path, and the safer one.

## 5. A Tour of the Main Window

The main window uses the standard macOS split layout: navigation on the left, content on the right, and a status bar along the bottom.

### 5.1 The Four Sidebar Pages

- **System Dependencies** — check macFUSE and ntfs-3g and read the installation guidance.
- **NTFS Devices** — the device list and every operation live here.
- **Operation Log** — the time and cause of each mount, unmount, and failure. Off by default; enable it in Settings.
- **Guide Manual** — the page you are reading. The table of contents on the left is searchable, and code blocks can be copied in one click.

Settings are **not** in the sidebar. Following macOS convention, they sit under "Settings…" (⌘,) in the app menu; adding another entry to the sidebar would only create two entry points to the same place.

### 5.2 The Bottom Status Bar

The status bar sums up the current situation with a colored dot and a short sentence:

| Color | Meaning |
| --- | --- |
| Gray | Checking dependencies |
| Green | Ready. Followed by how many devices are read-write and how many are read-only |
| Orange | Something is wrong but not fatal |
| Red | A dependency is missing and mounting is unavailable |

### 5.3 The Device Page Toolbar

From left to right: **Refresh**, **All Read/Write**, **All Read-Only**, **Unmount All**, **Eject All**. The search field is also in the toolbar and filters by volume name or device name.

The bulk buttons act on the **currently selected rows**; when no row is selected, they act on all devices.

## 6. The Device Page: Reading the Status

### 6.1 The Three States

| Display | Meaning | Writable |
| --- | --- | --- |
| Read/Write | Already taken over by ntfs-3g and mounted read-write | Yes |
| Read-Only | A read-only mount by the built-in NTFS driver | No |
| Unmounted | You have unmounted it, but the device is still plugged in | No |

The "Unmounted" state is kept on purpose: you unmount before unplugging a device, and afterward it should not vanish from the list — otherwise you would think the device had dropped off. To make it disappear completely, use "Eject".

### 6.2 The Capacity Bar

Beneath each device name is a capacity bar showing "available / total" and the used percentage. The capacity is still shown when the device is unmounted — it comes from reading the filesystem header information, which requires no mount.

The capacity bar uses three color tiers:

- Blue (default) — under 75% used;
- Orange — 75% to 90% used, time to pay attention;
- Red — over 90% used, time to clean up.

It uses three tiers rather than a continuous gradient because this progress bar is only a few millimeters wide on screen, and a gradient simply cannot be made out at that size.

### 6.3 Mount Point

The "Device Mount Point" column shows a path such as `/Volumes/volume-name`. When the device is unmounted it shows "Not mounted". After a read-write mount, this is the path you can reach in Finder.

## 7. The Device Page: What Each of the Six Actions Does

All six actions sit on the right side of each row. The difference between them is not only "mount" and "unmount"; choose the wrong one and you may at best waste effort, and at worst interrupt a transfer in progress.

| Action | What it actually does | When to use it |
| --- | --- | --- |
| Read/Write | Unmount the current read-only mount, then mount read-write with ntfs-3g | You need to write to the disk |
| Re-mount Read/Write | Unmount, then remount read-write once | Something goes wrong in read-write mode and you want a clean retry |
| Restore to Read-Only | Unmount, hand the volume back to the built-in driver, and mount read-only | You are done writing and want the most conservative state back |
| Unmount | Unmount, but leave the device in the list | Before unplugging the disk |
| Eject | Disconnect the device from the system entirely | You are done with it and about to unplug |
| Reset | Unmount → `ntfsfix` clears the dirty flag → remount read-only | When you see "Resource busy" or otherwise cannot use the disk |

### 7.1 Read/Write

Before mounting, the app checks that macFUSE and ntfs-3g are in place. If either is missing, it tells you directly what is missing and where to install it; it does not throw up an incomprehensible error, nor leave you guessing at a motionless icon.

### 7.2 Restore to Read-Only

This action unmounts the current mount and lets the built-in driver remount the volume read-only. **It does not lose data**, provided that no program is writing to the disk at that moment. If a copy or download is in progress, wait for it to finish first.

### 7.3 Unmount vs. Eject

Unmount only detaches the filesystem; the device stays connected and can be mounted again at any time. Eject genuinely disconnects the device from the system, and doing it before unplugging is the safest move. After ejecting, the device disappears from the list and only comes back once you plug it in again.

### 7.4 Reset

Some failures cannot be fixed by a plain remount, such as the dirty flag left by a previous abnormal exit, or a program holding the disk open. Reset does three things: force an unmount, call `ntfsfix` to clear the NTFS dirty flag, and mount the volume back read-only. Once the flag is cleared, read and write usually work normally again.

> [!NOTE]
> `ntfsfix` clears the "partition not clean" flag; it neither checks nor repairs file contents. If your disk started misbehaving after an improper Windows shutdown, clearing the flag usually restores it; but if the filesystem structure itself is damaged, what you need is the disk check built into Windows, not this button.

### 7.5 Bulk Operations

The toolbar's bulk buttons act on the currently selected rows, or on all devices when nothing is selected. A bulk mount issues operations for each device in turn — if you have not saved the administrator password, you will see a run of authorization dialogs, which is expected.

## 8. Mount Options

The mount options are decided by the app as a whole, and you do not need to specify a single one by hand. They are listed here so you can make sense of things when a problem arises:

| Option | Effect |
| --- | --- |
| `-olocal` | Treats the volume as a local volume rather than a network volume. This determines whether it appears under "Locations" or "Network" in Finder |
| `-oallow_other` | Lets processes other than the mounter access the volume. Without it, only root can read it, which amounts to unusable in a desktop environment |
| `-oremove_hiberfile` | Deletes the hibernation file when the volume is held by Windows hibernation, in exchange for a writable mount |
| `-onoatime` | Does not update a file's "last access time". Writing an index record on every read is pure write amplification |
| `-ovolname` | Makes the volume show its correct name in Finder |

> [!IMPORTANT]
> The meaning of `-oremove_hiberfile` needs to be spelled out: Windows Fast Startup writes the system state from before shutdown into the hibernation file, leaving the NTFS volume in an "in use" state. With this option, the app deletes that hibernation file to gain write access — **at the cost of losing any unsaved session state on the Windows side**. If you still have unsaved work in Windows, boot back into Windows and shut down normally first.

## 9. I/O Block Size

This is the only performance-oriented setting, located under "Settings → Mount Options".

macFUSE exposes a "virtual storage device" for each volume you access, and `iosize` sets the block size the kernel uses when issuing I/O requests to the filesystem. macFUSE's own default is 64 KiB, and its official documentation is blunt about it: on a fast link (a local disk, for example), larger blocks significantly reduce access overhead. A local USB or Thunderbolt drive clearly counts as a fast link.

| Setting | Suitable for |
| --- | --- |
| macFUSE default (64 KiB) | Mechanical drives; workloads dominated by vast numbers of small files with almost no large sequential I/O |
| 1 MiB (recommended) | The default setting. General use with SSDs and portable drives |
| 4 MiB | Workloads dominated by very large files: video footage, disk images, full-disk backups |

A changed setting takes effect on the **next mount**; devices that are already mounted need one read-write remount.

> [!NOTE]
> This option has a format constraint: it must be a power of two, with a maximum of 32 MiB. All three settings the app offers fall within the safe range, so you do not need to remember these limits — but mind them if you mount by hand elsewhere.

## 10. Permissions and the Administrator Password

A read-write mount requires administrator privileges. The app offers two ways to obtain them.

### 10.1 The Default: The System Authorization Dialog

Each time privileges are needed, macOS's own dialog appears; the password is verified by the system and this app never comes into contact with it. Touch ID and Apple Watch are supported. This is the default method and the more secure one.

### 10.2 The Optional Route: Saving the Administrator Password

Turn on "Save Administrator Password" under "Settings → System Integration", enter the password once, and click "Verify and Save". From then on, mounts no longer prompt.

The password is stored in the macOS keychain, as a generic password item owned by this app's bundle identifier. It never appears in any log or any file of the app's own.

> [!WARN]
> Understand this trade-off honestly: saving the password is **less secure** than typing it in by hand each time. The difference is that the password is submitted by this app on your behalf, rather than requested directly from you by the system. If this Mac is shared with others, or you are unsure where the software on the machine comes from, do not turn it on.

### 10.3 The Switch Has Three States, Do Not Confuse Them

| Switch | Password in keychain | Actual behavior |
| --- | --- | --- |
| Off | Irrelevant | The system authorization dialog appears every time |
| On | No | **Still prompts.** The switch only expresses intent; there is no usable password yet |
| On | Yes | No prompt; privileges are obtained with the saved password |

The second state gets its own orange notice line, precisely so you are not left staring at a switch that is on and wondering "why does it still prompt".

### 10.4 What Happens When the Password Goes Stale

If you later change your Mac login password, the copy stored in the keychain goes stale. The app then: deletes the stale password, explains the situation in the log and on the Settings page, and falls back to the system authorization dialog so that your current operation can still complete. You will never hit a "repeated failure that never gets better" situation.

### 10.5 How to Remove It Completely

Simply turn off the "Save Administrator Password" switch — turning it off includes deleting the keychain item. You can also search for this app's bundle identifier in the "Keychain Access" app and delete it by hand.

## 11. Startup Behavior: How the Four Switches Work Together

All four switches have to do with "launch" and "automatic", and they are easy to mix up. Each governs exactly one thing:

| Setting | What it governs |
| --- | --- |
| Launch at Login | Whether the app **starts** at login |
| Silent Launch | Whether the **main window opens** when it starts at login. When enabled, it resides only in the menu bar |
| Auto Mount Read/Write at Login | At the moment of startup, mounts the NTFS devices **already attached** as read-write |
| Auto Read/Write | While the app is running, automatically mounts devices **plugged in afterward** as read-write |

A few typical combinations:

- You just want one disk directly writable at login: turn on "Launch at Login" + "Auto Mount Read/Write at Login".
- You want it standing by in the background at login without a window popping up: add "Silent Launch".
- You do not want an automatic mount at login, but want any disk you plug in later to be writable automatically: turn on "Auto Read/Write" only.
- You do not even want the authorization dialog: also turn on "Save Administrator Password", and login mounts then complete unattended.

> [!TIP]
> With "Silent Launch" on, the app leaves only an icon in the menu bar and does not appear in the Dock. Left-click it to manage devices; the right-click menu has "Main Window"; closing the window from the main interface does not quit the app, which returns to the menu bar and keeps standing by.

## 12. The Menu Bar Icon and Quick Panel

Closing the main window does not quit the app — this is the basic behavior of a menu bar app. Once the window is closed, the app keeps working from the menu bar icon.

### 12.1 Left-Clicking the Icon

A quick panel pops up listing all NTFS devices directly. Each device shows:

- A status icon and the volume name;
- The volume's mount state;
- A **capacity bar**: "available / total" and the used percentage;
- Action buttons on the right.

You can mount, unmount, restore, and eject without opening the main window. The status shown in the panel is the same data as the main window, so there is no problem of the two being out of sync.

The icon itself changes too: when any device is in read-write mode it switches to a different icon, so you can tell at a glance that "there is a writable disk right now".

### 12.2 What the Panel Says When an Action Fails

The reason for the failure appears directly beneath that row, in red, with a warning icon, written as a **complete sentence** and not truncated. This is a necessary design decision rather than a nicety — the quick panel has no log page, so if failure information went only to the log, clicking "Read/Write" in this small panel would look like "nothing happened when I clicked": no dialog, no message, no change to the icon.

The most common one is a missing dependency: in that case it states plainly whether it is macFUSE or ntfs-3g that is missing, and that you should install it on the "System Dependencies" page.

### 12.3 Right-Clicking the Icon

The menu contains: Main Window, Refresh Device List, All Read/Write, Unmount All, Settings, Quit.

## 13. Finder Integration

The app includes a Finder extension. It adds two things to volumes under `/Volumes`.

### 13.1 Volume Badge

Looking at a volume's icon in Finder, you will see a small badge in the lower-right corner showing its current state: **Read/Write**, **Read-Only**, **Not Mounted**. You can tell whether the disk is writable right now without going back to the app.

### 13.2 Context Menu and Toolbar

The app's button appears on the Finder toolbar, and clicking it reads "Open NTFSMount". Right-clicking a volume under `/Volumes` brings up an extra group of menu items:

- Mount as Read/Write
- Unmount
- Restore to Read-Only
- Eject
- Reset Volume (ntfsfix)
- Show in NTFSMount

You can complete these actions right in Finder, without switching back to the main window.

> [!NOTE]
> The Finder extension is loaded on demand by the system, so on first use it may take a moment to appear in the menu. If it never shows up, go to "System Settings → General → Login Items & Extensions → Finder Extensions" and confirm it is turned on.

## 14. Operation Log

The "Operation Log" page records the time, content, and result of every operation. It is off by default; open "Enable Operation Log" under "Settings → General" to start recording.

The panel lets you clear the log or export it as a text file. The log is written only to the local Application Support directory and is never uploaded anywhere.

When you report a problem, please attach the exported log — the failure reasons inside are usually the key to diagnosing the issue, and the symptom description alone often leaves it impossible to guess.

## 15. Troubleshooting by Symptom

| What you see | Actual cause | What to do |
| --- | --- | --- |
| My disk is not in the list | The partition is not NTFS, or the device has not been recognized by the system yet | First confirm the disk really is NTFS format; unplug and plug it back in; click "Refresh" |
| A message says macFUSE / ntfs-3g is missing | The dependency is not installed | Install it following the guidance on the "System Dependencies" page |
| A message says Windows is hibernated | Windows Fast Startup is on and the volume is held by the hibernation file | Boot into Windows, run `shutdown /s /t 0` for a full shutdown, then plug the disk back in |
| A message says Resource busy | A program is using the disk | Quit the program that is holding it; or use the "Reset" button |
| A message says permission denied | The macFUSE system extension has not been approved | Allow macFUSE in "System Settings → Privacy & Security", then restart |
| A message says the password is wrong | The saved password has gone stale | Enter and save it once more in Settings |
| Cannot write after mounting | It is actually still a read-only mount | Check whether the row's status is "Read/Write"; if not, click "Read/Write" once more |
| The disk drops off mid-transfer | A hardware or power problem | Try another cable or port; avoid USB hubs without their own power supply |
| The Finder extension does not appear | The extension is not enabled | Confirm it is on in "System Settings → General → Login Items & Extensions" |

## 16. Uninstalling and Cleaning Up Completely

1. First "Restore to Read-Only" or "Eject" all NTFS devices; do not leave them in a read-write state.
2. Quit the app. Right-click the menu bar icon → Quit, or press ⌘Q.
3. Turn off "Launch at Login" under "Settings → System Integration" — otherwise it comes back after a restart.
4. Drag the app from the "Applications" folder to the Trash.
5. If you ever enabled "Save Administrator Password", search for this app's bundle identifier in "Keychain Access" and delete the corresponding item.
6. If you no longer need to mount NTFS, you can uninstall the two dependencies as well. For Homebrew that is `brew uninstall ntfs-3g-mac` and `brew uninstall --cask macfuse`; for MacPorts it is `sudo port uninstall ntfs-3g macfuse`.

The app's configuration files live in `~/Library/Application Support/NTFSMount/`; delete that directory to clear all settings.
