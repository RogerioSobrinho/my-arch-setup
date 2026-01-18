#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Installer v4.1 (Critical Fixes)
# DESCRIPTION:  Corrected package lists and AUR helper compilation strategy.
# AUTHOR:       Rogerio Sobrinho (Senior Engineer)
# DATE:         2026-01-18
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

# --- CONFIG ---
HOSTNAME_DEFAULT="archlinux"
# Official Repos Only in this list
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware archlinux-keyring linux-lts linux-lts-headers)
PKGS_SYS=(sudo neovim vim git man-db man-pages pacman-contrib fwupd bash-completion fzf fastfetch trash-cli ripgrep fd jq htop ncdu plocate unzip p7zip unrar atool tree rsync wget curl bind reflector restic plymouth)
PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor timeshift earlyoom)
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils openssh avahi)
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g xdg-user-dirs usbutils)
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware pavucontrol)
PKGS_PRINT=(cups)
PKGS_FONTS=(noto-fonts noto-fonts-emoji ttf-liberation ttf-roboto ttf-fira-sans ttf-jetbrains-mono-nerd)
PKGS_APPS=(firefox thunderbird flatpak)
PKGS_DEV=(docker docker-compose docker-buildx)

# Visuals (Official Repos ONLY)
# Removed adwaita-qt5/6 (AUR) from here to avoid pacstrap errors
PKGS_THEMES=(gnome-themes-extra adwaita-icon-theme glib2 qt5-wayland qt6-wayland qt5ct qt6ct)

# Sway (Official Repos)
# Replaced clipman with cliphist
PKGS_SWAY=(sway swaybg swayidle swaylock dmenu ly foot xdg-desktop-portal-wlr xdg-desktop-portal-gtk thunar thunar-volman gvfs tumbler file-roller polkit-gnome gnome-keyring libsecret blueman network-manager-applet zathura zathura-pdf-mupdf imv mpv mako grim slurp cliphist)

# Laptop/Game
PKGS_LAPTOP=(tlp kanshi brightnessctl)
PKGS_GAME=(steam lutris gamemode mangohud wine-staging winetricks openrgb)

# AUR Packages (Installed later via Yay)
PKGS_AUR_LIST="adwaita-qt5 adwaita-qt6"

# --- FUNCTIONS ---

pre_flight() {
    [[ $EUID -ne 0 ]] && log_err "Run as root."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_err "Not UEFI."
    ping -c 1 archlinux.org &>/dev/null || log_err "No Internet."
}

collect_input() {
    clear
    echo -e "${CYAN}=== Arch Installer v4.1 ===${NC}"
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_VAL
    HOSTNAME_VAL=${HOSTNAME_VAL:-$HOSTNAME_DEFAULT}
    
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk
    read -r -p "Target Disk (e.g. nvme0n1): " DISK
    TARGET="/dev/$DISK"
    [[ ! -b "$TARGET" ]] && log_err "Invalid disk."
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"; P_ROOT="${TARGET}${P_SUF}2"

    read -r -p "Gamer Profile? (y/n): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL="linux-zen"; K_HEADERS="linux-zen-headers"
    else
        KERNEL="linux"; K_HEADERS="linux-headers"
    fi
    
    read -r -p "Hibernate? (y/n): " OPT_HIB
    read -r -p "User: " USER_NAME
    read -r -s -p "Pass: " USER_PASS; echo ""
}

prepare_disk() {
    log_info "Wiping $TARGET..."
    wipefs -af "$TARGET"; sgdisk -Zo "$TARGET"
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    
    log_info "Encrypting..."
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
    mkfs.ext4 /dev/mapper/vg0-root
    mkfs.fat -F 32 -n EFI "$P_EFI"

    mount /dev/mapper/vg0-root /mnt
    mkdir -p /mnt/boot
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
    grep -EEq "^(8|9|10|14|31|32)$" /sys/class/dmi/id/chassis_type 2>/dev/null && IS_LAPTOP="true"
}

install_base() {
    log_info "Configuring Pacman..."
    sed -i 's/^#Parallel/Parallel/' /etc/pacman.conf
    # CRITICAL FIX: Enable Multilib on HOST before pacstrap
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Syy --noconfirm

    detect_hw
    
    PKG_LIST=("${PKGS_BASE[@]}" "$KERNEL" "$K_HEADERS" "$UCODE" "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" "${PKGS_APPS[@]}" "${PKGS_DEV[@]}" "${PKGS_THEMES[@]}" "${PKGS_SWAY[@]}" "${GPU_PKGS[@]}")
    
    [[ "$IS_LAPTOP" == "true" ]] && PKG_LIST+=("${PKGS_LAPTOP[@]}")
    [[ "$OPT_GAME" == "y" ]] && PKG_LIST+=("${PKGS_GAME[@]}")
    [[ "$OPT_HIB" != "y" ]] && PKG_LIST+=("zram-generator")

    log_info "Pacstrap..."
    pacstrap -K /mnt "${PKG_LIST[@]}"
    genfstab -U /mnt >> /mnt/etc/fstab
}

config_system() {
    cat <<EOF > /mnt/setup.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us-intl" > /etc/vconsole.conf
echo "$HOSTNAME_VAL" > /etc/hostname

# Enable Multilib inside target
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
sed -i 's/^#Parallel/Parallel/' /etc/pacman.conf

useradd -m -G wheel,video,storage,docker -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Bootloader
bootctl install
sed -i 's/^HOOKS=.*/HOOKS=(systemd sd-plymouth autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "title Arch Linux" > /boot/loader/entries/arch.conf
echo "linux /vmlinuz-$KERNEL" >> /boot/loader/entries/arch.conf
echo "initrd /$UCODE.img" >> /boot/loader/entries/arch.conf
echo "initrd /initramfs-$KERNEL.img" >> /boot/loader/entries/arch.conf
echo "options rd.luks.name=\$(blkid -s UUID -o value $P_ROOT)=cryptroot root=/dev/mapper/vg0-root rw quiet splash" >> /boot/loader/entries/arch.conf

echo "default arch.conf" > /boot/loader/loader.conf

# Services
systemctl enable NetworkManager bluetooth cronie firewalld apparmor docker fstrim.timer reflector.timer
[[ "$IS_LAPTOP" == "true" ]] && systemctl enable tlp
systemctl enable ly

# AUR HELPER (YAY) - Building from source to avoid libalpm error
echo "Building Yay..."
su - $USER_NAME <<AUR
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay

# Install AUR Themes
echo "Installing AUR Themes..."
yay -S --noconfirm $PKGS_AUR_LIST
AUR

# Sway Config
mkdir -p /home/$USER_NAME/.config/sway
cat <<SWAY > /home/$USER_NAME/.config/sway/config
# Include default config
include /etc/sway/config
set \\\$mod Mod4
set \\\$term foot
set \\\$menu dmenu_path | dmenu | xargs swaymsg exec --

exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec nm-applet --indicator
exec blueman-applet
exec mako
exec wl-paste --watch cliphist store

# Themes
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
SWAY
chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config

EOF
    chmod +x /mnt/setup.sh
    arch-chroot /mnt /setup.sh
}

# --- EXECUTION ---
pre_flight
collect_input
prepare_disk
install_base
config_system
log_succ "Done! Reboot now."
