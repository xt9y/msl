# msl — macOS Subsystem for Linux

Run Arch Linux ARM on macOS using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).

## Install

```bash
brew install xt9y/msl/msl
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

## License

MIT
