#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Installer v1.5 (Final Release)
# TARGET:       Workstation & Gaming
# AUTHOR:       Rogerio Sobrinho (Reviewed by Gemini)
# CHANGES:      Fixed mkinitcpio hooks (lvm2), /boot permissions, strict GPU detect
# ==============================================================================

# --- STRICT MODE ---
set -euo pipefail
IFS=$'\n\t'

# --- LOGGING INFRASTRUCTURE ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[$(date +'%H:%M:%S')] [INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] [WARN]${NC} $1"; }
log_error() { echo -e "${RED}[$(date +'%H:%M:%S')] [ERROR]${NC} $1" >&2; exit 1; }

error_handler() {
    local line_no=$1
    log_error "Script failed at line $line_no. Installation aborted."
}
trap 'error_handler $LINENO' ERR

# --- CONFIG DEFAULTS ---
LOCALE="en_US.UTF-8"
KEYMAP="us-acentos"
TIMEZONE="America/Sao_Paulo"
HOSTNAME_DEFAULT="archlinux"

# --- PACKAGE LISTS ---

# Core: lvm2 required for hooks, sof-firmware for audio
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware)

# Utils: Clean stack
PKGS_SYS=(sudo neovim git man-db pacman-contrib unzip p7zip bat eza btop reflector usbutils ripgrep fd)

# Security: AppArmor + YubiKey
PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor)

# Network
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils)

# Filesystem
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g)

# Audio
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware)

# Print
PKGS_PRINT=(cups)

# Fonts (Official Nerd Fonts)
PKGS_FONTS=(
    noto-fonts noto-fonts-emoji ttf-liberation
    ttf-jetbrains-mono-nerd ttf-cascadia-code-nerd ttf-hack-nerd ttf-firacode-nerd
)

# Apps
PKGS_APPS=(firefox thunderbird)

# DE Profiles
PKGS_SWAY=(
    sway swaybg swayidle swaylock waybar wofi mako ly 
    polkit-gnome thunar gvfs 
    wezterm grim slurp wl-clipboard brightnessctl pavucontrol network-manager-applet 
    xdg-desktop-portal-wlr
)
PKGS_GNOME=(gnome-shell gdm gnome-console nautilus xdg-desktop-portal-gnome gnome-control-center)
PKGS_KDE=(plasma-desktop sddm dolphin konsole xdg-desktop-portal-kde ark spectacle)

# Gaming
PKGS_GAME_TOOLS=(steam lutris gamemode mangohud wine-staging winetricks)

# --- HARDWARE DETECTION ---

detect_cpu_microcode() {
    log_info "Detecting CPU Vendor..."
    local cpu_vendor
    cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        log_info "Intel CPU detected. Staging intel-ucode."
        UCODE_PKG="intel-ucode"
        UCODE_IMG="/intel-ucode.img"
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        log_info "AMD CPU detected. Staging amd-ucode."
        UCODE_PKG="amd-ucode"
        UCODE_IMG="/amd-ucode.img"
    else
        log_warn "Unknown CPU vendor. Skipping microcode."
        UCODE_PKG=""
        UCODE_IMG=""
    fi
}

detect_gpu_drivers() {
    log_info "Scanning PCI bus for GPUs..."
    GPU_PKGS=()
    local gpu_info
    gpu_info=$(lspci -mm | grep -E "VGA|3D")

    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        log_info "NVIDIA GPU detected. Adding proprietary DKMS drivers."
        GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings)
    elif echo "$gpu_info" | grep -iq "AMD"; then
        log_info "AMD GPU detected. Adding Mesa/Vulkan stack."
        GPU_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu)
    elif echo "$gpu_info" | grep -iq "Intel"; then
        log_info "Intel GPU detected. Adding Mesa/Vulkan stack."
        GPU_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel)
    else
        log_warn "No discrete GPU detected. Fallback to generic Mesa."
        GPU_PKGS+=(mesa lib32-mesa)
    fi
}

# --- PRE-FLIGHT ---

pre_flight_checks() {
    [[ $EUID -ne 0 ]] && log_error "Run as root."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_error "Not in UEFI mode."
    if ! ping -c 1 archlinux.org &>/dev/null; then
        log_error "No internet. Connect via iwctl/ethernet."
    fi
}

# --- INPUT ---

collect_user_input() {
    clear
    echo -e "${BLUE}=== ARCH LINUX INSTALLER V1.5 ===${NC}"
    
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_INPUT
    HOSTNAME_VAL=${HOSTNAME_INPUT:-$HOSTNAME_DEFAULT}

    echo ""; lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk; echo ""
    read -r -p "Target Disk (e.g., nvme0n1): " DISK
    TARGET="/dev/$DISK"
    [[ ! -b "$TARGET" ]] && log_error "Invalid device."
    
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"
    P_ROOT="${TARGET}${P_SUF}2"

    echo ""; read -r -p "Enable GAMER Profile (Zen Kernel + Drivers)? (y/N): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL_PKG="linux-zen"; HEADER_PKG="linux-zen-headers"
        VMLINUZ="/vmlinuz-linux-zen"; INITRAMFS="/initramfs-linux-zen.img"
        detect_gpu_drivers
    else
        KERNEL_PKG="linux"; HEADER_PKG="linux-headers"
        VMLINUZ="/vmlinuz-linux"; INITRAMFS="/initramfs-linux.img"
        GPU_PKGS=()
    fi

    echo ""; read -r -p "Enable Hibernation? (y/N): " OPT_HIBERNATE

    echo ""; echo "Select DE:"
    select opt in "Sway" "Gnome" "KDE"; do
        case $opt in
            "Sway") DE_PKGS=("${PKGS_SWAY[@]}"); DM="ly"; DE_NAME="sway"; break ;;
            "Gnome") DE_PKGS=("${PKGS_GNOME[@]}"); DM="gdm"; DE_NAME="gnome"; break ;;
            "KDE") DE_PKGS=("${PKGS_KDE[@]}"); DM="sddm"; DE_NAME="kde"; break ;;
            *) log_warn "Invalid." ;;
        esac
    done

    echo ""; read -r -p "Username: " USER_NAME
    read -r -s -p "Password: " USER_PASS; echo ""
}

# --- INSTALL ---

prepare_storage() {
    log_info "Wiping $TARGET..."
    wipefs -af "$TARGET"
    sgdisk -Zo "$TARGET"
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    partprobe "$TARGET" && sleep 2

    log_info "Encrypting (LUKS2/Argon2id)..."
    cryptsetup luksFormat --type luks2 --sector-size 4096 --verify-passphrase "$P_ROOT"
    cryptsetup open "$P_ROOT" cryptroot \
        --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

    log_info "LVM Setup..."
    pvcreate /dev/mapper/cryptroot
    vgcreate vg0 /dev/mapper/cryptroot

    if [[ "$OPT_HIBERNATE" == "y" ]]; then
        lvcreate -L 34G -n swap vg0; mkswap -L swap /dev/mapper/vg0-swap
        SWAP_DEVICE="/dev/mapper/vg0-swap"
    else
        SWAP_DEVICE=""
    fi

    lvcreate -l 100%FREE -n root vg0
    mkfs.ext4 -L arch_root /dev/mapper/vg0-root
    mkfs.fat -F 32 -n EFI "$P_EFI"

    log_info "Mounting..."
    mount /dev/mapper/vg0-root /mnt
    mkdir -p /mnt/boot
    # SECURE MOUNT
    mount -o fmask=0077,dmask=0077 "$P_EFI" /mnt/boot
    [[ -n "$SWAP_DEVICE" ]] && swapon "$SWAP_DEVICE"
}

install_packages() {
    log_info "Configuring Pacman..."
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    reflector --country Brazil --country 'United States' --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    log_info "Bootstrapping..."
    FINAL_PKG_LIST=(
        "${PKGS_BASE[@]}" "$KERNEL_PKG" "$HEADER_PKG" ${UCODE_PKG:+"$UCODE_PKG"}
        "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" 
        "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" 
        "${PKGS_APPS[@]}" "${DE_PKGS[@]}"
    )
    [[ "$OPT_HIBERNATE" != "y" ]] && FINAL_PKG_LIST+=("zram-generator")

    pacstrap -K /mnt "${FINAL_PKG_LIST[@]}"
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # Permission hardening
    sed -i 's/fmask=0022/fmask=0077/g' /mnt/etc/fstab || true
    sed -i 's/dmask=0022/dmask=0077/g' /mnt/etc/fstab || true
}

configure_target_system() {
    log_info "Configuring internal system..."
    
    cat <<EOF > /mnt/setup_internal.sh
#!/bin/bash
set -euo pipefail

# Locale/Time
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen; locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME_VAL" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_VAL.localdomain $HOSTNAME_VAL
HOSTS

sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Users
useradd -m -G wheel,video,input,storage -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# Gaming
if [ "$OPT_GAME" == "y" ]; then
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm
    pacman -S --noconfirm ${PKGS_GAME_TOOLS[@]} ${GPU_PKGS[@]}
fi

# Sway
if [[ "$DE_NAME" == "sway" ]]; then
    mkdir -p /home/$USER_NAME/.config/sway
    [ ! -f /home/$USER_NAME/.config/sway/config ] && cp /etc/sway/config /home/$USER_NAME/.config/sway/config
    if ! grep -q "polkit-gnome" /home/$USER_NAME/.config/sway/config; then
        echo -e "\nexec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" >> /home/$USER_NAME/.config/sway/config
        echo "exec nm-applet --indicator" >> /home/$USER_NAME/.config/sway/config
    fi
    chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config
fi

# Bootloader
bootctl install
UUID_CRYPT=\$(blkid -s UUID -o value $P_ROOT)
SEC_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1 apparmor=1 security=apparmor"

# HOOK FIX: lvm2 replaced sd-lvm2
HOOKS="systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2"

if [ "$OPT_HIBERNATE" == "y" ]; then
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS resume filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root resume=/dev/mapper/vg0-swap rw quiet splash \$SEC_PARAMS"
else
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root rw quiet splash \$SEC_PARAMS"
    echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
fi

mkinitcpio -P

cat > /boot/loader/loader.conf <<LCONF
default arch.conf
timeout 2
console-mode max
editor no
LCONF

INITRD_UCODE=""
[ -n "$UCODE_IMG" ] && INITRD_UCODE="initrd $UCODE_IMG"

cat > /boot/loader/entries/arch.conf <<LENTRY
title   Arch Linux
linux   $VMLINUZ
\$INITRD_UCODE
initrd  $INITRAMFS
options \$CMDLINE
LENTRY

# Services
systemctl enable NetworkManager bluetooth chronyd firewalld fstrim.timer pcscd cups apparmor $DM
echo "vm.swappiness=10" > /etc/sysctl.d/99-ssd.conf

EOF

    chmod +x /mnt/setup_internal.sh
    log_info "Running chroot setup..."
    arch-chroot /mnt /setup_internal.sh
    rm /mnt/setup_internal.sh
}

# --- MAIN ---
pre_flight_checks
detect_cpu_microcode
collect_user_input
prepare_storage
install_packages
configure_target_system

echo ""
log_info "DONE. Type 'reboot'."
