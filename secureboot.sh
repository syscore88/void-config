#!/bin/sh
set -eu

detect_system_lang() {
    sys_lang="${LANG:-}"
    if [ -z "$sys_lang" ]; then
        sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    fi
    case "$sys_lang" in
        pl*) echo "pl" ;;
        *) echo "en" ;;
    esac
}
SCRIPT_LANG="$(detect_system_lang)"

msg() {
    if [ "$SCRIPT_LANG" = "pl" ]; then
        echo "$1"
    else
        echo "$2"
    fi
}

RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YLW="$(printf '\033[33m')"
BLU="$(printf '\033[34m')"
RST="$(printf '\033[0m')"

info() {
    printf '%s[+]%s ' "$GRN" "$RST"
    msg "$1" "$2"
}

warn() {
    printf '%s[!]%s ' "$YLW" "$RST"
    msg "$1" "$2"
}

die() {
    printf '%s[x]%s ' "$RED" "$RST" >&2
    msg "$1" "$2" >&2
    exit 1
}

[ "$(id -u)" -ne 0 ] || die "Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo." "Do not run this script as root. Run it as a regular user with sudo."
command -v sudo >/dev/null 2>&1 || die "Brak polecenia sudo" "sudo command not found"
[ -d /sys/firmware/efi ] || die "System nie jest uruchomiony w trybie UEFI" "The system is not booted in UEFI mode"

sudo -v

(
    set +e
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done
) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

MISSING=""
for p in sbctl efibootmgr; do
    xbps-query "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
    sudo xbps-install -Sy $MISSING
fi

ESP=""
for d in /boot/efi /efi /boot; do
    if mountpoint -q "$d" && [ "$(findmnt -no FSTYPE "$d")" = "vfat" ]; then
        ESP="$d"
        break
    fi
done
[ -n "$ESP" ] || die "Nie znaleziono partycji ESP" "ESP partition not found"

if ! sudo test -f /var/lib/sbctl/keys/db/db.key && ! sudo test -f /usr/share/secureboot/keys/db/db.key; then
    sudo sbctl create-keys
fi

if command -v grub-install >/dev/null 2>&1; then
    GRUB_DIR="$(sudo find "$ESP/EFI" -iname grubx64.efi 2>/dev/null | head -n1 | xargs -r dirname | xargs -r basename || true)"
    GRUB_ID="${GRUB_DIR:-void}"
    GRUB_MODULES="all_video boot btrfs cat chain configfile cpuid echo efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal part_apple part_gpt part_msdos password_pbkdf2 play png probe reboot regexp search search_fs_file search_fs_uuid search_label sleep smbios squash4 test tpm true video xfs zfs zfscrypt zfsinfo"
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP" --bootloader-id="$GRUB_ID" --modules="$GRUB_MODULES" --disable-shim-lock --recheck
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

{
    sudo find "$ESP/EFI" -mindepth 2 -maxdepth 2 -type f \( -iname grubx64.efi -o -iname systemd-bootx64.efi -o -iname bootx64.efi -o -ipath "$ESP/EFI/Linux/*.efi" \) 2>/dev/null || true
    sudo find /boot -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null || true
} | sort -u | while read -r f; do
    sudo sbctl sign -s "$f" </dev/null
done

sudo mkdir -p /etc/kernel.d/post-install
sudo tee /etc/kernel.d/post-install/99-sbctl >/dev/null <<'EOF'
#!/bin/sh
sbctl sign-all
EOF
sudo chmod 755 /etc/kernel.d/post-install/99-sbctl

if sudo sbctl status 2>/dev/null | grep -i 'Setup Mode' | grep -qi 'enabled'; then
    sudo sbctl enroll-keys --microsoft
else
    warn "Firmware nie jest w trybie Setup Mode. Wejdź do UEFI, wyczyść klucze Secure Boot (Setup Mode), a następnie uruchom: sudo sbctl enroll-keys --microsoft" \
         "Firmware is not in Setup Mode. Enter UEFI, clear the Secure Boot keys (Setup Mode), then run: sudo sbctl enroll-keys --microsoft"
fi

sudo sbctl --esp "$ESP" verify || true
sudo sbctl status || true

info "Gotowe. Uruchom ponownie komputer i włącz Secure Boot w ustawieniach UEFI." \
     "Done. Restart the computer and enable Secure Boot in the UEFI settings."
warn "Po każdej aktualizacji pakietu grub trzeba ponownie uruchomić grub-install i podpisać nowy plik grubx64.efi przez sbctl sign-all." \
     "After every grub package update, you must run grub-install again and sign the new grubx64.efi file with sbctl sign-all."

if [ "$SCRIPT_LANG" = "pl" ]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
printf '%s==> %s%s' "$BLU" "$RESTART_PROMPT" "$RST"
read -r RESTART_CHOICE < /dev/tty || RESTART_CHOICE=""
case "$RESTART_CHOICE" in
    [YyTt]*)
        sudo reboot
        ;;
esac
exit 0
