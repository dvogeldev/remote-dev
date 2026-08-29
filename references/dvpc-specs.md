System:
  Host: dvpc Kernel: 7.1.9-arch1-2 arch: x86_64 bits: 64 compiler: gcc
    v: 16.2.1 clocksource: hpet
  Desktop: Hyprland v: 0.56.2 vt: 1 dm: SDDM Distro: Omarchy
Machine:
  Type: Desktop System: Micro-Star product: MS-7B84 v: 1.0
    serial: <superuser required>
  Mobo: Micro-Star model: A320M PRO-M2 (MS-7B84) v: 1.0
    serial: <superuser required> uuid: <superuser required> Firmware: UEFI
    vendor: American Megatrends v: 1.7V date: 07/02/2020
Battery:
  Device-1: hidpp_battery_0 model: Logitech MX Vertical Advanced Ergonomic
    Mouse serial: c6-68-26-03 charge: 100% (should be ignored)
    rechargeable: yes status: full
CPU:
  Info: quad core model: AMD Ryzen 3 2200G with Radeon Vega Graphics bits: 64
    type: MCP smt: <unsupported> arch: Zen rev: 0 cache: L1: 384 KiB L2: 2 MiB
    L3: 4 MiB
  Speed (MHz): avg: 1874 min/max: 1600/3700 boost: enabled cores: 1: 1874
    2: 1874 3: 1874 4: 1874 bogomips: 28001
  Flags-basic: avx avx2 ht lm nx pae sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3
Graphics:
  Device-1: NVIDIA TU117 [GeForce GTX 1650] vendor: Micro-Star MSI
    driver: nvidia v: 610.57.04 arch: Turing pcie: speed: 5 GT/s lanes: 8 ports:
    active: DP-1,DP-2 empty: HDMI-A-1 bus-ID: 10:00.0 chip-ID: 10de:1f82
    class-ID: 0300
  Device-2: C922 Pro Stream Webcam driver: snd-usb-audio,uvcvideo type: USB
    rev: 2.0 speed: 480 Mb/s lanes: 1 bus-ID: 3-4.2:6 chip-ID: 046d:085c
    class-ID: 0102 serial: 4C4F3B5F
  Display: wayland server: X.org v: 1.21.1.24 with: Xwayland v: 24.1.13
    compositor: Hyprland v: 0.56.2 driver: X: loaded: nvidia
    unloaded: modesetting alternate: fbdev,nouveau,nv,vesa
    gpu: nv_platform,nvidia,nvidia-nvswitch display-ID: 1
  Monitor-1: DP-1 model: Dell S2817Q serial: MTKT171Q614M res: 3840x2160
    dpi: 157 size: 621x341mm (24.45x13.43") diag: 708mm (27.9") modes:
    max: 3840x2160 min: 640x480
  Monitor-2: DP-2 model: Dell S2817Q serial: MTKT178L221I res: 3840x2160
    dpi: 157 size: 621x341mm (24.45x13.43") diag: 708mm (27.9") modes:
    max: 3840x2160 min: 640x480
  API: EGL Message: EGL data requires eglinfo. Check --recommends.
  Info: Tools: gpu: nvidia-smi x11: xprop
Audio:
  Device-1: NVIDIA vendor: Micro-Star MSI driver: snd_hda_intel v: kernel
    pcie: speed: 5 GT/s lanes: 8 bus-ID: 10:00.1 chip-ID: 10de:10fa
    class-ID: 0403
  Device-2: Advanced Micro Devices [AMD] Ryzen HD Audio
    vendor: Micro-Star MSI driver: snd_hda_intel v: kernel pcie: speed: 8 GT/s
    lanes: 16 bus-ID: 2a:00.6 chip-ID: 1022:15e3 class-ID: 0403
  Device-3: C922 Pro Stream Webcam driver: snd-usb-audio,uvcvideo type: USB
    rev: 2.0 speed: 480 Mb/s lanes: 1 bus-ID: 3-4.2:6 chip-ID: 046d:085c
    class-ID: 0102 serial: 4C4F3B5F
  API: ALSA v: k7.1.9-arch1-2 status: kernel-api
  Server-1: sndiod v: N/A status: off
  Server-2: PipeWire v: 1.6.8 status: active with: 1: pipewire-pulse
    status: active 2: wireplumber status: active 3: pipewire-alsa type: plugin
    4: pw-jack type: plugin
Network:
  Device-1: Realtek RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet
    vendor: Micro-Star MSI driver: r8169 v: kernel pcie: speed: 2.5 GT/s
    lanes: 1 port: e000 bus-ID: 25:00.0 chip-ID: 10ec:8168 class-ID: 0200
  IF: enp37s0 state: up speed: 1000 Mbps duplex: full mac: 00:d8:61:14:4d:c1
  IF-ID-1: tailscale0 state: unknown speed: -1 duplex: full mac: N/A
Bluetooth:
  Device-1: Broadcom Corp BCM20702A0 driver: btusb v: 0.8 type: USB rev: 2.0
    speed: 12 Mb/s lanes: 1 bus-ID: 5-1.4.2:4 chip-ID: 0a5c:21e8 class-ID: fe01
    serial: 00198600164F
  Report: btmgmt ID: hci0 rfk-id: 0 state: up address: 00:19:86:00:16:4F
    bt-v: 4.0 lmp-v: 6 class-ID: 6c0104
Drives:
  Local Storage: total: 5.91 TiB used: 1.35 TiB (22.8%)
  ID-1: /dev/nvme0n1 vendor: Samsung model: SSD 970 EVO Plus 500GB
    size: 465.76 GiB speed: 31.6 Gb/s lanes: 4 tech: SSD serial: S4P2NG0M205691H
    fw-rev: 1B2QEXM7 temp: 37.9 C scheme: GPT
  ID-2: /dev/sda vendor: Seagate model: ST2000DM001-1ER164 size: 1.82 TiB
    speed: 6.0 Gb/s tech: HDD rpm: 7200 serial: W4Z08FGQ fw-rev: CC25
  ID-3: /dev/sdb vendor: Seagate model: ST2000DM001-1CH164 size: 1.82 TiB
    speed: 6.0 Gb/s tech: HDD rpm: 7200 serial: Z240TGRP fw-rev: CC27
    scheme: GPT
  ID-4: /dev/sdc vendor: Seagate model: ST2000DM001-9YN164 size: 1.82 TiB
    speed: 6.0 Gb/s tech: HDD rpm: 7200 serial: Z1E0P66B fw-rev: CC4H
Partition:
  ID-1: / size: 463.74 GiB used: 260.79 GiB (56.2%) fs: btrfs dev: /dev/dm-0
    mapped: root
  ID-2: /boot size: 2 GiB used: 734.6 MiB (35.9%) fs: vfat
    dev: /dev/nvme0n1p1
  ID-3: /home size: 463.74 GiB used: 260.79 GiB (56.2%) fs: btrfs
    dev: /dev/dm-0 mapped: root
  ID-4: /var/log size: 463.74 GiB used: 260.79 GiB (56.2%) fs: btrfs
    dev: /dev/dm-0 mapped: root
Swap:
  ID-1: swap-1 type: file size: 15.56 GiB used: 0 KiB (0.0%) priority: 0
    file: /swap/swapfile
  ID-2: swap-2 type: zram size: 15.56 GiB used: 0 KiB (0.0%) priority: 100
    dev: /dev/zram0
Sensors:
  System Temperatures: cpu: 36.0 C mobo: N/A
  Fan Speeds (rpm): N/A
Info:
  Memory: total: 16 GiB available: 15.56 GiB used: 5.51 GiB (35.4%)
  Processes: 361 Power: uptime: 49m states: freeze,mem,disk suspend: deep
    wakeups: 0 hibernate: platform Init: systemd v: 261 default: graphical
  Packages: 1459 pm: pacman pkgs: 1448 pm: flatpak pkgs: 11 Compilers:
    clang: 22.1.8 gcc: 16.2.1 alt: 15 Shell: fish v: 4.8.1 default: Bash
    v: 5.3.15 running-in: herdr inxi: 3.3.41
