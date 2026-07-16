# MSL — MacOS Subsystem for Linux

Run Arch Linux ARM on macOS using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).


## Install

```bash
brew tap xt9y/MSL
brew install msl
```


## Setup

Download the Arch Linux ARM image (~1GB) and configure VM resources:

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
msl start        # boot the VM
msl shell        # interactive shell
msl exec "cmd"   # run a command
msl stop         # stop the VM
msl status       # check if running
msl help         # show help
```


## GUI applications

`msl setup` installs [XQuartz](https://www.xquartz.org) automatically for GUI forwarding:

```bash
msl exec "pacman -S --noconfirm xorg-xeyes"
msl exec xeyes
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

**Not working right now**
- GPU-accelerated apps (OpenGL/Vulkan) fail or silently fall back to software
  rendering — the guest has no GPU device (`/dev/dri` doesn't exist). Only
  plain X11 core-protocol drawing (like `xeyes`) works today.
- Apps relying on `MIT-SHM` or `DRI3`/`Present` (shared-memory frame handoff)
  don't get the fast path — Xlib disables SHM over a non-local display, so
  these fall back to slow `PutImage`, if they fall back at all.

**Will never be implemented**
- GPU acceleration (Vulkan/OpenGL) of any kind. True GPU passthrough isn't
  possible on Apple Silicon (the host needs the GPU for its own display),
  and full virtio-gpu 3D acceleration (Venus/virglrenderer → MoltenVK)
  requires a custom device with shared-memory command streaming that
  `Virtualization.framework` doesn't expose — projects that have this
  (e.g. Podman/`krunkit`) had to abandon `Virtualization.framework` entirely
  for raw `Hypervisor.framework`.
- Reliable indirect GLX hardware acceleration through XQuartz — indirect GLX
  support has been scaled back in modern X servers for security reasons, so
  this isn't achievable regardless of what msl does guest-side.
- Screen mirroring / RDP-style remote desktop of the whole guest — msl aims
  for native per-window integration via X11, not a virtual monitor.

**Might be added, no promises**
- Forcing software GL (Mesa `llvmpipe`) in the guest so simple 3D apps
  (`glxgears`, basic GL UI toolkits) render via CPU and composite through the
  existing X11 bridge like any other window. Slow, but real, and doesn't
  require touching the VM architecture.
- ARM64-native package mirror selection / faster first-boot.
- Multiple simultaneous VMs / named instances.
- Snapshotting or pausing VM state instead of full shutdown/boot.
- Port forwarding helpers for guest network services.


## License

MIT

