# 🌀 Void Linux Post-Install Setup Script

A comprehensive, automated Bash post-installation script for **Void Linux** (glibc, runit). It configures `xbps` repositories (nonfree + multilib), detects your GPU and installs the matching drivers, removes unwanted software-center apps, installs a curated set of system/audio/virtualization packages plus Flatpak apps, wires up PipeWire, enables key **runit** services, and sets up Zsh with Oh My Zsh and Powerlevel10k.

The script auto-detects the system language (Polish/English) from the `LANG`/`LC_ALL` locale and prints all status messages accordingly.

---

## 🚀 Script Features

- **Passwordless Sudo**: Requests the admin password once at the start, validates the syntax with `visudo -cf`, and installs a `NOPASSWD` rule in `/etc/sudoers.d/` so the rest of the script can run unattended. A background keep-alive refreshes the sudo timestamp during the run. The temporary per-user rule (`99-temp-installer`) is removed automatically at the end, while the `%wheel` rule (`99_nopasswd`) stays in place.
- **Repository Setup**: Updates `xbps` itself first, then enables `void-repo-nonfree`, `void-repo-multilib` and `void-repo-multilib-nonfree`, and performs a full system update.
- **GPU Detection & Driver Setup**: Detects NVIDIA/AMD/Intel GPUs (and hybrid setups) via `lspci` and installs the matching drivers, including 32-bit libraries: `nvidia` + `nvidia-libs-32bit`, `mesa-vulkan-radeon` + `mesa-vaapi` + `mesa-vdpau`, or `mesa-vulkan-intel` + `intel-media-driver`. If no supported GPU is found, only the base Mesa stack is installed.
- **Bloatware Removal**: Removes software-center apps that are not needed on a customized setup (`gnome-software`, `cosmic-store`, `discover`) and cleans up orphaned packages and the old package cache (`xbps-remove -Oo`).
- **Package Installation**: Installs a curated set of base system packages — `elogind`, `dbus`, `polkit`, `sudo`, `chrony`, `acpid`, `NetworkManager`, `bluez`, fonts (DejaVu, Liberation, Noto + emoji), dev basics (`git`, `curl`, `wget`, `base-devel`, `xtools`), Zsh with plugins, `fastfetch`, and the virtualization stack (`virt-manager`, `libvirt`, `qemu`, `dnsmasq`, `edk2-ovmf`). Each package is validated against the repositories (`xbps-query -R`) before installing, and failures are collected and reported at the end instead of aborting the whole run.
- **PipeWire Audio**: Installs `pipewire`, `wireplumber`, `alsa-pipewire` and `libspa-bluetooth`, then creates the required symlinks in `/etc/pipewire/pipewire.conf.d/` and `/etc/alsa/conf.d/` so WirePlumber, PipeWire-Pulse and the ALSA default device work out of the box.
- **Flatpak Apps**: Adds the Flathub remote, enables the Polish extra language, and installs a curated list of apps (Firefox, Brave, VLC, Audacity, Mixxx, Kdenlive, HandBrake, Discord, Telegram, qBittorrent, LibreOffice, Krita, GIMP + G'MIC, Flatseal, Gear Lever, Faugus Launcher, Qmmp, SoundConverter, OpenCode...).
- **lsfg-vk Support**: Installs the `lsfgvk` Vulkan layer (for both the 24.08 and 25.08 runtimes) and applies Flatpak overrides for Faugus Launcher (config directory, Steam library access and the `LSFGVK_CONFIG` variable).
- **runit Services**: Enables services by linking them from `/etc/sv/` into `/var/service/`: `dbus`, `elogind`, `NetworkManager`, `bluetoothd`, `chronyd`, `acpid`, `ufw`, `ananicy-cpp`, `libvirtd`, `virtlogd` and `virtlockd`. Missing services are skipped with a warning. The conflicting `dhcpcd` and `wpa_supplicant` services are disabled so they don't clash with NetworkManager.
- **Firewall**: Configures UFW (allows SSH, allows `virbr0` traffic, sets the forward policy to `ACCEPT` for virtual machines) and enables it.
- **System Tuning**: Sets up a weekly `fstrim` job via `snooze` (`/etc/cron.weekly/fstrim`) and disables Bluetooth USB autosuspend (`btusb enable_autosuspend=0`).
- **Virtualization**: Waits for `libvirtd`, defines/starts/autostarts the default `libvirt` NAT network, imports default `virt-manager` preferences via `dconf load`, and adds the current user to the `libvirt`/`kvm` groups.
- **Shell Setup**: If `zsh` is available, sets it as the default shell, installs Oh My Zsh (unattended) and the Powerlevel10k theme, and updates `~/.zshrc` (theme, plugins, locale exports, `fastfetch` on login, syntax-highlighting/autosuggestions sourcing).
- **Dotfiles & Config Copy**: Copies an optional `.update.sh` helper script plus `.local`/`.config` directories from the script folder into the user's home directory.
- **Progress Bar & Logging**: Displays a live progress bar across 4 phases / 9 steps (adapts to the terminal width). On failure, a detailed log is saved to `~/install_error_<timestamp>.log`.
- **Optional Reboot Prompt**: At the end the script asks **"Do you want to restart the system now? [Y/N]"** instead of rebooting silently.

---

## 🔍 Module Details

### 1. Permissions & Preparation
Verifies the script is **not** run as root, grants passwordless `sudo`, adds the user to the `wheel`, `audio`, `video`, `input` and `bluetooth` groups, updates `xbps`, enables the nonfree/multilib repositories and runs a full system update.

### 2. Package Installation
Installs the curated base package set (each package validated first), detects the GPU vendor(s) and installs the matching drivers, then sets up Flathub, installs the Flatpak app list and applies the lsfg-vk overrides.

### 3. Optimization & Services
Removes unwanted software-center apps, configures PipeWire symlinks, disables `dhcpcd`/`wpa_supplicant`, enables the required runit services, configures UFW, schedules weekly TRIM, sets up the default `libvirt` network and imports the `virt-manager` GUI preferences.

### 4. Shell & Finalization
Sets up Zsh + Oh My Zsh + Powerlevel10k, copies optional dotfiles, removes the temporary sudo rule, reports any packages that failed to install, and prompts the user to reboot immediately or exit without rebooting.

---

## 🚀 How to Run

1. Clone the repository to your disk
   ```bash
   git clone https://github.com/syscore88/void-config.git
   ```

2. Navigate to the folder
   ```bash
   cd void-config
   ```

3. Make the script executable
   ```bash
   chmod +x install.sh
   ```

4. Run the script
   > ⚠️ **IMPORTANT:** Run the script as a **regular user** (NOT as root/sudo). The script will ask for the administrator password at the start to configure passwordless privileges.
   ```bash
   ./install.sh
   ```

---

### ☕ Support the Project

If you find this tool helpful and it saved you some time, consider buying me a coffee to support further development!

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/bartekszczecinski)

---

If you find this project useful, leave a star! ⭐

---

## ⚠️ Requirements & Notes

- A base **Void Linux** installation (glibc) with `xbps`, `runit` and an internet connection. Packages are installed from the official repositories and Flathub.
- The user must have `sudo` access (`sudo` is part of the install list, but the account must be able to run `sudo -v` at the start).
- The script targets **glibc** Void. On musl, 32-bit/multilib packages and some Flatpak apps are not available.
- The following optional files, placed alongside `install.sh`, are picked up automatically if present: `.update.sh`, `.local/`, `.config/`.
- The script installs a fairly large number of Flatpak apps and the full KVM/QEMU virtualization stack — review the `install_xbps_pkgs` and `install_flatpak_apps` lists before running if you want a lighter setup.
- Unlike the Arch version, Void uses **runit** instead of systemd, so services are enabled by symlinking into `/var/service/` and there is no bootloader/Plymouth configuration step.
- The permanent `%wheel ALL=(ALL) NOPASSWD: ALL` rule (`/etc/sudoers.d/99_nopasswd`) remains after the script finishes. Remove it manually if you don't want passwordless sudo for the `wheel` group.
- A reboot (or re-login) is required for the new group memberships and the default shell to take effect.
- On failure, check the generated `install_error_<timestamp>.log` file in your home directory for details.
