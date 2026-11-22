#!/bin/sh
set -eu

detect_system_lang() {
    sys_lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    sys_lang="$(printf '%s' "$sys_lang" | tr -d "\"'")"
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

SUDO_KEEPALIVE_PID=""
FILES_TMP=""

cleanup() {
    if [ -n "$SUDO_KEEPALIVE_PID" ]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    if [ -n "$FILES_TMP" ]; then
        rm -f "$FILES_TMP" 2>/dev/null || true
    fi
    sudo -k 2>/dev/null || true
}
trap cleanup EXIT

(
    set +e
    while kill -0 "$$" 2>/dev/null; do
        sleep 50
        kill -0 "$$" 2>/dev/null || exit 0
        sudo -n -v 2>/dev/null || exit 0
    done
) </dev/null >/dev/null 2>&1 &
SUDO_KEEPALIVE_PID=$!

MISSING=""
for p in sbctl efibootmgr; do
    xbps-query "$p" >/dev/null 2>&1 || MISSING="${MISSING:+$MISSING }$p"
done
if [ -n "$MISSING" ]; then
    sudo xbps-install -Syu xbps
    sudo xbps-install -Syu $MISSING
fi

ESP=""
for d in /boot/efi /efi /boot; do
    if mountpoint -q "$d" && findmnt -M "$d" -no FSTYPE 2>/dev/null | grep -qxE 'vfat|msdos'; then
        ESP="$d"
        break
    fi
done
[ -n "$ESP" ] || die "Nie znaleziono partycji ESP" "ESP partition not found"

if ! sudo test -f /var/lib/sbctl/keys/db/db.key && ! sudo test -f /usr/share/secureboot/keys/db/db.key; then
    sudo env ESP_PATH="$ESP" sbctl create-keys
fi

GRUB_USED=0
GRUB_EFI_PATH="$(sudo find "$ESP/EFI" -mindepth 2 -maxdepth 2 -type f -iname grubx64.efi ! -ipath "$ESP/EFI/BOOT/*" 2>/dev/null | head -n1 || true)"
if command -v grub-install >/dev/null 2>&1 && { [ -n "$GRUB_EFI_PATH" ] || [ -f /boot/grub/grub.cfg ]; }; then
    GRUB_USED=1
    if [ -n "$GRUB_EFI_PATH" ]; then
        GRUB_PARENT="${GRUB_EFI_PATH%/*}"
        GRUB_ID="${GRUB_PARENT##*/}"
    else
        GRUB_ID="void_grub"
    fi
    GRUB_MOD_DIR="/usr/lib/grub/x86_64-efi"
    WANTED_MODULES="all_video boot btrfs cat chain configfile cpuid cryptodisk diskfilter echo efinet ext2 f2fs fat font gcry_rijndael gcry_sha256 gcry_sha512 gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal luks luks2 lvm mdraid09 mdraid1x memdisk minicmd normal part_apple part_gpt part_msdos password_pbkdf2 pbkdf2 play png probe reboot regexp search search_fs_file search_fs_uuid search_label sleep smbios squash4 test tpm true video xfs zfs zfscrypt zfsinfo"
    GRUB_MODULES=""
    if [ -d "$GRUB_MOD_DIR" ]; then
        for m in $WANTED_MODULES; do
            if [ -f "$GRUB_MOD_DIR/$m.mod" ]; then
                GRUB_MODULES="${GRUB_MODULES:+$GRUB_MODULES }$m"
            fi
        done
    else
        GRUB_MODULES="$WANTED_MODULES"
    fi
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP" --bootloader-id="$GRUB_ID" --modules="$GRUB_MODULES" --disable-shim-lock --recheck
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

FILES_TMP="$(mktemp)"
{
    sudo find "$ESP/EFI" -mindepth 2 -maxdepth 2 -type f \
        ! -ipath "$ESP/EFI/Microsoft/*" \
        \( -iname grubx64.efi -o -iname systemd-bootx64.efi -o -ipath "$ESP/EFI/Linux/*.efi" \) 2>/dev/null || true
    sudo find "$ESP/EFI/BOOT" -maxdepth 1 -type f -iname bootx64.efi 2>/dev/null | while IFS= read -r boot_efi; do
        [ -n "$boot_efi" ] || continue
        if sudo grep -aqiE 'GRUB|systemd-boot' "$boot_efi" 2>/dev/null; then
            printf '%s\n' "$boot_efi"
        fi
    done || true
    sudo find /boot -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null || true
} | sort -u > "$FILES_TMP"

SIGNED_COUNT=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    sudo env ESP_PATH="$ESP" sbctl sign -s "$f" </dev/null
    SIGNED_COUNT=$((SIGNED_COUNT + 1))
done < "$FILES_TMP"

[ "$SIGNED_COUNT" -gt 0 ] || die "Nie znaleziono żadnych plików EFI ani jąder do podpisania – przerywam przed wgraniem kluczy." "No EFI binaries or kernels found to sign - aborting before enrolling keys."

sudo mkdir -p /etc/kernel.d/post-install /etc/kernel.d/post-remove
sudo tee /etc/kernel.d/post-install/99-sbctl >/dev/null <<'EOF'
#!/bin/sh
command -v sbctl >/dev/null 2>&1 || exit 0
if [ -n "${2:-}" ] && [ -f "/boot/vmlinuz-$2" ]; then
    sbctl sign -s "/boot/vmlinuz-$2"
fi
sbctl sign-all
EOF
sudo chmod 755 /etc/kernel.d/post-install/99-sbctl

sudo tee /etc/kernel.d/post-remove/99-sbctl >/dev/null <<'EOF'
#!/bin/sh
command -v sbctl >/dev/null 2>&1 || exit 0
if [ -n "${2:-}" ]; then
    sbctl remove-file "/boot/vmlinuz-$2" >/dev/null 2>&1 || true
fi
EOF
sudo chmod 755 /etc/kernel.d/post-remove/99-sbctl

SBCTL_STATUS="$(sudo env LC_ALL=C ESP_PATH="$ESP" sbctl status 2>/dev/null || true)"
if printf '%s\n' "$SBCTL_STATUS" | grep -i 'Setup Mode' | grep -qi 'enabled'; then
    sudo env ESP_PATH="$ESP" sbctl enroll-keys --microsoft
elif printf '%s\n' "$SBCTL_STATUS" | grep -i 'Secure Boot' | grep -qi 'enabled'; then
    info "Secure Boot jest już włączony – pomijam wgrywanie kluczy." \
         "Secure Boot is already enabled - skipping key enrollment."
else
    warn "Firmware nie jest w trybie Setup Mode. Jeśli klucze sbctl nie zostały jeszcze wgrane, wejdź do UEFI, wyczyść klucze Secure Boot (Setup Mode), a następnie uruchom: sudo sbctl enroll-keys --microsoft" \
         "Firmware is not in Setup Mode. If sbctl keys have not been enrolled yet, enter UEFI, clear the Secure Boot keys (Setup Mode), then run: sudo sbctl enroll-keys --microsoft"
fi

sudo env ESP_PATH="$ESP" sbctl verify || true
sudo env ESP_PATH="$ESP" sbctl status || true

info "Gotowe. Uruchom ponownie komputer i włącz Secure Boot w ustawieniach UEFI." \
     "Done. Restart the computer and enable Secure Boot in the UEFI settings."
if [ "$GRUB_USED" -eq 1 ]; then
    warn "Po każdej aktualizacji pakietu grub trzeba ponownie uruchomić grub-install i podpisać nowy plik grubx64.efi przez sbctl sign-all." \
         "After every grub package update, you must run grub-install again and sign the new grubx64.efi file with sbctl sign-all."
fi

if [ "$SCRIPT_LANG" = "pl" ]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
printf '%s==> %s%s' "$BLU" "$RESTART_PROMPT" "$RST"
if [ -r /dev/tty ]; then
    read -r RESTART_CHOICE < /dev/tty || RESTART_CHOICE=""
else
    read -r RESTART_CHOICE || RESTART_CHOICE=""
fi
case "$RESTART_CHOICE" in
    [YyTt]*)
        sudo reboot
        ;;
esac
exit 0
