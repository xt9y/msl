# MSL — MacOS Subsystem for Linux

Run Arch Linux ARM on macOS using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).


## Install

One-liner:

```bash
curl -L https://xt9y.de/msl | sh
```

Or manually via Homebrew:

```bash
brew tap xt9y/MSL
brew install msl msld
```

Or manually via install.sh inside the repo (can just be extracted, has do dependencies inside the repo)
```bash
curl -L https://raw.githubusercontent.com/xt9y/msl/main/install.sh | sh
```

## Requirements

- **macOS 14+** (Sonoma) with Apple Silicon (M1/M2/M3/M4)
- [Zig](https://ziglang.org/download/) (`brew install zig`) for building from source

## Setup

Download the Arch Linux ARM image (~1GB), kernel, and modules, then configure
VM resources:

```bash
msl setup
# with custom resources:
msl setup --disk-size 16 --ram-size 4 --cpu-cores 4
```

| Flag | Default | Description |
|---|---|---|
| `--disk-size` | 8 | Disk image size in GB |
| `--ram-size` | 2 | RAM size in GB |
| `--cpu-cores` | 2 | Number of vCPUs |

Configuration is stored in `~/.msl/config.json`.

## Usage

```bash
msl help         # show usage
msl start        # boot the VM (daemon runs in background)
msl stop         # graceful ACPI shutdown
msl status       # check if the VM is running
msl shell        # interactive shell (like SSH)
msl exec "cmd"   # run a command and print output
msl update       # download latest kernel/modules/Arch image
msl setup --force # re-create disk image from scratch
```

## GUI applications

`msl setup` installs [XQuartz](https://www.xquartz.org) automatically for GUI forwarding:

```bash
msl exec "pacman -S --noconfirm xorg-xeyes"
msl exec xeyes
```

### Vulkan (software)

Mesa's `llvmpipe` provides Vulkan over CPU — works out of the box:

```bash
msl exec vulkaninfo --summary
msl exec vkcube
```

Performance is ~1–5 FPS for complex scenes (fine for UI toolkits, not for games).

### EGL-based GL

Apps compiled with an EGL backend (bypassing GLX) render via Mesa's software rasterizer:

```bash
# GLFW apps with EGL support
msl exec "GLFW_BACKEND=egl ./myapp"
```

## Build from source

```bash
make
```

Requires: Xcode 15+, Xcode Command Line Tools, and `zig` (for cross-compiling the guest daemon).

## Uninstall

```bash
msl uninstall            # removes ~/.msl (disk images, kernel, config)
brew uninstall msl msld  # removes the binaries
brew untap xt9y/MSL      # removes the tap
```

## Known Limitations

### Works

- **Plain X11 apps** (`xeyes`, terminal emulators, basic GUI toolkits). 
- **Vulkan (software)** using Mesa `llvmpipe`.
- **EGL-native GL** apps compiled with an EGL backend bypass GLX and render via Mesa's software rasterizer.
- **`msl shell`** — interactive PTY shell with job control, resize handling, DISPLAY forwarding.
- **`msl exec`** — run commands, capture stdout/stderr + exit code.

### Not working

- **GLX (OpenGL over X11)** — XQuartz does not implement the GLX server extension, so any app
  using legacy GLX (`glxgears`, unmodified GLUT, etc.) will fail with `GLXBadContext`.
  *Fix:* recompile the app with an EGL backend.
- **Hardware GPU acceleration** — Apple Silicon has no GPU passthrough mechanism.
  `/dev/dri` doesn't exist in the guest. All rendering is CPU-based.

### Will never be implemented

- True GPU passthrough / virtio-gpu 3D (Venus/virglrenderer → MoltenVK) — requires
  custom device support that `Virtualization.framework` doesn't expose.
- Indirect GLX hardware acceleration through XQuartz, GLX indirect support has been
  scaled back in modern X servers for security reasons.
- Screen mirroring / RDP-style remote desktop of the whole guest — msl targets native
  per-window integration via X11.

### Might be added, no promises

- ARM64-native package mirror selection / faster first-boot.
- Multiple simultaneous VMs / named instances.
- Snapshotting or pausing VM state instead of full shutdown/boot.
- Port forwarding helpers for guest network services.

## License

MIT

