#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

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
SCRIPT_LANG="${SCRIPT_LANG:-$(detect_system_lang)}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
info() { local m; m="$(_pick_msg "$1" "$2")"; echo "${GRN}[+]${RST} $m"; }
warn() { local m; m="$(_pick_msg "$1" "$2")"; echo "${YLW}[!]${RST} $m"; }
die()  { local m; m="$(_pick_msg "$1" "$2")"; echo "${RED}[x]${RST} $m" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash -- "$0" "$@"
    elif command -v doas >/dev/null 2>&1; then
        exec doas bash -- "$0" "$@"
    elif command -v su >/dev/null 2>&1; then
        exec su root -c "$(printf '%q ' bash -- "$0" "$@")"
    else
        die "Brak sudo, doas lub su. Uruchom skrypt jako root." \
            "Missing sudo, doas, or su. Run this script as root."
    fi
fi

command -v xbps-install >/dev/null 2>&1 || die "To nie jest Void Linux (brak xbps-install)." "This is not Void Linux (xbps-install not found)."

APPARMOR_PARAMS="apparmor=1 security=apparmor"
BOOTLOADER_CONFIGURED=false
APPARMOR_ALREADY_SET=false
TMP_FILE=""
declare -A SEEN_FILES=()

cleanup() {
    [[ -n "${TMP_FILE:-}" ]] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

has_uncommented_apparmor() {
    grep -qE '^[[:space:]]*[^#]*([[:space:]"'"'"'=:]|^)(apparmor=1|security=apparmor|lsm=[^[:space:]"'"'"']*apparmor)' "$@" 2>/dev/null
}

apply_if_changed() {
    local file="$1"
    local tmp="$2"
    if ! cmp -s "$file" "$tmp"; then
        cat "$tmp" > "$file"
        rm -f "$tmp"
        TMP_FILE=""
        return 0
    fi
    rm -f "$tmp"
    TMP_FILE=""
    return 1
}

mark_seen() {
    local real
    real="$(realpath -e "$1" 2>/dev/null)" || return 1
    if [[ -n "${SEEN_FILES[$real]:-}" ]]; then
        return 1
    fi
    SEEN_FILES[$real]=1
    return 0
}

reconfigure_kernels() {
    local pkg pkgname
    local -a kernel_pkgs=()
    if command -v xbps-query >/dev/null 2>&1 && command -v xbps-uhelper >/dev/null 2>&1; then
        while read -r pkg; do
            [[ -n "$pkg" ]] || continue
            pkgname="$(xbps-uhelper getpkgname "$pkg" 2>/dev/null || true)"
            if [[ "$pkgname" =~ ^linux[0-9]+\.[0-9]+$ ]]; then
                kernel_pkgs+=("$pkgname")
            fi
        done < <(xbps-query -l | awk '$1 == "ii" {print $2}')
    fi

    if (( ${#kernel_pkgs[@]} > 0 )) && command -v xbps-reconfigure >/dev/null 2>&1; then
        info "Przebudowywanie konfiguracji jąder (${kernel_pkgs[*]})..." \
             "Reconfiguring kernels (${kernel_pkgs[*]})..."
        xbps-reconfigure -f "${kernel_pkgs[@]}"
        return 0
    fi
    return 1
}

configure_uki() {
    local dracut_uki=false
    local has_uki_efi=false

    local dracut_confs=(/etc/dracut.conf /etc/dracut.conf.d/*.conf)
    local existing_dracut=()
    for f in "${dracut_confs[@]}"; do
        [[ -f "$f" ]] && existing_dracut+=("$f")
    done
    if (( ${#existing_dracut[@]} > 0 )) && grep -qE '^[[:space:]]*uefi="?yes"?' "${existing_dracut[@]}"; then
        dracut_uki=true
    fi

    local uki_efis=(/boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi /boot/efi/EFI/Linux/*.efi)
    if (( ${#uki_efis[@]} > 0 )); then
        has_uki_efi=true
    fi

    if [[ "$dracut_uki" == false && "$has_uki_efi" == false ]]; then
        return
    fi

    info "Wykryto UKI (Unified Kernel Image)." "Detected UKI (Unified Kernel Image)."
    local uki_updated=false
    local cmdline_d=(/etc/cmdline.d/*.conf)
    local check_files=()
    [[ -f /etc/kernel/cmdline ]] && check_files+=(/etc/kernel/cmdline)
    (( ${#cmdline_d[@]} > 0 )) && check_files+=("${cmdline_d[@]}")
    (( ${#existing_dracut[@]} > 0 )) && check_files+=("${existing_dracut[@]}")

    if (( ${#check_files[@]} > 0 )) && has_uncommented_apparmor "${check_files[@]}"; then
        warn "Parametry AppArmor są już obecne w konfiguracji UKI / dracut – sprawdź je ręcznie." \
             "AppArmor parameters are already present in UKI / dracut configuration – check them manually."
        APPARMOR_ALREADY_SET=true
        return
    fi

    if [[ -s /etc/kernel/cmdline ]] && grep -qvE '^[[:space:]]*(#|$)' /etc/kernel/cmdline; then
        TMP_FILE="$(mktemp)"
        awk -v param="$APPARMOR_PARAMS" '
            !done && $0 !~ /^[[:space:]]*#/ && $0 ~ /[^[:space:]]/ {
                sub(/[[:space:]]+$/, "")
                $0 = $0 " " param
                done = 1
            }
            { print }
        ' /etc/kernel/cmdline > "$TMP_FILE"
        if apply_if_changed /etc/kernel/cmdline "$TMP_FILE"; then
            info "Zaktualizowano /etc/kernel/cmdline." "Updated /etc/kernel/cmdline."
            uki_updated=true
        fi
    elif (( ${#cmdline_d[@]} > 0 )); then
        echo "$APPARMOR_PARAMS" > /etc/cmdline.d/99-apparmor.conf
        info "Utworzono /etc/cmdline.d/99-apparmor.conf." "Created /etc/cmdline.d/99-apparmor.conf."
        uki_updated=true
    elif [[ "$dracut_uki" == true ]]; then
        mkdir -p /etc/dracut.conf.d
        echo "kernel_cmdline+=\" ${APPARMOR_PARAMS} \"" > /etc/dracut.conf.d/99-apparmor.conf
        info "Utworzono /etc/dracut.conf.d/99-apparmor.conf." "Created /etc/dracut.conf.d/99-apparmor.conf."
        uki_updated=true
    else
        warn "Wykryto UKI, ale nie znaleziono aktywnej konfiguracji w /etc/kernel/cmdline, /etc/cmdline.d ani dracut." \
             "UKI detected, but no active configuration was found in /etc/kernel/cmdline, /etc/cmdline.d, or dracut."
        warn "Dodaj ręcznie do linii poleceń jądra:" "Add manually to the kernel command line:"
        echo "  $APPARMOR_PARAMS"
    fi

    if [[ "$uki_updated" == true ]]; then
        if ! reconfigure_kernels; then
            if command -v dracut >/dev/null 2>&1; then
                info "Przebudowywanie obrazów UKI (dracut)..." "Rebuilding UKI images (dracut)..."
                dracut --regenerate-all --force
            else
                warn "Przebuduj obrazy UKI ręcznie." "Rebuild UKI images manually."
            fi
        fi
        BOOTLOADER_CONFIGURED=true
    fi
}

configure_efibootmgr_hook() {
    local hook_conf="/etc/default/efibootmgr-kernel-hook"
    if [[ ! -f "$hook_conf" ]]; then
        return
    fi
    mark_seen "$hook_conf" || return

    if ! grep -qE '^[[:space:]]*MODIFY_EFI_ENTRIES=("?1"?|"?true"?)' "$hook_conf"; then
        return
    fi

    info "Wykryto efibootmgr-kernel-hook ($hook_conf)." "Detected efibootmgr-kernel-hook ($hook_conf)."
    if has_uncommented_apparmor "$hook_conf"; then
        warn "Parametry AppArmor są już obecne w $hook_conf – sprawdź je ręcznie." \
             "AppArmor parameters are already present in $hook_conf – check them manually."
        APPARMOR_ALREADY_SET=true
        return
    fi

    if grep -qE '^[[:space:]]*OPTIONS=("[^"]*"|'\''[^'\'']*'\'')[[:space:]]*$' "$hook_conf"; then
        TMP_FILE="$(mktemp)"
        awk -v param="$APPARMOR_PARAMS" '
            /^[[:space:]]*OPTIONS="[^"]*"[[:space:]]*$/ {
                sub(/"[[:space:]]*$/, "")
                if ($0 ~ /="$/) {
                    $0 = $0 param "\""
                } else {
                    $0 = $0 " " param "\""
                }
            }
            /^[[:space:]]*OPTIONS='\''[^'\'']*'\''[[:space:]]*$/ {
                sub(/'\''[[:space:]]*$/, "")
                if ($0 ~ /='\''$/) {
                    $0 = $0 param "'\''"
                } else {
                    $0 = $0 " " param "'\''"
                }
            }
            { print }
        ' "$hook_conf" > "$TMP_FILE"

        if apply_if_changed "$hook_conf" "$TMP_FILE"; then
            reconfigure_kernels || true
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano $hook_conf." "Updated $hook_conf."
        fi
    else
        warn "Nie znaleziono standardowej linii OPTIONS= w $hook_conf." \
             "Standard OPTIONS= line not found in $hook_conf."
    fi
}

configure_grub() {
    if [[ ! -f /etc/default/grub ]]; then
        return
    fi
    if ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-mkconfig >/dev/null 2>&1; then
        return
    fi
    mark_seen /etc/default/grub || return

    info "Wykryto GRUB." "Detected GRUB."
    if grep -qE '^GRUB_CMDLINE_LINUX(_DEFAULT)?=("[^"]*(apparmor=1|security=apparmor|lsm=[^"]*apparmor)[^"]*"|'\''[^'\'']*(apparmor=1|security=apparmor|lsm=[^'\'']*apparmor)[^'\'']*'\'')' /etc/default/grub; then
        warn "Parametry AppArmor są już obecne w /etc/default/grub – sprawdź je ręcznie." \
             "AppArmor parameters are already present in /etc/default/grub – check them manually."
        APPARMOR_ALREADY_SET=true
        return
    fi

    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=("[^"]*"|'\''[^'\'']*'\'')[[:space:]]*$' /etc/default/grub; then
        TMP_FILE="$(mktemp)"
        awk -v param="$APPARMOR_PARAMS" '
            /^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"[[:space:]]*$/ {
                sub(/"[[:space:]]*$/, "")
                if ($0 ~ /="$/) {
                    $0 = $0 param "\""
                } else {
                    $0 = $0 " " param "\""
                }
            }
            /^GRUB_CMDLINE_LINUX_DEFAULT='\''[^'\'']*'\''[[:space:]]*$/ {
                sub(/'\''[[:space:]]*$/, "")
                if ($0 ~ /='\''$/) {
                    $0 = $0 param "'\''"
                } else {
                    $0 = $0 " " param "'\''"
                }
            }
            { print }
        ' /etc/default/grub > "$TMP_FILE"

        if apply_if_changed /etc/default/grub "$TMP_FILE"; then
            if command -v update-grub >/dev/null 2>&1; then
                update-grub
                info "Zaktualizowano GRUB (update-grub)." "Updated GRUB (update-grub)."
            else
                local grub_cfg="/boot/grub/grub.cfg"
                for candidate in /boot/grub/grub.cfg /efi/grub/grub.cfg /boot/efi/grub/grub.cfg; do
                    if [[ -f "$candidate" ]]; then
                        grub_cfg="$candidate"
                        break
                    fi
                done
                grub-mkconfig -o "$grub_cfg"
                info "Zaktualizowano GRUB ($grub_cfg)." "Updated GRUB ($grub_cfg)."
            fi
            BOOTLOADER_CONFIGURED=true
        fi
    else
        warn "Nie znaleziono standardowej linii GRUB_CMDLINE_LINUX_DEFAULT w /etc/default/grub." \
             "Standard GRUB_CMDLINE_LINUX_DEFAULT line not found in /etc/default/grub."
    fi
}

configure_systemd_boot() {
    local dir entry name
    for dir in /boot/loader/entries /efi/loader/entries /boot/efi/loader/entries; do
        [[ -d "$dir" ]] || continue
        local entries=("$dir"/*.conf)
        (( ${#entries[@]} > 0 )) || continue

        info "Wykryto systemd-boot w $dir." "Detected systemd-boot in $dir."
        for entry in "${entries[@]}"; do
            mark_seen "$entry" || continue
            name="$(basename "$entry")"

            if [[ "${name,,}" == *fallback* ]]; then
                info "Pominięto wpis awaryjny: $name" "Skipped fallback entry: $name"
                continue
            fi
            if grep -qE '^[[:space:]]*options[[:space:]]+.*(^|[[:space:]])(apparmor=1|security=apparmor|lsm=[^[:space:]]*apparmor)' "$entry"; then
                warn "$name zawiera już parametry AppArmor – pominięto." \
                     "$name already contains AppArmor parameters – skipped."
                APPARMOR_ALREADY_SET=true
                continue
            fi
            if grep -qE '^[[:space:]]*options[[:space:]]+' "$entry"; then
                TMP_FILE="$(mktemp)"
                awk -v param="$APPARMOR_PARAMS" '
                    !done && /^[[:space:]]*options[[:space:]]+/ {
                        sub(/[[:space:]]+$/, "")
                        $0 = $0 " " param
                        done = 1
                    }
                    { print }
                ' "$entry" > "$TMP_FILE"
                if apply_if_changed "$entry" "$TMP_FILE"; then
                    BOOTLOADER_CONFIGURED=true
                    info "Zaktualizowano wpis systemd-boot: $name" "Updated systemd-boot entry: $name"
                fi
            fi
        done
    done
}

configure_refind() {
    local f

    # 1. Automatyczne wpisy w refind_linux.conf
    for f in /boot/refind_linux.conf /efi/refind_linux.conf /boot/efi/refind_linux.conf; do
        [[ -f "$f" ]] || continue
        mark_seen "$f" || continue

        info "Wykryto rEFInd ($f)." "Detected rEFInd ($f)."
        if has_uncommented_apparmor "$f"; then
            warn "$f zawiera już parametry AppArmor – pominięto." \
                 "$f already contains AppArmor parameters – skipped."
            APPARMOR_ALREADY_SET=true
            continue
        fi

        TMP_FILE="$(mktemp)"
        awk -v param="$APPARMOR_PARAMS" '
            /^[[:space:]]*"[^"]+"[[:space:]]+"[^"]*"[[:space:]]*$/ {
                title = $0
                sub(/^[[:space:]]*"/, "", title)
                sub(/".*$/, "", title)
                if (tolower(title) !~ /fallback|minimal|single/ && $0 !~ /(apparmor=1|security=apparmor)/) {
                    if ($0 ~ /""[[:space:]]*$/) {
                        sub(/"[[:space:]]*$/, param "\"")
                    } else {
                        sub(/"[[:space:]]*$/, " " param "\"")
                    }
                }
            }
            { print }
        ' "$f" > "$TMP_FILE"

        if apply_if_changed "$f" "$TMP_FILE"; then
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano $f." "Updated $f."
        fi
    done

    # 2. Ręczne sekcje menuentry w refind.conf
    for f in /boot/EFI/refind/refind.conf /efi/EFI/refind/refind.conf /boot/efi/EFI/refind/refind.conf; do
        [[ -f "$f" ]] || continue
        mark_seen "$f" || continue

        if ! grep -qE '^[[:space:]]*options[[:space:]]+"[^"]*"' "$f"; then
            continue
        fi

        info "Wykryto ręczne wpisy rEFInd ($f)." "Detected manual rEFInd entries ($f)."
        if grep -qE '^[[:space:]]*options[[:space:]]+"[^"]*(apparmor=1|security=apparmor|lsm=[^"]*apparmor)[^"]*"' "$f"; then
            APPARMOR_ALREADY_SET=true
        fi

        TMP_FILE="$(mktemp)"
        awk -v param="$APPARMOR_PARAMS" '
            BEGIN { depth = 0; skip_depth = 0 }
            /^[[:space:]]*(menuentry|submenuentry)[[:space:]]+/ {
                depth++
                if (skip_depth == 0 && tolower($0) ~ /fallback|minimal|single/) {
                    skip_depth = depth
                }
                print
                next
            }
            /^[[:space:]]*\}[[:space:]]*$/ {
                if (skip_depth == depth) {
                    skip_depth = 0
                }
                if (depth > 0) depth--
                print
                next
            }
            skip_depth == 0 && /^[[:space:]]*options[[:space:]]+"[^"]*"[[:space:]]*$/ && $0 !~ /(apparmor=1|security=apparmor|lsm=[^"]*apparmor)/ {
                if ($0 ~ /""[[:space:]]*$/) {
                    sub(/"[[:space:]]*$/, param "\"")
                } else {
                    sub(/"[[:space:]]*$/, " " param "\"")
                }
            }
            { print }
        ' "$f" > "$TMP_FILE"

        if apply_if_changed "$f" "$TMP_FILE"; then
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano wpisy w $f." "Updated entries in $f."
        fi
    done
}

configure_limine() {
    # 1. limine-entry-tool (jeśli zainstalowane)
    if [[ -f /etc/default/limine ]] && command -v limine-update >/dev/null 2>&1; then
        mark_seen /etc/default/limine || return
        info "Wykryto Limine zarządzane przez limine-entry-tool (/etc/default/limine)." \
             "Detected Limine managed by limine-entry-tool (/etc/default/limine)."
        if has_uncommented_apparmor /etc/default/limine; then
            warn "/etc/default/limine zawiera już parametry AppArmor – sprawdź je ręcznie." \
                 "/etc/default/limine already contains AppArmor parameters – check them manually."
            APPARMOR_ALREADY_SET=true
            return
        fi
        printf '\nKERNEL_CMDLINE[default]+=" %s"\n' "$APPARMOR_PARAMS" >> /etc/default/limine
        limine-update
        BOOTLOADER_CONFIGURED=true
        info "Zaktualizowano /etc/default/limine i wykonano limine-update." \
             "Updated /etc/default/limine and ran limine-update."
        return
    fi

    # 2. Bezpośrednie pliki limine.conf
    local candidates=(
        /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf
        /efi/limine.conf /efi/limine/limine.conf /efi/EFI/limine/limine.conf
        /boot/efi/limine.conf /boot/efi/limine/limine.conf /boot/efi/EFI/limine/limine.conf
    )

    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] || continue
        mark_seen "$f" || continue

        info "Wykryto Limine ($f)." "Detected Limine ($f)."
        if has_uncommented_apparmor "$f"; then
            warn "$f zawiera już parametry AppArmor – pominięto." \
                 "$f already contains AppArmor parameters – skipped."
            APPARMOR_ALREADY_SET=true
            continue
        fi

        TMP_FILE="$(mktemp)"
        awk -v param="$APPARMOR_PARAMS" '
            /^[[:space:]]*\/+/ {
                skip = (tolower($0) ~ /fallback/)
            }
            !skip && /^[[:space:]]*(kernel_)?cmdline:[[:space:]]*/ && $0 !~ /(apparmor=1|security=apparmor|lsm=[^[:space:]]*apparmor)/ {
                sub(/[[:space:]]+$/, "")
                $0 = $0 " " param
            }
            { print }
        ' "$f" > "$TMP_FILE"

        if apply_if_changed "$f" "$TMP_FILE"; then
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano $f." "Updated $f."
        fi
    done
}

info "Instalacja pakietów apparmor i audit..." "Installing apparmor and audit packages..."
xbps-install -Sy apparmor audit

info "Konfiguracja ładowania profili przy starcie (/etc/default/apparmor)..." \
     "Configuring profile loading at boot (/etc/default/apparmor)..."
if [[ -f /etc/default/apparmor ]]; then
    if grep -qE '^[[:space:]]*APPARMOR=' /etc/default/apparmor; then
        if grep -qE '^[[:space:]]*APPARMOR=["'"'"']?disable["'"'"']?' /etc/default/apparmor; then
            sed -i -E 's/^[[:space:]]*APPARMOR=.*/APPARMOR=enforce/' /etc/default/apparmor
        fi
    elif grep -qE '^[[:space:]]*#[[:space:]]*APPARMOR=' /etc/default/apparmor; then
        sed -i -E 's/^[[:space:]]*#[[:space:]]*APPARMOR=.*/APPARMOR=enforce/' /etc/default/apparmor
    else
        echo "APPARMOR=enforce" >> /etc/default/apparmor
    fi
else
    mkdir -p /etc/default
    echo "APPARMOR=enforce" > /etc/default/apparmor
fi

info "Włączanie cache'owania profili (/etc/apparmor/parser.conf)..." \
     "Enabling profile caching (/etc/apparmor/parser.conf)..."
if [[ -f /etc/apparmor/parser.conf ]]; then
    if grep -qE '^[[:space:]]*#[[:space:]]*write-cache' /etc/apparmor/parser.conf; then
        sed -i -E 's/^[[:space:]]*#[[:space:]]*write-cache/write-cache/' /etc/apparmor/parser.conf
    elif ! grep -qE '^[[:space:]]*write-cache' /etc/apparmor/parser.conf; then
        echo "write-cache" >> /etc/apparmor/parser.conf
    fi
fi

if [[ -d /etc/sv/auditd ]]; then
    info "Aktywacja usługi runit auditd..." "Enabling runit auditd service..."
    if [[ ! -e /var/service/auditd ]]; then
        ln -s /etc/sv/auditd /var/service/auditd
    fi
else
    warn "Nie znaleziono usługi /etc/sv/auditd – pominięto." \
         "Service /etc/sv/auditd not found – skipped."
fi

info "Wykrywanie i konfiguracja bootloadera / UKI..." \
     "Detecting and configuring bootloader / UKI..."
configure_uki
configure_efibootmgr_hook
configure_grub
configure_systemd_boot
configure_refind
configure_limine

if [[ "$BOOTLOADER_CONFIGURED" == false && "$APPARMOR_ALREADY_SET" == false ]]; then
    echo
    warn "Nie wprowadzono automatycznych zmian w parametrach jądra." \
         "No automatic changes were made to kernel parameters."
    warn "Dodaj ręcznie do linii poleceń jądra:" \
         "Add manually to the kernel command line:"
    echo "  $APPARMOR_PARAMS"
fi

echo
info "Gotowe. Po restarcie zweryfikuj działanie poleceniami:" \
     "Done. After rebooting, verify with:"
echo "  aa-enabled"
echo "  sudo aa-status"
echo

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${BLU}==> ${RESTART_PROMPT}${RST}"
RESTART_CHOICE=""
if [[ -r /dev/tty ]]; then
    read -r RESTART_CHOICE < /dev/tty || RESTART_CHOICE=""
else
    read -r RESTART_CHOICE || RESTART_CHOICE=""
fi
case "$RESTART_CHOICE" in
    [YyTt]*)
        info "Restartowanie systemu..." "Restarting the system..."
        reboot
        ;;
    *)
        warn "Pominięto restart. Uruchom system ponownie ręcznie, aby aktywować AppArmor." \
             "Reboot skipped. Restart the system manually to activate AppArmor."
        ;;
esac
exit 0