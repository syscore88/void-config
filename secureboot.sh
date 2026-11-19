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

die() {
    msg "$1" "$2" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Uruchom skrypt jako root" "Run the script as root"
[ -d /sys/firmware/efi ] || die "System nie jest uruchomiony w trybie UEFI" "The system is not booted in UEFI mode"

xbps-install -Sy sbctl efibootmgr

ESP=""
for d in /boot/efi /efi /boot; do
    if mountpoint -q "$d" && [ "$(findmnt -no FSTYPE "$d")" = "vfat" ]; then
        ESP="$d"
        break
    fi
done
[ -n "$ESP" ] || die "Nie znaleziono partycji ESP" "ESP partition not found"

if [ ! -f /var/lib/sbctl/keys/db/db.key ] && [ ! -f /usr/share/secureboot/keys/db/db.key ]; then
    sbctl create-keys
fi

if command -v grub-install >/dev/null 2>&1; then
    GRUB_DIR="$(find "$ESP/EFI" -iname grubx64.efi 2>/dev/null | head -n1 | xargs -r dirname | xargs -r basename || true)"
    GRUB_ID="${GRUB_DIR:-void}"
    GRUB_MODULES="all_video boot btrfs cat chain configfile cpuid echo efifwrw efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal part_apple part_gpt part_msdos password_pbkdf2 play png probe reboot regexp search search_fs_file search_fs_uuid search_label sleep smbios squash4 test tpm true video xfs zfs zfscrypt zfsinfo"
    grub-install --target=x86_64-efi --efi-directory="$ESP" --bootloader-id="$GRUB_ID" --modules="$GRUB_MODULES" --disable-shim-lock --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
fi

for f in \
    "$ESP"/EFI/*/grubx64.efi \
    "$ESP"/EFI/*/systemd-bootx64.efi \
    "$ESP"/EFI/BOOT/BOOTX64.EFI \
    "$ESP"/EFI/BOOT/bootx64.efi \
    "$ESP"/EFI/Linux/*.efi \
    /boot/vmlinuz-*
do
    [ -f "$f" ] && sbctl sign -s "$f"
done

mkdir -p /etc/kernel.d/post-install
cat > /etc/kernel.d/post-install/99-sbctl <<'EOF'
#!/bin/sh
sbctl sign-all
EOF
chmod 755 /etc/kernel.d/post-install/99-sbctl

if sbctl status 2>/dev/null | grep -i 'Setup Mode' | grep -qi 'enabled'; then
    sbctl enroll-keys --microsoft
else
    msg "Firmware nie jest w trybie Setup Mode. Wejdź do UEFI, wyczyść klucze Secure Boot (Setup Mode), a następnie uruchom: sbctl enroll-keys --microsoft" \
        "Firmware is not in Setup Mode. Enter UEFI, clear the Secure Boot keys (Setup Mode), then run: sbctl enroll-keys --microsoft"
fi

sbctl verify || true
sbctl status || true

msg "Gotowe. Uruchom ponownie komputer i włącz Secure Boot w ustawieniach UEFI." \
    "Done. Restart the computer and enable Secure Boot in the UEFI settings."
msg "Po każdej aktualizacji pakietu grub trzeba ponownie uruchomić grub-install i podpisać nowy plik grubx64.efi przez sbctl sign-all." \
    "After every grub package update, you must run grub-install again and sign the new grubx64.efi file with sbctl sign-all."
