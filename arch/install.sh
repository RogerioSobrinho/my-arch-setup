#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Automated Installer
# VERSION:      1.4.0 (Final Stable)
# TARGET:       Workstation (Laptop/Desktop) & Gaming
# AUTHOR:       Rogerio Sobrinho (Gemini Reviewed)
# DOCS:         Compliant with Arch Wiki & CIS Benchmarks
# CHANGES:      Merged v1.3 Fixes (GPU/Permissions) with v1.2 Logging Standard
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

# Error trap with line reporting
error_handler() {
    local line_no=$1
    log_error "Script failed at line $line_no. Installation aborted."
}
trap 'error_handler $LINENO' ERR

# --- CONFIGURATION DEFAULTS ---
LOCALE="en_US.UTF-8"
KEYMAP="us-acentos"
TIMEZONE="America/Sao_Paulo"
HOSTNAME_DEFAULT="archlinux"

# --- PACKAGE LISTS ---

# 1. System Core (Hardware support + LVM)
# Note: 'lvm2' is explicitly required for the sd-lvm2 hook
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware)

# 2. System Utilities (Clean CLI stack)
PKGS_SYS=(sudo neovim git man-db pacman-contrib unzip p7zip bat eza btop reflector usbutils ripgrep fd)

# 3. Security & Identity (AppArmor + YubiKey)
PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor)

# 4. Networking
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils)

# 5. Filesystem Support
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g)

# 6. Audio Stack (Pipewire)
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware)

# 7. Printing
PKGS_PRINT=(cups)

# 8. Fonts (Official Repo - No Bloat)
PKGS_FONTS=(
    noto-fonts                  # Fallback
    noto-fonts-emoji            # Emoji support
    ttf-liberation              # Metric-compatible with Arial/Times
    
    # Selected Nerd Fonts (Dev Standard)
    ttf-jetbrains-mono-nerd
    ttf-cascadia-code-nerd
    ttf-hack-nerd
    ttf-firacode-nerd
)

# 9. Applications
PKGS_APPS=(firefox thunderbird)

# 10. Desktop Environments (Clean Profiles)
PKGS_SWAY=(
    sway swaybg swayidle swaylock waybar wofi mako ly 
    polkit-gnome thunar gvfs 
    wezterm grim slurp wl-clipboard brightnessctl pavucontrol network-manager-applet 
    xdg-desktop-portal-wlr
)
PKGS_GNOME=(gnome-shell gdm gnome-console nautilus xdg-desktop-portal-gnome gnome-control-center)
PKGS_KDE=(plasma-desktop sddm dolphin konsole xdg-desktop-portal-kde ark spectacle)

# 11. Gaming Tools (Optional Profile)
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
    
    # Strict detection: Filter only VGA or 3D controllers to avoid false positives
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

# --- PRE-FLIGHT CHECKS ---

pre_flight_checks() {
    [[ $EUID -ne 0 ]] && log_error "This script must be run as root."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_error "System is not booted in UEFI mode."
    
    if ! ping -c 1 archlinux.org &>/dev/null; then
        log_error "No internet connection. Please connect via iwctl or ethernet."
    fi
}

# --- USER INPUT ---

collect_user_input() {
    clear
    echo -e "${BLUE}=== ARCH LINUX INSTALLER V1.4 (FINAL STABLE) ===${NC}"
    
    # Hostname
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_INPUT
    HOSTNAME_VAL=${HOSTNAME_INPUT:-$HOSTNAME_DEFAULT}

    # Disk
    echo ""
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk
    echo ""
    read -r -p "Target Disk (e.g., nvme0n1): " DISK
    TARGET="/dev/$DISK"
    
    [[ ! -b "$TARGET" ]] && log_error "Invalid device: $TARGET"
    
    # NVMe vs SATA partition naming
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"
    P_ROOT="${TARGET}${P_SUF}2"

    # Profiles
    echo ""
    read -r -p "Enable GAMER Profile (Zen Kernel + Drivers)? (y/N): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL_PKG="linux-zen"; HEADER_PKG="linux-zen-headers"
        VMLINUZ="/vmlinuz-linux-zen"; INITRAMFS="/initramfs-linux-zen.img"
        detect_gpu_drivers
    else
        KERNEL_PKG="linux"; HEADER_PKG="linux-headers"
        VMLINUZ="/vmlinuz-linux"; INITRAMFS="/initramfs-linux.img"
        GPU_PKGS=()
    fi

    echo ""; read -r -p "Enable Hibernation (Physical Swap)? (y/N): " OPT_HIBERNATE

    # Desktop Environment
    echo ""; echo "Select Desktop Environment:"
    select opt in "Sway" "Gnome" "KDE"; do
        case $opt in
            "Sway") DE_PKGS=("${PKGS_SWAY[@]}"); DM="ly"; DE_NAME="sway"; break ;;
            "Gnome") DE_PKGS=("${PKGS_GNOME[@]}"); DM="gdm"; DE_NAME="gnome"; break ;;
            "KDE") DE_PKGS=("${PKGS_KDE[@]}"); DM="sddm"; DE_NAME="kde"; break ;;
            *) log_warn "Invalid option." ;;
        esac
    done

    # Credentials
    echo ""; read -r -p "New Username: " USER_NAME
    read -r -s -p "Password: " USER_PASS; echo ""
}

# --- INSTALLATION ROUTINE ---

prepare_storage() {
    log_info "Wiping filesystem signatures on $TARGET..."
    wipefs -af "$TARGET"
    sgdisk -Zo "$TARGET"
    
    log_info "Partitioning (GPT)..."
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    partprobe "$TARGET" && sleep 2

    log_info "Encrypting (LUKS2 + Argon2id)..."
    # Optimization: 4k sector size, disable workqueues for NVMe performance
    cryptsetup luksFormat --type luks2 --sector-size 4096 --verify-passphrase "$P_ROOT"
    cryptsetup open "$P_ROOT" cryptroot \
        --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

    log_info "Configuring LVM..."
    pvcreate /dev/mapper/cryptroot
    vgcreate vg0 /dev/mapper/cryptroot

    if [[ "$OPT_HIBERNATE" == "y" ]]; then
        log_info "Allocating Swap (34GB)..."
        lvcreate -L 34G -n swap vg0; mkswap -L swap /dev/mapper/vg0-swap
        SWAP_DEVICE="/dev/mapper/vg0-swap"
    else
        SWAP_DEVICE=""
    fi

    log_info "Allocating Root..."
    lvcreate -l 100%FREE -n root vg0
    mkfs.ext4 -L arch_root /dev/mapper/vg0-root
    mkfs.fat -F 32 -n EFI "$P_EFI"

    log_info "Mounting volumes..."
    mount /dev/mapper/vg0-root /mnt
    mkdir -p /mnt/boot
    
    # SECURITY FIX: Mount /boot with strict umask (0077) to prevent random seed leakage warning
    log_info "Mounting EFI with strict permissions..."
    mount -o fmask=0077,dmask=0077 "$P_EFI" /mnt/boot
    
    [[ -n "$SWAP_DEVICE" ]] && swapon "$SWAP_DEVICE"
}

install_packages() {
    log_info "Configuring Pacman..."
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    
    log_info "Updating mirrors (Reflector)..."
    reflector --country Brazil --country 'United States' --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    log_info "Bootstrapping system..."
    
    # Array Expansion handling
    FINAL_PKG_LIST=(
        "${PKGS_BASE[@]}" "$KERNEL_PKG" "$HEADER_PKG" ${UCODE_PKG:+"$UCODE_PKG"}
        "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" 
        "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" 
        "${PKGS_APPS[@]}" "${DE_PKGS[@]}"
    )

    if [[ "$OPT_HIBERNATE" != "y" ]]; then
        FINAL_PKG_LIST+=("zram-generator")
    fi

    pacstrap -K /mnt "${FINAL_PKG_LIST[@]}"
    
    log_info "Generating Fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # SECURITY FIX: Ensure fmask/dmask=0077 persists in fstab
    log_info "Hardening Fstab permissions..."
    sed -i 's/fmask=0022/fmask=0077/g' /mnt/etc/fstab || true
    sed -i 's/dmask=0022/dmask=0077/g' /mnt/etc/fstab || true
    # Fallback if genfstab used default vfat options
    if ! grep -q "fmask=0077" /mnt/etc/fstab; then
        sed -i 's/vfat\s*rw,/vfat    rw,fmask=0077,dmask=0077,/' /mnt/etc/fstab
    fi
}

configure_target_system() {
    log_info "Generating internal configuration script..."
    
    cat <<EOF > /mnt/setup_internal.sh
#!/bin/bash
set -euo pipefail

# --- 1. LOCALIZATION ---
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

# --- 2. USER & SECURITY ---
useradd -m -G wheel,video,input,storage -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd

# Sudoers Drop-in (Best Practice)
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# --- 3. GAMING ---
if [ "$OPT_GAME" == "y" ]; then
    echo "Configuring Gaming Stack..."
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm
    # Installs explicit drivers detected from the outside variable
    pacman -S --noconfirm ${PKGS_GAME_TOOLS[@]} ${GPU_PKGS[@]}
fi

# --- 4. SWAY CONFIG ---
if [[ "$DE_NAME" == "sway" ]]; then
    mkdir -p /home/$USER_NAME/.config/sway
    [ ! -f /home/$USER_NAME/.config/sway/config ] && cp /etc/sway/config /home/$USER_NAME/.config/sway/config
    
    # Ensure Autostart for Polkit/Network
    if ! grep -q "polkit-gnome" /home/$USER_NAME/.config/sway/config; then
        echo -e "\n# --- Custom Autostart ---" >> /home/$USER_NAME/.config/sway/config
        echo "exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" >> /home/$USER_NAME/.config/sway/config
        echo "exec nm-applet --indicator" >> /home/$USER_NAME/.config/sway/config
    fi
    chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config
fi

# --- 5. BOOTLOADER & HARDENING ---
bootctl install
UUID_CRYPT=\$(blkid -s UUID -o value $P_ROOT)

# SECURITY: AppArmor enabled, Audit on, Lockdown mode
SEC_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1 apparmor=1 security=apparmor"

# HOOKS: systemd based (sd-encrypt/sd-lvm2)
# FIX: 'sd-lvm2' must be AFTER 'sd-encrypt'
HOOKS="systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt sd-lvm2"

if [ "$OPT_HIBERNATE" == "y" ]; then
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS resume filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root resume=/dev/mapper/vg0-swap rw quiet splash \$SEC_PARAMS"
else
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root rw quiet splash \$SEC_PARAMS"
    
    # ZRAM Config
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

# --- 6. ENABLE SERVICES ---
systemctl enable NetworkManager bluetooth chronyd firewalld fstrim.timer pcscd cups apparmor $DM
echo "vm.swappiness=10" > /etc/sysctl.d/99-ssd.conf

EOF

    chmod +x /mnt/setup_internal.sh
    log_info "Executing chroot configuration..."
    arch-chroot /mnt /setup_internal.sh
    rm /mnt/setup_internal.sh
}

# --- MAIN EXECUTION ---

pre_flight_checks
detect_cpu_microcode
collect_user_input
prepare_storage
install_packages
configure_target_system

echo ""
log_info "=================================================="
log_info " INSTALLATION COMPLETED SUCCESSFULLY"
log_info "=================================================="
log_info " 1. Type 'reboot' to restart."
log_info " 2. SECURE BOOT: Enroll keys with 'sbctl' manually."
log_info "=================================================="
