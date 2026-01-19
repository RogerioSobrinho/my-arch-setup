#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Installer v5.4 (Stable/Udev/Ly-Template/Verbose)
# DESCRIPTION:  Official Repos. Hooks: Udev. Ly: TTY Template. PkgList: On.
# TARGET:       Workstation & Gaming
# AUTHOR:       Rogerio Sobrinho (Refactored by Gemini)
# DATE:         2026-01-19
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_succ() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_err()  { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
trap 'log_err "Script failed at line $LINENO"' ERR

# --- CONFIG ---
HOSTNAME_DEFAULT="archlinux"
KEYMAP="us-intl"
FONT_CONSOLE="latarcyrheb-sun16" 

# --- PACKAGES ---
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware archlinux-keyring linux-lts linux-lts-headers)

PKGS_SYS=(
    sudo neovim vim git man-db man-pages pacman-contrib fwupd 
    bash-completion fzf fastfetch trash-cli ripgrep fd jq
    htop ncdu plocate unzip p7zip unrar atool tree
    rsync wget curl bind restic
)

PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor timeshift earlyoom)
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils openssh avahi)
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g xdg-user-dirs usbutils)
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware pavucontrol)
PKGS_PRINT=(cups)
PKGS_FONTS=(noto-fonts noto-fonts-emoji ttf-liberation ttf-roboto ttf-fira-sans ttf-jetbrains-mono-nerd)
PKGS_APPS=(firefox thunderbird flatpak)
PKGS_DEV=(docker docker-compose docker-buildx)
PKGS_THEMES_GLOBAL=(gnome-themes-extra adwaita-icon-theme glib2)

# Sway Profile
PKGS_SWAY=(
    sway swaybg swayidle swaylock dmenu ly foot 
    xdg-desktop-portal-wlr xdg-desktop-portal-gtk 
    thunar thunar-volman gvfs tumbler file-roller 
    polkit-gnome gnome-keyring libsecret 
    blueman network-manager-applet 
    zathura zathura-pdf-mupdf imv mpv 
    mako grim slurp cliphist
    xorg-xwayland
    qt5-wayland qt6-wayland qt5ct qt6ct
    gsettings-desktop-schemas
)

PKGS_GNOME=(gnome-shell gdm gnome-console nautilus xdg-desktop-portal-gnome gnome-control-center)
PKGS_KDE=(plasma-desktop sddm dolphin konsole xdg-desktop-portal-kde ark spectacle)
PKGS_LAPTOP=(tlp kanshi brightnessctl)
PKGS_GAME=(steam lutris gamemode mangohud wine-staging winetricks openrgb)

# --- FUNCTIONS ---

pre_flight() {
    [[ $EUID -ne 0 ]] && log_err "Run as ROOT."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_err "UEFI Required."
    ping -c 1 archlinux.org &>/dev/null || log_err "No Internet."
}

collect_input() {
    clear
    echo -e "${CYAN}=== Arch Installer v5.4 (Fixed) ===${NC}"
    
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_VAL
    HOSTNAME_VAL=${HOSTNAME_VAL:-$HOSTNAME_DEFAULT}
    
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk
    echo ""
    read -r -p "Target Disk (e.g., nvme0n1): " DISK
    TARGET="/dev/$DISK"
    
    [[ ! -b "$TARGET" ]] && log_err "Invalid disk."
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"; P_ROOT="${TARGET}${P_SUF}2"

    read -r -p "Gamer Profile (Zen Kernel)? (y/n): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL="linux-zen"; K_HEADERS="linux-zen-headers"
    else
        KERNEL="linux"; K_HEADERS="linux-headers"
    fi
    
    read -r -p "Hibernate (Disk Swap)? (y/n): " OPT_HIB
    
    echo "Select Desktop:"
    select opt in "Sway" "Gnome" "KDE"; do
        case $opt in
            "Sway") DE_PKGS=("${PKGS_SWAY[@]}"); DM="ly"; DE_NAME="sway"; break ;;
            "Gnome") DE_PKGS=("${PKGS_GNOME[@]}"); DM="gdm"; DE_NAME="gnome"; break ;;
            "KDE") DE_PKGS=("${PKGS_KDE[@]}"); DM="sddm"; DE_NAME="kde"; break ;;
            *) echo "Invalid." ;;
        esac
    done

    read -r -p "User: " USER_NAME
    read -r -s -p "Pass: " USER_PASS; echo ""
}

prepare_disk() {
    log_info "Wiping $TARGET..."
    wipefs -af "$TARGET"; sgdisk -Zo "$TARGET"
    
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    sleep 2
    
    log_info "Encrypting (LUKS2)..."
    echo -n "$USER_PASS" | cryptsetup luksFormat --type luks2 --sector-size 4096 -d - "$P_ROOT"
    echo -n "$USER_PASS" | cryptsetup open -d - "$P_ROOT" cryptroot --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

    pvcreate /dev/mapper/cryptroot; vgcreate vg0 /dev/mapper/cryptroot
    
    if [[ "$OPT_HIB" == "y" ]]; then
        lvcreate -L 34G -n swap vg0; mkswap /dev/mapper/vg0-swap
        SWAP_DEV="/dev/mapper/vg0-swap"
    else
        SWAP_DEV=""
    fi
    
    lvcreate -l 100%FREE -n root vg0
    mkfs.ext4 /dev/mapper/vg0-root; mkfs.fat -F 32 -n EFI "$P_EFI"

    mount /dev/mapper/vg0-root /mnt; mkdir -p /mnt/boot
    mount -o fmask=0077,dmask=0077 "$P_EFI" /mnt/boot
    [[ -n "$SWAP_DEV" ]] && swapon "$SWAP_DEV"
}

detect_hw() {
    CPU_V=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    [[ "$CPU_V" == "GenuineIntel" ]] && UCODE="intel-ucode" || UCODE="amd-ucode"
    
    GPU_PKGS=()
    if lspci | grep -qi "NVIDIA"; then GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils); fi
    if lspci | grep -qi "AMD"; then GPU_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon); fi
    if lspci | grep -qi "Intel"; then GPU_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel); fi
    
    IS_LAPTOP="false"
    if grep -EEq "^(8|9|10|14|31|32)$" /sys/class/dmi/id/chassis_type 2>/dev/null; then
        IS_LAPTOP="true"
    fi
}

install_base() {
    log_info "Pacman Config & Install..."
    sed -i 's/^#Parallel/Parallel/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf # Added
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy
    
    detect_hw
    
    PKG_LIST=(
        "${PKGS_BASE[@]}" "$KERNEL" "$K_HEADERS" "$UCODE" 
        "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" 
        "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" 
        "${PKGS_APPS[@]}" "${PKGS_DEV[@]}" "${PKGS_THEMES_GLOBAL[@]}"
        "${DE_PKGS[@]}" "${GPU_PKGS[@]}"
    )
    
    [[ "$IS_LAPTOP" == "true" ]] && PKG_LIST+=("${PKGS_LAPTOP[@]}")
    [[ "$OPT_GAME" == "y" ]] && PKG_LIST+=("${PKGS_GAME[@]}")
    [[ "$OPT_HIB" != "y" ]] && PKG_LIST+=("zram-generator")

    pacstrap -K /mnt "${PKG_LIST[@]}"
    genfstab -U /mnt >> /mnt/etc/fstab
}

config_system() {
    log_info "Configuring System..."
    LUKSUUID=$(blkid -s UUID -o value "$P_ROOT")

    cat <<EOF > /mnt/setup.sh
#!/bin/bash
set -e

# Time & Locale
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME_VAL" > /etc/hostname

# VConsole
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "FONT=$FONT_CONSOLE" >> /etc/vconsole.conf

# Repos & Users
sed -i 's/^#Parallel/Parallel/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf # Added
cat >> /etc/pacman.conf <<PAC
[multilib]
Include = /etc/pacman.d/mirrorlist
PAC
pacman -Sy

useradd -m -G wheel,video,storage,docker -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# ZRAM Config
if pacman -Q zram-generator &>/dev/null; then
    echo -e "[zram0]\nzram-size = min(ram, 8192)" > /etc/systemd/zram-generator.conf
fi

# --- Desktop Config ---
if [[ "$DE_NAME" == "sway" ]]; then
    cat > /etc/environment <<ENV
QT_QPA_PLATFORM=wayland
MOZ_ENABLE_WAYLAND=1
_JAVA_AWT_WM_NONREPARENTING=1
GTK_THEME=Adwaita:dark
QT_QPA_PLATFORMTHEME=qt5ct
ENV

    mkdir -p /home/$USER_NAME/.config/sway
    if [ ! -f /home/$USER_NAME/.config/sway/config ]; then
        cp /etc/sway/config /home/$USER_NAME/.config/sway/config
        cat <<SWAYCONF >> /home/$USER_NAME/.config/sway/config
# Installer Overrides
set \\\$term foot
set \\\$menu dmenu_path | dmenu | xargs swaymsg exec --
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec nm-applet --indicator
exec blueman-applet
exec mako
exec wl-paste --watch cliphist store
exec gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
SWAYCONF
        if [ "$IS_LAPTOP" == "true" ]; then
             echo "exec kanshi" >> /home/$USER_NAME/.config/sway/config
        fi
    fi
    chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config
fi

# --- Bootloader & Initramfs ---
bootctl install

# HOOKS: Udev standard
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Loader Entry
cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-$KERNEL
initrd /$UCODE.img
initrd /initramfs-$KERNEL.img
options rd.luks.name=$LUKSUUID=cryptroot root=/dev/mapper/vg0-root rw quiet
ENTRY
echo "default arch.conf" > /boot/loader/loader.conf

# Services
systemctl enable NetworkManager bluetooth firewalld apparmor docker fstrim.timer
[[ "$IS_LAPTOP" == "true" ]] && systemctl enable tlp

if [[ "$DM" == "ly" ]]; then
    systemctl disable getty@tty2.service
    systemctl enable ly@tty2.service
else
    systemctl enable "$DM"
fi

EOF
    chmod +x /mnt/setup.sh
    arch-chroot /mnt /setup.sh
    rm /mnt/setup.sh
}

# --- EXECUTION ---
pre_flight
collect_input
prepare_disk
install_base
config_system
log_succ "DONE. Remove USB and Reboot."
