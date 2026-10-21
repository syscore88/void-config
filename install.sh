#!/bin/bash
# =====================================
#  SKRYPT INSTALACYJNY - Void Linux
# =====================================

set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

detect_system_lang() {
    local sys_lang="${LANG:-}"
    [[ -z "$sys_lang" ]] && sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    if [[ "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[0;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/install-log.XXXXXX)"
LOG_FILE="$HOME/install_error_$(date +%Y%m%d_%H%M%S).log"

FAILED_PACKAGES=()

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${ERR}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
            fi
        fi
    fi
    rm -f "$TMP_LOG"
    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        sudo sh -c 'rm -f "$1"; if [ "$2" = 1 ]; then reboot; fi' _ \
            "/etc/sudoers.d/99-temp-installer" \
            "$do_reboot"
    fi
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() { printf "\r\033[K" >&3; echo -e "$1" >&3; echo -e "$1"; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}✔ $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}✘ ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}⚠ WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(tput cols 2>/dev/null || true)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    local bar_width=50
    local reserved=12
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 1))}…"
    fi

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ $filled -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ $empty -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
}

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    MSG_PHASE_1="[1/4] Przygotowywanie..."
    MSG_PHASE_2="[2/4] Instalacja..."
    MSG_PHASE_3="[3/4] Optymalizacja..."
    MSG_PHASE_4="[4/4] Finalizowanie..."
else
    MSG_PHASE_1="[1/4] Preparing..."
    MSG_PHASE_2="[2/4] Installing..."
    MSG_PHASE_3="[3/4] Optimizing..."
    MSG_PHASE_4="[4/4] Finalizing..."
fi

TOTAL_STEPS=9

if [[ "$EUID" -eq 0 ]]; then
    echo -e "${ERR}✘ Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo.${NC}" >&3
    exit 1
fi

CURRENT_USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf '\033[?7h\n' >&3

SUDO_READY=0
sudo -v

(
    set +e
    trap - ERR
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done
) &
SUDO_KEEPALIVE_PID=$!

SUDOERS_TMP="$(mktemp)"
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
    sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    sudo visudo -cf "$SUDOERS_TMP" &>/dev/null && sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99_nopasswd || true
else
    rm -f "$SUDOERS_TMP"
    echo -e "${ERR}✘ Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3
    exit 1
fi
rm -f "$SUDOERS_TMP"
SUDO_READY=1

printf '\033[?7l' >&3

pkg_installed() {
    xbps-query "$1" &>/dev/null
}

install_xbps_pkgs() {
    local valid_pkgs=()
    local pkg
    for pkg in "$@"; do
        pkg_installed "$pkg" && continue
        if xbps-query -R "$pkg" &>/dev/null; then
            valid_pkgs+=("$pkg")
        else
            FAILED_PACKAGES+=("$pkg")
        fi
    done
    for pkg in "${valid_pkgs[@]}"; do
        sudo xbps-install -y "$pkg" || FAILED_PACKAGES+=("$pkg")
    done
}

install_flatpak_apps() {
    local app
    for app in "$@"; do
        sudo flatpak install -y --noninteractive flathub "$app" || FAILED_PACKAGES+=("$app")
    done
}

enable_service() {
    if [ -d "/etc/sv/$1" ]; then
        sudo ln -sf "/etc/sv/$1" /var/service/
    else
        log_warn "Pominięto usługę $1 (brak /etc/sv/$1)" "Skipped service $1 (/etc/sv/$1 not found)"
    fi
}

# =============================================================
#  ETAP 1/4: PRZYGOTOWYWANIE
# =============================================================
show_progress 0 $TOTAL_STEPS "$MSG_PHASE_1"

sudo usermod -aG wheel,audio,video,input,bluetooth "$CURRENT_USER" 2>/dev/null || sudo usermod -aG wheel,audio,video,input "$CURRENT_USER"

show_progress 1 $TOTAL_STEPS "$MSG_PHASE_1"

sudo xbps-install -Syu xbps
sudo xbps-install -Sy void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
sudo xbps-install -Syu

# =============================================================
#  ETAP 2/4: INSTALACJA
# =============================================================
show_progress 2 $TOTAL_STEPS "$MSG_PHASE_2"

install_xbps_pkgs \
    pciutils mesa-dri vulkan-loader libgcc-32bit mesa-dri-32bit vulkan-loader-32bit \
    elogind dbus polkit sudo chrony acpid NetworkManager \
    bluez pipewire wireplumber alsa-utils alsa-pipewire libspa-bluetooth pavucontrol \
    dejavu-fonts-ttf liberation-fonts-ttf noto-fonts-ttf noto-fonts-emoji \
    curl wget git xtools base-devel xdg-utils xdg-user-dirs flatpak \
    zsh zsh-syntax-highlighting zsh-autosuggestions fastfetch \
    virt-manager libvirt qemu dnsmasq edk2-ovmf dconf \
    ufw geoclue2 snooze fuse

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_2"

GPU_VENDORS=()
GPU_PKGS=()
if command -v lspci &>/dev/null; then
    GPU_INFO=$(lspci | grep -Ei 'vga|3d|display' || true)

    if echo "$GPU_INFO" | grep -qi 'nvidia'; then
        GPU_VENDORS+=("nvidia")
        GPU_PKGS+=(nvidia nvidia-libs-32bit)
    fi
    if echo "$GPU_INFO" | grep -Eqi 'amd|advanced micro|\bati\b|radeon'; then
        GPU_VENDORS+=("amd")
        GPU_PKGS+=(mesa-vulkan-radeon mesa-vulkan-radeon-32bit mesa-vaapi mesa-vdpau)
    fi
    if echo "$GPU_INFO" | grep -qi 'intel'; then
        GPU_VENDORS+=("intel")
        GPU_PKGS+=(mesa-vulkan-intel mesa-vulkan-intel-32bit intel-media-driver)
    fi
fi

if [ "${#GPU_VENDORS[@]}" -gt 1 ]; then
    log_info "Wykryto hybrydowy układ graficzny: ${GPU_VENDORS[*]}" "Detected a hybrid GPU setup: ${GPU_VENDORS[*]}"
elif [ "${#GPU_VENDORS[@]}" -eq 1 ]; then
    log_info "Wykryto kartę graficzną: ${GPU_VENDORS[*]}" "Detected GPU: ${GPU_VENDORS[*]}"
fi

if [ "${#GPU_PKGS[@]}" -gt 0 ]; then
    install_xbps_pkgs "${GPU_PKGS[@]}"
fi

show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
sudo flatpak config --system --set extra-languages pl

install_flatpak_apps \
    org.mozilla.firefox \
    org.kde.ghostwriter \
    org.videolan.VLC \
    org.audacityteam.Audacity \
    org.mixxx.Mixxx \
    org.kde.kdenlive \
    fr.handbrake.ghb \
    com.discordapp.Discord \
    org.telegram.desktop \
    org.qbittorrent.qBittorrent \
    org.libreoffice.LibreOffice \
    org.kde.krita \
    org.gimp.GIMP \
    org.gimp.GIMP.Plugin.GMic \
    com.brave.Browser \
    com.github.tchx84.Flatseal \
    it.mijorus.gearlever \
    io.github.Faugus.faugus-launcher \
    com.ylsoftware.qmmp.Qmmp \
    org.soundconverter.SoundConverter \
    ai.opencode.opencode \
    org.freedesktop.Platform.VulkanLayer.lsfgvk//24.08 \
    org.freedesktop.Platform.VulkanLayer.lsfgvk//25.08

LSFG_APPS=(io.github.Faugus.faugus-launcher)
mkdir -p "$HOME/.config/lsfg-vk"
for appid in "${LSFG_APPS[@]}"; do
    flatpak override --user --filesystem="$HOME/.config/lsfg-vk:rw" "$appid" || true
    flatpak override --user --filesystem="$HOME/.local/share/Steam/steamapps/common:ro" "$appid" || true
    flatpak override --user --env=LSFGVK_CONFIG="$HOME/.config/lsfg-vk/conf.toml" "$appid" || true
done

# =============================================================
#  ETAP 3/4: OPTYMALIZACJA
# =============================================================
show_progress 5 $TOTAL_STEPS "$MSG_PHASE_3"

TO_REMOVE=(
    gnome-software cosmic-store discover
)
for pkg in "${TO_REMOVE[@]}"; do
    if pkg_installed "$pkg"; then
        sudo xbps-remove -Ry "$pkg" || true
    fi
done
sudo xbps-remove -Oo -y || true

sudo mkdir -p /etc/pipewire/pipewire.conf.d /etc/alsa/conf.d
sudo ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
sudo ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
sudo ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf
sudo ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/99-pipewire-default.conf

show_progress 6 $TOTAL_STEPS "$MSG_PHASE_3"

sudo rm -f /var/service/dhcpcd /var/service/wpa_supplicant

enable_service dbus
enable_service elogind
enable_service NetworkManager
enable_service bluetoothd
enable_service chronyd
enable_service acpid

show_progress 7 $TOTAL_STEPS "$MSG_PHASE_3"

if [ -f /etc/default/ufw ]; then
    sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
fi

if command -v ufw &>/dev/null; then
    sudo ufw allow ssh || true
    sudo ufw allow in  on virbr0 || true
    sudo ufw allow out on virbr0 || true
    sudo ufw --force enable || true
    enable_service ufw
fi

sudo mkdir -p /etc/cron.weekly
printf '#!/bin/sh\nfstrim -Av\n' | sudo tee /etc/cron.weekly/fstrim
sudo chmod 755 /etc/cron.weekly/fstrim
enable_service snooze-weekly

echo "options btusb enable_autosuspend=0" | sudo tee /etc/modprobe.d/btusb.conf

sudo mkdir -p /etc/modules-load.d
echo "fuse" | sudo tee /etc/modules-load.d/fuse.conf
sudo modprobe fuse || true

enable_service libvirtd
enable_service virtlogd
enable_service virtlockd

for _ in $(seq 1 30); do
    sudo virsh list &>/dev/null && break
    sleep 1
done

if ! sudo virsh net-info default &>/dev/null; then
    sudo virsh net-define /usr/share/libvirt/networks/default.xml || true
fi

sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default || true

dbus-run-session -- dconf load /org/virt-manager/virt-manager/ <<'DCONF_EOF' || true
[/]
manager-window-height=297
manager-window-width=478
xmleditor-enabled=true

[confirm]
delete-storage=false
forcepoweroff=false

[connections]
autoconnect=['qemu:///system']
uris=['qemu:///system']

[conns/qemu:system]
window-size=(800, 600)

[details]
show-toolbar=true

[new-vm]
cpu-default='host-passthrough'
firmware='uefi'
graphics-type='spice'
storage-format='raw'

[stats]
enable-disk-poll=true
enable-memory-poll=true
enable-net-poll=true

[vmlist-fields]
disk-usage=false
network-traffic=false

autoconnect=1
vm-window-size=(1280, 842)
DCONF_EOF

for grp in libvirt kvm; do
    getent group "$grp" &>/dev/null && sudo usermod -aG "$grp" "$CURRENT_USER" || true
done

show_progress 8 $TOTAL_STEPS "$MSG_PHASE_3"

if command -v zsh &>/dev/null; then
    sudo chsh -s /usr/bin/zsh "$CURRENT_USER" || true

    [ ! -d "$HOME/.oh-my-zsh" ] && \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended || true

    P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    [ ! -d "$P10K_DIR" ] && \
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR" || true

    if [ -f ~/.zshrc ]; then
        sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc
        sed -i 's/^plugins=(.*/plugins=(git sudo)/' ~/.zshrc

        SHELL_LOCALE="${LANG:-${LC_ALL:-${LC_MESSAGES:-en_US.UTF-8}}}"
        if command -v locale &>/dev/null; then
            AVAILABLE_LOCALES="$(locale -a 2>/dev/null || true)"
            if ! echo "$AVAILABLE_LOCALES" | grep -qiF "$SHELL_LOCALE" && ! echo "$AVAILABLE_LOCALES" | grep -qiF "$(echo "$SHELL_LOCALE" | sed 's/UTF-8/utf8/')"; then
                SHELL_LOCALE="en_US.UTF-8"
            fi
        fi
        if ! grep -q "^export LC_ALL=" ~/.zshrc; then
            {
                echo ""
                echo "export LC_ALL=${SHELL_LOCALE}"
                echo "export LC_MESSAGES=${SHELL_LOCALE}"
                echo "fastfetch"
            } >> ~/.zshrc
        fi

        for plugin_file in \
            /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
            /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
            /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
            /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh; do
            if [ -f "$plugin_file" ] && ! grep -qF "$plugin_file" ~/.zshrc; then
                echo "source $plugin_file" >> ~/.zshrc
            fi
        done
    fi
fi

if [ -f "$SCRIPT_DIR/.update.sh" ]; then
    cp -af "$SCRIPT_DIR/.update.sh" ~/.update.sh
    chmod +x ~/.update.sh
fi

if [ -d "$SCRIPT_DIR/.local" ]; then
    mkdir -p ~/.local
    cp -afT "$SCRIPT_DIR/.local" ~/.local
fi

if [ -d "$SCRIPT_DIR/.config" ]; then
    mkdir -p ~/.config
    cp -afT "$SCRIPT_DIR/.config" ~/.config
fi

# =============================================================
#  ETAP 4/4: CZYSZCZENIE
# =============================================================
show_progress 9 $TOTAL_STEPS "$MSG_PHASE_4"
echo -e "\n" >&3

if [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
    log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}" "Failed to install: ${FAILED_PACKAGES[*]}"
fi

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}✔ CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
fi

# =============================================================
#  RESTART SYSTEMU
# =============================================================
if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${INFO}==> ${RESTART_PROMPT}${NC}" >&3
read -r RESTART_CHOICE < /dev/tty
case "$RESTART_CHOICE" in
    [YyTt]*)
        DO_REBOOT=1
        ;;
esac
exit 0
