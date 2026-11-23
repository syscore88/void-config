#!/bin/bash
set -uo pipefail

detect_system_lang() {
    local sys_lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    sys_lang="${sys_lang//\"/}"
    sys_lang="${sys_lang//\'/}"
    if [[ "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[1;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/update-log.XXXXXX)"
LOG_FILE="$HOME/update_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

RESTART_NEEDED=false

PRIVS_GRANTED=0

remove_temp_privs() {
    [[ "$PRIVS_GRANTED" -eq 1 ]] || return 0
    PRIVS_GRANTED=0
    sudo -n rm -f /etc/sudoers.d/99-temp-update </dev/null 3>&- 2>/dev/null || true
}

cleanup_on_exit() {
    local exit_code=$?
    remove_temp_privs
    printf '\033[?25h' >&3 2>/dev/null || true
    echo "" >&3 2>/dev/null || true
    if [ "$exit_code" -ne 0 ]; then
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3 2>/dev/null || true
        else
            echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3 2>/dev/null || true
        fi
    else
        rm -f "$LOG_FILE"
    fi
    rm -f "$TMP_LOG"
    exec 3>&- 2>/dev/null || true
}
trap cleanup_on_exit EXIT

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    local bar_width=50
    local reserved=12
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ "$filled" -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ "$empty" -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    if (( avail >= 4 )); then
        if (( ${#msg} > avail )); then
            msg="${msg:0:$((avail - 3))}..."
        fi
        printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
    else
        printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%%" "$bar_filled" "$bar_empty" "$percent" >&3
    fi
}

print_pkg_list() {
    local title="$1"
    local list="$2"
    [ -z "$list" ] && return
    printf "\r\033[K" >&3
    echo -e "${INFO}${title}${NC}" >&3
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && echo -e "  ${SUCCESS}•${NC} $pkg" >&3
    done <<< "$list"
}

if [ "$SCRIPT_LANG" = "pl" ]; then
    MSG_TITLE="                  KONSERWACJA SYSTEMU                  "
    MSG_ASK_PASS="Proszę podać hasło administratora (sudo):"
    MSG_PHASE_UPDATE="[1/2] Aktualizacja i optymalizacja..."
    MSG_PKGS_UPDATED="Aktualizowane pakiety:"
    MSG_PKGS_NONE="Brak pakietów do aktualizacji (system aktualny)."
    MSG_FLATPAK_UPDATED="Aktualizowane pakiety Flatpak:"
    MSG_PHASE_CLEAN_SYS="[2/2] Czyszczenie systemowe..."
    MSG_DONE="             KONSERWACJA SYSTEMU ZAKOŃCZONA!           "
    MSG_RESTART_WARN="UWAGA: Zalecany jest restart komputera"
    MSG_NO_RESTART="Restart systemu nie jest aktualnie wymagany."
    MSG_PRESS_ENTER="Naciśnij Enter, aby zamknąć okno..."
    MSG_UPDATE_FAIL="[X] Aktualizacja pakietów xbps nie powiodła się – przerywam."
else
    MSG_TITLE="                   SYSTEM MAINTENANCE                   "
    MSG_ASK_PASS="Please enter the administrator (sudo) password:"
    MSG_PHASE_UPDATE="[1/2] Updates and optimization..."
    MSG_PKGS_UPDATED="Updating packages:"
    MSG_PKGS_NONE="No packages to update (system is up to date)."
    MSG_FLATPAK_UPDATED="Updating Flatpak packages:"
    MSG_PHASE_CLEAN_SYS="[2/2] System cleanup..."
    MSG_DONE="             SYSTEM MAINTENANCE COMPLETE!           "
    MSG_RESTART_WARN="WARNING: A system restart is recommended"
    MSG_NO_RESTART="A system restart is not currently required."
    MSG_PRESS_ENTER="Press Enter to close this window..."
    MSG_UPDATE_FAIL="[X] xbps package update failed - aborting."
fi

CURRENT_USER=$(whoami)

cleanup_stale_privs() {
    sudo -n true </dev/null 3>&- 2>/dev/null || return 0
    sudo -n rm -f /etc/sudoers.d/99-temp-update </dev/null 3>&- 2>/dev/null || true
}
cleanup_stale_privs

echo -e "${INFO}======================================================${NC}" >&3
echo -e "${INFO}${MSG_TITLE}${NC}" >&3
echo -e "${INFO}======================================================${NC}" >&3
echo -e "${WARN}${MSG_ASK_PASS}${NC}" >&3
if [[ -r /dev/tty ]]; then
    IFS= read -rs SUDO_PASSWORD < /dev/tty || true
else
    IFS= read -rs SUDO_PASSWORD || true
fi
echo "" >&3

SUDOERS_TMP="$(mktemp)"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$CURRENT_USER" > "$SUDOERS_TMP"
if printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' visudo -cf "$SUDOERS_TMP" 3>&- &>/dev/null \
   && printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' install -d -m 0750 -o root -g root /etc/sudoers.d 3>&- &>/dev/null \
   && printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-update 3>&- &>/dev/null; then
    PRIVS_GRANTED=1
    rm -f "$SUDOERS_TMP"
    unset SUDO_PASSWORD
    if ! sudo -n true </dev/null 3>&- 2>/dev/null; then
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${WARN}[!] Reguła NOPASSWD zainstalowana, ale sudo nadal prosi o hasło - sprawdź 'sudo -l' (możliwa inna reguła w /etc/sudoers nadpisująca wpis z sudoers.d).${NC}" >&3
        else
            echo -e "${WARN}[!] NOPASSWD rule installed, but sudo still asks for a password - check 'sudo -l' (a rule in /etc/sudoers may be overriding the sudoers.d entry).${NC}" >&3
        fi
    fi
else
    rm -f "$SUDOERS_TMP"
    unset SUDO_PASSWORD
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}[X] Nieprawidłowe hasło lub składnia pliku sudoers – przerywam. Jeśli w /etc/sudoers działa opcja targetpw, podaj hasło roota.${NC}" >&3
    else
        echo -e "${ERR}[X] Wrong password or invalid sudoers syntax - aborting. If targetpw is set in /etc/sudoers, enter the root password.${NC}" >&3
    fi
    exit 1
fi

if ! sudo -n true </dev/null 3>&- 2>/dev/null; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}[X] Nie udało się uzyskać uprawnień bez hasła – przerywam.${NC}" >&3
    else
        echo -e "${ERR}[X] Could not obtain passwordless privileges - aborting.${NC}" >&3
    fi
    exit 1
fi

TOTAL_STEPS=17
STEP=0
printf '\033[?25l' >&3
show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

# ---------------------------------------------------------------
# PHASE: UPDATE
# ---------------------------------------------------------------
sudo env LC_ALL=C xbps-install -Syu xbps </dev/null 3>&-
XBPS_RC=$?
if [ "$XBPS_RC" -ne 0 ]; then
    printf "\r\033[K" >&3
    echo -e "${ERR}${MSG_UPDATE_FAIL}${NC}" >&3
    exit "$XBPS_RC"
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

PKG_VERSIONS=$(sudo env LC_ALL=C xbps-install -un </dev/null 3>&- 2>/dev/null | awk 'NF >= 2 { print $1 }' | sort -u)

XBPS_OUTPUT=$(sudo env LC_ALL=C xbps-install -yu </dev/null 3>&- 2>&1)
XBPS_RC=$?
echo "$XBPS_OUTPUT"
if [ "$XBPS_RC" -ne 0 ]; then
    printf "\r\033[K" >&3
    echo -e "${ERR}${MSG_UPDATE_FAIL}${NC}" >&3
    exit "$XBPS_RC"
fi

if [ -n "$PKG_VERSIONS" ]; then
    print_pkg_list "$MSG_PKGS_UPDATED" "$PKG_VERSIONS"
else
    printf "\r\033[K" >&3
    echo -e "${INFO}${MSG_PKGS_NONE}${NC}" >&3
fi

STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v gext &> /dev/null; then
    gext update </dev/null 3>&-
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v cinnamon-spice-updater &> /dev/null; then
    cinnamon-spice-updater --update-all </dev/null 3>&-
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v fwupdmgr &> /dev/null; then
    sudo env LC_ALL=C fwupdmgr refresh --force </dev/null 3>&-
    FWUPD_OUT=$(sudo env LC_ALL=C fwupdmgr update -y --no-reboot-check </dev/null 3>&- 2>&1)
    echo "$FWUPD_OUT"
    if echo "$FWUPD_OUT" | grep -qiE "restart|reboot"; then
        RESTART_NEEDED=true
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: SYSTEM CLEANUP (SUDO)
# ---------------------------------------------------------------
sudo find /var/cache/xbps -type f -name "*.part" -delete </dev/null 3>&- 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

{
    sudo env LC_ALL=C xbps-remove -oy
    if command -v vkpurge &> /dev/null; then
        mapfile -t OLD_KERNELS < <(vkpurge list 2>/dev/null | sort -V | head -n -1)
        if (( ${#OLD_KERNELS[@]} > 0 )); then
            sudo vkpurge rm "${OLD_KERNELS[@]}"
        fi
    fi
} </dev/null 3>&-
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

{
    sudo find /var/cache/xbps -maxdepth 1 -type f -name '*.xbps' 2>/dev/null \
        | awk -F/ '{ f = $NF; n = f; sub(/-[^-]+_[0-9]+\.[^.]+\.xbps$/, "", n); a = f; sub(/\.xbps$/, "", a); sub(/^.*\./, "", a); printf "%s.%s\t%s\t%s\n", n, a, f, $0 }' \
        | env LC_ALL=C sort -t$'\t' -k1,1 -k2,2Vr \
        | awk -F'\t' '$1 == prev { n++ } $1 != prev { n = 1; prev = $1 } n > 2 { print $3; print $3 ".sig"; print $3 ".sig2" }' \
        | xargs -r -d '\n' sudo rm -f --
} </dev/null 3>&-
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v flatpak &> /dev/null; then
    FLATPAK_BEFORE=$(flatpak list --system --app --columns=application,version </dev/null 3>&- 2>/dev/null)

    sudo flatpak update --system -y </dev/null 3>&-

    FLATPAK_AFTER=$(flatpak list --system --app --columns=application,version </dev/null 3>&- 2>/dev/null)

    FLATPAK_PKGS=$(LC_ALL=C join -t$'\t' -j1 \
        <(echo "$FLATPAK_BEFORE" | LC_ALL=C sort -t$'\t' -k1,1) \
        <(echo "$FLATPAK_AFTER" | LC_ALL=C sort -t$'\t' -k1,1) 2>/dev/null \
        | awk -F'\t' '$2 != $3 { printf "%s: %s → %s\n", $1, ($2==""?"?":$2), ($3==""?"?":$3) }')
    print_pkg_list "$MSG_FLATPAK_UPDATED" "$FLATPAK_PKGS"

    {
        sudo flatpak uninstall --unused --system --delete-data -y
        sudo flatpak repair --system

        USED_REMOTES=$(flatpak list --system --columns=origin 2>/dev/null | sort -u)
        ALL_REMOTES=$(flatpak remotes --system --columns=name 2>/dev/null)
        while IFS= read -r remote; do
            if [ -n "$remote" ] && [ "$remote" != "flathub" ] && ! echo "$USED_REMOTES" | grep -qxF -- "$remote"; then
                sudo flatpak remote-delete --system --force "$remote" </dev/null 2>/dev/null
            fi
        done <<< "$ALL_REMOTES"

        sudo rm -rf /var/tmp/flatpak-cache-* 2>/dev/null
        sudo rm -rf /var/lib/flatpak/repo/tmp/* 2>/dev/null
        sudo find /var/lib/flatpak -name "*.tmp" -delete 2>/dev/null
        sudo rm -f /var/lib/flatpak/history 2>/dev/null
    } </dev/null 3>&-
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

{
    sudo find /var/log -type f -name "*.gz" -mtime +7 -exec rm -f {} +
    sudo find /var/log -type f -name "*.1" -exec rm -f {} +
} </dev/null 3>&-
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

{
    sudo find /tmp -xdev -type f -atime +3 \
        ! -path "/tmp/systemd-private-*" \
        ! -path "/tmp/.*" \
        -exec rm -f {} + 2>/dev/null
    sudo find /var/tmp -xdev -type f -atime +3 \
        ! -path "/var/tmp/systemd-private-*" \
        ! -path "/var/tmp/.*" \
        -exec rm -f {} + 2>/dev/null
} </dev/null 3>&-
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: USER CLEANUP (NO SUDO)
# ---------------------------------------------------------------
if command -v flatpak &> /dev/null; then
    FLATPAK_BEFORE=$(flatpak list --user --app --columns=application,version </dev/null 3>&- 2>/dev/null)

    flatpak update --user -y </dev/null 3>&-

    FLATPAK_AFTER=$(flatpak list --user --app --columns=application,version </dev/null 3>&- 2>/dev/null)

    FLATPAK_PKGS=$(LC_ALL=C join -t$'\t' -j1 \
        <(echo "$FLATPAK_BEFORE" | LC_ALL=C sort -t$'\t' -k1,1) \
        <(echo "$FLATPAK_AFTER" | LC_ALL=C sort -t$'\t' -k1,1) 2>/dev/null \
        | awk -F'\t' '$2 != $3 { printf "%s: %s → %s\n", $1, ($2==""?"?":$2), ($3==""?"?":$3) }')
    print_pkg_list "$MSG_FLATPAK_UPDATED" "$FLATPAK_PKGS"

    {
        flatpak uninstall --unused --user --delete-data -y
        flatpak repair --user
        rm -rf ~/.local/share/flatpak/repo/tmp/* 2>/dev/null
        rm -f ~/.local/share/flatpak/history 2>/dev/null

        INSTALLED_FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
        if [ -n "$INSTALLED_FLATPAKS" ] && [ -d "$HOME/.var/app" ]; then
            for app_dir in "$HOME/.var/app"/*; do
                if [ -d "$app_dir" ]; then
                    app_id=$(basename "$app_dir")
                    if ! echo "$INSTALLED_FLATPAKS" | grep -qxF -- "$app_id"; then
                        rm -rf "$app_dir"
                    fi
                fi
            done
        fi
    } </dev/null 3>&-
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

find ~/.cache -type f -atime +14 \
    ! -path "*/mozilla/*" \
    ! -path "*/google-chrome/*" \
    ! -path "*/chromium/*" \
    ! -path "*/BraveSoftware/*" \
    ! -path "*/opera/*" \
    ! -path "*/vivaldi/*" \
    ! -path "*/huggingface/*" \
    ! -path "*/torch/*" \
    ! -path "*/ms-playwright/*" \
    -exec rm -f {} + </dev/null 3>&- 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

find ~/.cache/thumbnails -type f -atime +7 -exec rm -f {} + </dev/null 3>&- 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

fc-cache -r </dev/null 3>&-
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

{
    USER_ID=$(id -u)
    if command -v dconf &> /dev/null && [ -S "/run/user/$USER_ID/bus" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
    fi
    rm -rf "$HOME/.cache/virt-manager" 2>/dev/null
} </dev/null 3>&-
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: RESTART CHECK
# ---------------------------------------------------------------
RUNNING_KERNEL="$(uname -r)"
LATEST_KERNEL=$(for f in /boot/vmlinuz-*; do [ -e "$f" ] && printf '%s\n' "${f##*/vmlinuz-}"; done | sort -V | tail -n1)
if [ ! -d "/usr/lib/modules/$RUNNING_KERNEL" ] || { [ -n "$LATEST_KERNEL" ] && [ "$LATEST_KERNEL" != "$RUNNING_KERNEL" ]; }; then
    RESTART_NEEDED=true
fi
if [ -n "$PKG_VERSIONS" ] && grep -qE '^(glibc|musl|dbus|elogind|eudev|runit|amd-ucode|intel-ucode)-[0-9]' <<< "$PKG_VERSIONS"; then
    RESTART_NEEDED=true
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

remove_temp_privs

printf '\033[?25h' >&3 2>/dev/null || true
echo -e "\n" >&3
echo -e "${SUCCESS}======================================================${NC}" >&3
echo -e "${SUCCESS}${MSG_DONE}${NC}" >&3
echo -e "${SUCCESS}======================================================${NC}" >&3

if [ "$RESTART_NEEDED" = true ]; then
    echo -e "${WARN}${MSG_RESTART_WARN}${NC}" >&3
else
    echo -e "${INFO}${MSG_NO_RESTART}${NC}" >&3
fi
echo -e "${WARN}${MSG_PRESS_ENTER}${NC}" >&3
if exec 4</dev/tty 2>/dev/null; then
    stty sane <&4 2>/dev/null || true
    IFS= read -r _ <&4 || true
    exec 4<&-
else
    stty sane 2>/dev/null || true
    IFS= read -r _ || true
fi

PARENT_COMM="$(ps -o comm= -p "$PPID" 2>/dev/null || cat "/proc/$PPID/comm" 2>/dev/null || true)"
PARENT_COMM="$(printf '%s' "$PARENT_COMM" | tr -d '[:space:]')"
PARENT_COMM="${PARENT_COMM#-}"
case "$PARENT_COMM" in
    bash|zsh|fish|sh|dash|ksh)
        trap '' HUP PIPE
        kill -HUP "$PPID" 2>/dev/null || true
        ;;
esac
exit 0
