# NTFSMount

**[简体中文](README.md) · [English](#english)**

A native NTFS read/write utility for macOS, written in Swift + SwiftUI.

macOS ships read-only NTFS support. NTFSMount calls **ntfs-3g + macFUSE** to remount an
NTFS volume as read/write, and exposes quick actions in the menu bar and in Finder.

![NTFS devices](docs/images/devices.png)

---

# English

## Why this project exists

I have long used **[Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac)** (formerly
Free-NTFS-for-Mac; the GitHub repository still carries the old name) to read and write NTFS
drives on macOS — it works well, it is free, and its interface is clear. Credit where it is due.

The one problem: the latest release, **v1.5.4, ships Apple Silicon (arm64) builds only** —
Intel Macs are officially told to stay on 1.4.5, and the release notes state that future
versions will no longer support Intel, citing macOS 27 dropping Intel Macs. I had cloned the
older version, so the decision was to build a native Swift rewrite that **keeps Intel and
Apple Silicon on the same release train**.

The rewrite was AI-assisted (vibe coding), but it is not a reskin: device detection, mount
arguments, dependency checks and Finder integration — the parts that fail *silently* — were
all re-evaluated from scratch.

## Features and advantages

### Apple Silicon and Intel ship together

One DMG per architecture, versions kept in lockstep. **Intel users are not left behind on an
old build.**

That matters right now: Homebrew 7.0.0 (2026-09-13) moved macOS Intel to **Tier 3** — no more
binary bottles, with the project recommending Intel users migrate to MacPorts, and its
official `.pkg` installer now Apple Silicon only. Software supply for Intel Macs is narrowing,
so a small utility that still ships both architectures has real value.

### A native app, not an Electron wrapper

| | NTFSMount | Nigate 1.5.4 |
|---|---|---|
| Installer size | **~2 MB** | ~98 MB |
| Runtime | native Swift / SwiftUI | Electron (bundled Chromium + Node) |
| Memory footprint | ~40 MB | — |

No bundled browser engine, no Node runtime.

### Drives show up even with no driver installed

Device detection runs on IOKit and DiskArbitration system APIs and **does not depend on
macFUSE / ntfs-3g**. Before either is installed, the app still lists every partition,
identifies the filesystem type and shows capacity bars — only the "mount read/write" step
needs the driver.

### Zero resident child processes, zero polling timers

Device changes come from IOKit match/terminate notification ports and NSWorkspace mount
events; idle CPU usage is 0.

A full refresh pass takes about **3–5 ms** (`statfs` plus one IOKit sweep, with no process
forks at all).

### Homebrew is not required

`core dependencies = macOS version × macFUSE × ntfs-3g`, with **no Homebrew term**.
MacPorts, Homebrew and manual installs are treated identically — a machine without Homebrew
is never misreported as "missing dependencies". Given the Intel situation above, that matters
most for exactly those users.

### Mount arguments were reviewed item by item, not copied

One is worth calling out: **`-oauto_xattr` is deliberately omitted.** It forces the kernel to
*always* store extended attributes in `._` sidecar files, whereas ntfs-3g supports xattrs
natively — adding it litters every tagged file with a sidecar that Windows cannot even see,
while abandoning NTFS's native extended-attribute channel.

`iosize` defaults to 1 MiB (macFUSE's own default is 64 KiB). The full argument list and the
reasoning behind each entry appear under "Mount arguments" below.

### No privileged helper is installed

Privilege escalation uses the native system authorization dialog, with Touch ID / Apple Watch
support, so credentials never pass through the app process. **No privileged daemon is
installed**, and uninstalling leaves nothing behind.

### Interface and system integration

- Menu bar resident: left-click opens a quick panel, right-click opens a menu; closing the
  main window does not quit
- Finder integration: volume status badges + context menu (mount / unmount, toggle
  read-write, eject, ntfsfix)
- Silent launch: on login, only the menu bar icon appears — no main window
- Auto-mount read/write at launch
- Five UI languages (Simplified Chinese, Traditional Chinese, English, Japanese, German),
  switchable at runtime
- A 16-chapter manual built into the app, readable offline
- Optional keychain storage for the administrator password, so mounting stops prompting

### No network, no telemetry

The app makes no network requests and collects or uploads nothing.

## Features

| | |
|---|---|
| Read/write mount | Uses ntfs-3g + macFUSE to mount NTFS volumes as read/write |
| Device detection | Built on IOKit / DiskArbitration system APIs — **no third-party driver required**. Drives show up even before macFUSE / ntfs-3g are installed |
| Refresh strategy | Event-driven (IOKit match/terminate notifications + NSWorkspace mount events); no polling timers |
| Resident child processes | None |
| Memory footprint | ~40 MB (Activity Monitor's "Memory" column, i.e. `phys_footprint`) |
| Menu bar | Left-click opens a quick panel, right-click opens a menu; closing the main window does not quit |
| Finder integration | Volume status badges + context menu (mount / unmount, toggle read-write, eject, ntfsfix) |
| UI languages | Simplified Chinese, Traditional Chinese, English, Japanese, German — switchable at runtime |
| Architectures | Separate builds for Apple Silicon (arm64) and Intel (x86_64) |
| Minimum OS | macOS 14 |

## Screenshots

| System Dependencies | NTFS Devices |
|---|---|
| ![System Dependencies](docs/images/dependencies.png) | ![NTFS Devices](docs/images/devices.png) |

| Menu bar quick panel (left-click) | Settings |
|---|---|
| ![Menu bar quick panel](docs/images/tray-panel.png) | ![Settings](docs/images/settings.png) |

The built-in manual has 16 chapters and works entirely offline:

![Manual](docs/images/manual.png)

## What it does — and does not do

**Does**: mount existing NTFS volumes read/write; mount, unmount and restore read-only;
clear the "dirty volume" flag with `ntfsfix`.

**Does not**: format, partition or convert filesystems; modify partition tables or boot records;
touch Windows ACLs; recover data; keep third-party processes resident, connect to the network,
or upload anything.

> **Writing to NTFS carries risk regardless of which tool you use.** Back up anything important
> on the volume before the first write. The `ntfsfix` action only clears the dirty-volume flag —
> it does not repair file contents.

## Installation

### 1. Install the app

Download the DMG matching your architecture, mount it, and drag `NTFSMount.app` into
Applications.

- Apple Silicon (M-series): `NTFSMount-1.0.0-arm64.dmg`
- Intel: `NTFSMount-1.0.0-x86_64.dmg`

Release builds are ad-hoc signed. If macOS shows "cannot verify the developer" on first
launch, right-click the app and choose Open.

### 2. Install the dependencies

Read/write support comes from macFUSE + NTFS-3G, which must be installed separately. The
in-app "System Dependencies" page detects them and shows the exact commands.

**MacPorts**

```bash
sudo port install macfuse      # then allow it in System Settings → General → Login Items & Extensions
sudo port install ntfs-3g
```

**Homebrew**

```bash
brew install --cask macfuse
brew tap gromgit/homebrew-fuse
brew install ntfs-3g-mac
```

**Manual**: download from [macFUSE](https://macfuse.github.io/) and
[NTFS-3G](https://tuxera.com/opensource/ntfs-3g_ntfsprogs/), then put `ntfs-3g` anywhere on
your PATH (e.g. `/usr/local/bin`).

The app looks up binaries by path, so **it does not matter which package manager you used**.

## Usage

### Mount as read/write

Click "Read/Write" for a device on the NTFS Devices page, or left-click the menu bar icon and
use the quick panel. Mounting requires administrator privileges and shows the system
authorization dialog.

### Settings

| Setting | Effect |
|---|---|
| Auto read/write | Automatically mount newly attached NTFS devices as read/write |
| Launch at login | Start the app when you log in |
| Silent launch | On login, stay in the menu bar only — no main window |
| Mount at launch | Mount already-connected NTFS devices as read/write on startup |
| Save admin password | Store the administrator password in the macOS keychain so mounting never prompts again |
| I/O block size | `iosize` passed to macFUSE; affects large-file throughput. Default 1 MiB |
| Enable operation log | Record all operations, retained for up to 30 days |

> **Save admin password** trades convenience for security: the password is submitted to the
> system privilege-escalation mechanism on your behalf and stored in the login keychain
> (`kSecAttrAccessibleWhenUnlocked`, unreadable while locked). If the password is later
> changed, the app discards it automatically and falls back to the system dialog. Turn it off
> if you would rather not store it.

## Building

Requires Xcode Command Line Tools and [Bazelisk](https://github.com/bazelbuild/bazelisk).

```bash
# Apple Silicon
bazelisk build //swift:NTFSMount --config=arm64

# Intel x86_64
bazelisk build //swift:NTFSMount --config=intel
```

> **Cross-compilation note**: `--platforms` in `.bazelrc` must use the raw label
> (e.g. `@apple_support//platforms:darwin_x86_64`). A local alias is not dereferenced,
> so rules_apple's platform→architecture mapping silently misses and falls back to the host CPU.

## Packaging

### Release shape: one DMG per architecture

```bash
scripts/package.sh --arch x86_64 --sign --dmg   # → dist/NTFSMount-1.0.0-x86_64.dmg
scripts/package.sh --arch arm64  --sign --dmg   # → dist/NTFSMount-1.0.0-arm64.dmg
```

Each DMG contains `NTFSMount.app` plus an `Applications` symlink: mount it, drag the app in,
and you are done.

> **The two builds must run sequentially.** SwiftPM's `.build/out/Products/Release/` is not
> split per architecture, so the second build overwrites the first. The script copies artifacts
> out immediately after each build, but parallel runs still collide. For the same reason
> `.pkg` / `.dmg` filenames must carry the architecture suffix — otherwise the second packaging
> run **silently overwrites** the first, leaving a single artifact.

### Other shapes

```bash
scripts/package.sh --universal --sign --pkg --dmg   # Universal 2 + .pkg + .dmg
scripts/package.sh --app-only                       # .app only, host architecture
scripts/package.sh --arch x86_64 --sign --pkg       # single-arch .app + .pkg
```

Artifacts land in `dist/`. Run `scripts/package.sh --help` for all options.

### Signing

Release builds use **ad-hoc signing**. On your own machine they run directly; on someone
else's, the first launch shows "cannot verify the developer", which is normal Gatekeeper
behaviour. To make installation fully silent for all users, sign and notarize with an Apple
**Developer ID** certificate:

```bash
scripts/package.sh --universal --sign \
    --identity "Developer ID Application: Your Name (TEAMID)" \
    --pkg --dmg
```

### Sandbox and entitlements

The main app is **not** sandboxed, and must not be — a sandboxed process cannot open
`/dev/rdisk*`, child processes inherit the sandbox (so an elevated `ntfs-3g` still cannot
reach the device node), and `/opt/homebrew` becomes unreadable. Only the Finder extension
(`.appex`) must be sandboxed, otherwise `pkd` refuses to load it. The two share state through
the App Group `group.com.ntfsmount.shared`.

## Architecture

```
swift/Sources/
├── NTFSMountCore/            Pure logic, no UI dependency
│   ├── MountContract.swift     Single source of truth for mount arguments
│   ├── MountEngine.swift       Mount / unmount / read-write switching
│   ├── DeviceService.swift     Device list + event-driven refresh
│   ├── VolumeMonitor.swift     IOKit + NSWorkspace event source
│   ├── DependencyDetector.swift Dependency detection and version checks
│   ├── KeychainStore.swift     Administrator password storage
│   └── Shell.swift             Subprocess execution
├── NTFSMountUI/             SwiftUI interface
├── NTFSMountFinderBridge/   App side: App Group snapshot IPC
├── NTFSMountFinderSync/     Finder extension: badges + context menu
├── NTFSMountSmoke/          Regression tests
└── NTFSMount/               App entry point
```

### Mount arguments

All of them live in `MountContract.swift`, with the reasoning in the source comments:

| Argument | Purpose |
|---|---|
| `-olocal` | Treat the volume as local; affects the Finder sidebar and idle unmounting |
| `-oallow_other` | Let other users access the mount point |
| `-oremove_hiberfile` | Remove the hibernation file to reclaim space |
| `-onoatime` | Do not update access times; fewer writes |
| `-oiosize=` | macFUSE I/O block size. Default 1 MiB (4 MiB, or macFUSE's own 64 KiB default) |

`-oauto_xattr` is **deliberately omitted**: the macFUSE documentation states that it makes the
kernel *always* use `._` sidecar files for xattrs, while NTFS-3G supports xattrs natively — so
adding it would be a pessimisation.

`big_writes` is treated as an experimental flag and off by default — macFUSE's `max_write`
defaults to roughly 32 KiB while write requests are already below 128 KiB, so the benefit is
unmeasured.

## Finder integration

Once installed, Finder shows volume status badges and a context menu: mount / unmount, toggle
read-write, open NTFSMount.

It is implemented as a FIFinderSync extension plus a shared App Group directory: the main app
writes volume state as a JSON snapshot, the extension reads it to render badges, and user
actions are posted back to the main app through a command queue (the extension itself has no
privilege escalation).

Polling (5 s) is the primary consistency channel; Darwin notifications are only an accelerator,
because they can occasionally be dropped.

## License

[GNU General Public License v3.0](LICENSE) (GPL-3.0).

## Acknowledgements

Read/write support rests on two open-source projects:

- **[macFUSE](https://macfuse.github.io/)** — userspace filesystem framework providing the kernel channel used to mount NTFS
- **[NTFS-3G](https://github.com/tuxera/ntfs-3g)** (Tuxera) — the NTFS read/write driver itself

The UI and interaction design was inspired by
[Nigate](https://github.com/hoochanlon/Free-NTFS-for-Mac).
With thanks to its author.
