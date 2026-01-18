#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Installer v3.8 (Detailed Golden Master)
# DESCRIPTION:  Automated, encrypted, hardware-aware Arch Linux installation.
# TARGET:       Workstation (Laptop/Desktop) & Gaming
# AUTHOR:       Rogerio Sobrinho (Reviewed by Gemini AI)
# DATE:         2026-01-18
# CHANGES:      Added VerbosePkgLists for detailed pacman output
# ==============================================================================

# --- STRICT MODE ---
set -euo pipefail
IFS=$'\n\t'

# --- LOGGING INFRASTRUCTURE ---
# High contrast colors for dark terminals
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

timestamp() { date +'%H:%M:%S'; }

log_info()  { echo -e "${CYAN}[$(timestamp)] [INFO]${NC} $1"; }
log_succ()  { echo -e "${GREEN}[$(timestamp)] [OK]${NC}   $1"; }
log_warn()  { echo -e "${YELLOW}[$(timestamp)] [WARN]${NC} $1"; }
log_step()  { echo -e "\n${MAGENTA}[$(timestamp)] === $1 ===${NC}"; }
log_error() { echo -e "${RED}[$(timestamp)] [ERROR]${NC} $1" >&2; exit 1; }

# Error trap with line reporting
error_handler() {
    local line_no=$1
    log_error "Critical failure at line $line_no. Installation aborted."
}
trap 'error_handler $LINENO' ERR

# --- CONFIG DEFAULTS ---
LOCALE="en_US.UTF-8"
# NOTE: 'us-intl' is the correct map for TTY console. 'us-acentos' causes warnings.
KEYMAP="us-intl"
TIMEZONE="America/Sao_Paulo"
HOSTNAME_DEFAULT="archlinux"

# --- PACKAGE LISTS ---

# 1. CORE SYSTEM (Base + Kernel Backup + Firmware)
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware archlinux-keyring linux-lts linux-lts-headers)

# 2. SENIOR CLI TOOLKIT (Daily Drivers)
PKGS_SYS=(
    # Admin & Maintenance
    sudo neovim vim git man-db man-pages pacman-contrib fwupd 
    # Shell & Search
    bash-completion fzf fastfetch trash-cli ripgrep fd jq
    # Monitoring & Disk
    htop ncdu plocate
    # Archives
    unzip p7zip unrar atool tree
    # Network Utils
    rsync wget curl bind reflector
    # Backup
    restic
    # Boot UI
    plymouth
)

# 3. SECURITY & STABILITY
# timeshift: System Snapshots (Rollback)
# earlyoom: Prevents system freeze on OOM (Out of Memory)
PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor timeshift earlyoom)

# 4. NETWORK STACK
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils openssh avahi)

# 5. FILESYSTEM
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g xdg-user-dirs usbutils)

# 6. AUDIO STACK (Pipewire)
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware pavucontrol)

# 7. PRINTING
PKGS_PRINT=(cups)

# 8. FONTS (UI, Web & Code)
PKGS_FONTS=(
    noto-fonts noto-fonts-emoji 
    ttf-liberation ttf-roboto ttf-fira-sans 
    ttf-jetbrains-mono-nerd
)

# 9. APPS (Browser + Flatpak)
PKGS_APPS=(firefox thunderbird flatpak)

# 10. DEV INFRA
PKGS_DEV=(docker docker-compose docker-buildx)

# 11. VISUALS (GTK & QT Uniformity)
# qt5-wayland/qt6-wayland: Essential for Qt apps on Sway
# qt5ct/qt6ct: Theme bridging
PKGS_THEMES=(
    gnome-themes-extra adwaita-icon-theme glib2
    qt5-wayland qt6-wayland qt5ct qt6ct adwaita-qt5 adwaita-qt6
)

# --- DE SPECIFIC LISTS ---

# SWAY PROFILE (Vanilla + Senior Plumbing)
PKGS_SWAY_BASE=(
    # Core
    sway swaybg swayidle swaylock dmenu ly 
    foot 
    # Portal (Screen sharing + File Dialogs)
    xdg-desktop-portal-wlr xdg-desktop-portal-gtk
    # File Mgmt
    thunar thunar-volman gvfs tumbler file-roller
    # Auth & Secrets (Essential for VSCode, Chrome, Git)
    polkit-gnome gnome-keyring libsecret
    # Tray Apps
    blueman network-manager-applet
    # Media (Lightweight)
    zathura zathura-pdf-mupdf imv mpv
    # Wayland Utils
    mako grim slurp clipman
)

# LAPTOP TOOLS (Conditional)
PKGS_LAPTOP_TOOLS=(tlp kanshi brightnessctl)

# GAMING TOOLS (Conditional)
PKGS_GAME_TOOLS=(steam lutris gamemode mangohud wine-staging winetricks openrgb)

# Alternative DEs
PKGS_GNOME=(gnome-shell gdm gnome-console nautilus xdg-desktop-portal-gnome gnome-control-center)
PKGS_KDE=(plasma-desktop sddm dolphin konsole xdg-desktop-portal-kde ark spectacle)

# --- HARDWARE DETECTION ---

detect_hardware() {
    log_step "Hardware Detection"
    
    # 1. CPU (Microcode)
    local cpu_vendor
    cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        log_info "CPU: Intel (Microcode selected)"
        UCODE_PKG="intel-ucode"; UCODE_IMG="/intel-ucode.img"
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        log_info "CPU: AMD (Microcode selected)"
        UCODE_PKG="amd-ucode"; UCODE_IMG="/amd-ucode.img"
    else
        log_warn "CPU: Generic/VM"
        UCODE_PKG=""; UCODE_IMG=""
    fi

    # 2. GPU (Drivers & VA-API)
    GPU_PKGS=()
    local gpu_info
    gpu_info=$(lspci -mm | grep -E "VGA|3D")
    
    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        log_info "GPU: NVIDIA detected (Proprietary + DKMS)"
        GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings)
    
    elif echo "$gpu_info" | grep -iq "AMD"; then
        log_info "GPU: AMD detected (RADV + VA-API)"
        GPU_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu libva-mesa-driver)
    
    elif echo "$gpu_info" | grep -iq "Intel"; then
        log_info "GPU: Intel detected (Media Driver)"
        GPU_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver)
    
    else
        log_warn "GPU: Fallback (Software Rendering)"
        GPU_PKGS+=(mesa lib32-mesa)
    fi

    # 3. CHASSIS (Laptop vs Desktop)
    IS_LAPTOP="false"
    # DMI Chassis Types (8-10, 14, 31-32 are portable)
    if grep -EEq "^(8|9|10|14|31|32)$" /sys/class/dmi/id/chassis_type 2>/dev/null; then
        IS_LAPTOP="true"
        log_info "Chassis: Laptop detected (Enabling Mobile Suite)"
    else
        log_info "Chassis: Desktop detected (Disabling Mobile Suite)"
    fi
}

# --- PRE-FLIGHT ---

pre_flight_checks() {
    [[ $EUID -ne 0 ]] && log_error "This script must be run as ROOT."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_error "System not booted in UEFI mode."
    ping -c 1 archlinux.org &>/dev/null || log_error "No internet connection. Configure with 'iwctl'."
    log_succ "Pre-flight checks passed."
}

# --- INPUT ---

collect_user_input() {
    clear
    echo -e "${MAGENTA}==========================================${NC}"
    echo -e "${MAGENTA}   ARCH LINUX INSTALLER v3.8 (FINAL)      ${NC}"
    echo -e "${MAGENTA}==========================================${NC}"
    
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_INPUT
    HOSTNAME_VAL=${HOSTNAME_INPUT:-$HOSTNAME_DEFAULT}

    echo ""; lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk; echo ""
    read -r -p "Target Disk (e.g., nvme0n1): " DISK
    TARGET="/dev/$DISK"
    [[ ! -b "$TARGET" ]] && log_error "Invalid device: $TARGET"
    
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"
    P_ROOT="${TARGET}${P_SUF}2"

    echo ""; read -r -p "Enable GAMER Profile (Zen Kernel + Gaming Tools)? (y/N): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL_PKG="linux-zen"; HEADER_PKG="linux-zen-headers"
        VMLINUZ="/vmlinuz-linux-zen"; INITRAMFS="/initramfs-linux-zen.img"
    else
        KERNEL_PKG="linux"; HEADER_PKG="linux-headers"
        VMLINUZ="/vmlinuz-linux"; INITRAMFS="/initramfs-linux.img"
        GPU_PKGS=()
    fi

    echo ""; read -r -p "Enable Hibernation (Disk Swap)? (y/N): " OPT_HIBERNATE

    echo ""; echo "Select Desktop Environment:"
    select opt in "Sway" "Gnome" "KDE"; do
        case $opt in
            "Sway") DE_PKGS=("${PKGS_SWAY_BASE[@]}"); DM="ly"; DE_NAME="sway"; break ;;
            "Gnome") DE_PKGS=("${PKGS_GNOME[@]}"); DM="gdm"; DE_NAME="gnome"; break ;;
            "KDE") DE_PKGS=("${PKGS_KDE[@]}"); DM="sddm"; DE_NAME="kde"; break ;;
            *) log_warn "Invalid option." ;;
        esac
    done

    echo ""; read -r -p "Sudo Username: " USER_NAME
    read -r -s -p "Password: " USER_PASS; echo ""
}

# --- INSTALLATION ---

prepare_storage() {
    log_step "Storage Preparation"
    log_info "Wiping signatures on $TARGET..."
    wipefs -af "$TARGET"
    sgdisk -Zo "$TARGET"
    
    log_info "Partitioning (GPT)..."
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    partprobe "$TARGET" && sleep 2

    log_info "Encrypting (LUKS2)..."
    # Optimization: Perf-no-workqueue improves SSD/NVMe performance
    cryptsetup luksFormat --type luks2 --sector-size 4096 --verify-passphrase "$P_ROOT"
    cryptsetup open "$P_ROOT" cryptroot \
        --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

    log_info "Configuring LVM..."
    pvcreate /dev/mapper/cryptroot
    vgcreate vg0 /dev/mapper/cryptroot

    if [[ "$OPT_HIBERNATE" == "y" ]]; then
        log_info "Allocating Swap (34G)..."
        lvcreate -L 34G -n swap vg0; mkswap -L swap /dev/mapper/vg0-swap
        SWAP_DEVICE="/dev/mapper/vg0-swap"
    else
        SWAP_DEVICE=""
    fi

    log_info "Allocating Root..."
    lvcreate -l 100%FREE -n root vg0
    mkfs.ext4 -L arch_root /dev/mapper/vg0-root
    mkfs.fat -F 32 -n EFI "$P_EFI"

    log_info "Mounting Volumes..."
    mount /dev/mapper/vg0-root /mnt
    mkdir -p /mnt/boot
    # Security: umask 0077 on /boot prevents non-root access
    mount -o fmask=0077,dmask=0077 "$P_EFI" /mnt/boot
    [[ -n "$SWAP_DEVICE" ]] && swapon "$SWAP_DEVICE"
    log_succ "Storage ready."
}

install_packages() {
    log_step "Package Installation"
    
    log_info "Updating Keyring..."
    pacman -Sy --noconfirm archlinux-keyring

    log_info "Optimizing Pacman..."
    # Enable Parallel Downloads, Color, and Verbose Lists
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
    
    # Pacman Easter Egg
    if ! grep -q "ILoveCandy" /etc/pacman.conf; then
        sed -i '/Color/a ILoveCandy' /etc/pacman.conf
    fi
    
    log_info "Selecting best mirrors (Reflector)..."
    reflector --country Brazil --country 'United States' --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    detect_hardware
    
    FINAL_PKG_LIST=(
        "${PKGS_BASE[@]}" "$KERNEL_PKG" "$HEADER_PKG" ${UCODE_PKG:+"$UCODE_PKG"}
        "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" 
        "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" "${PKGS_DEV[@]}" "${PKGS_THEMES[@]}"
        "${PKGS_APPS[@]}" "${DE_PKGS[@]}" "${GPU_PKGS[@]}"
    )
    
    # Laptop Logic
    if [ "$IS_LAPTOP" == "true" ] && [ "$DE_NAME" == "sway" ]; then
        FINAL_PKG_LIST+=("${PKGS_LAPTOP_TOOLS[@]}")
    elif [ "$IS_LAPTOP" == "true" ]; then
        FINAL_PKG_LIST+=("tlp")
    fi
    
    # Gaming Logic
    if [ "$OPT_GAME" == "y" ]; then
        FINAL_PKG_LIST+=("${PKGS_GAME_TOOLS[@]}")
    fi

    [[ "$OPT_HIBERNATE" != "y" ]] && FINAL_PKG_LIST+=("zram-generator")

    log_info "Downloading and installing packages..."
    pacstrap -K /mnt "${FINAL_PKG_LIST[@]}"
    
    log_info "Generating Fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    # Enforce umask in fstab for persistent security
    sed -i 's/fmask=0022/fmask=0077/g' /mnt/etc/fstab || true
    sed -i 's/dmask=0022/dmask=0077/g' /mnt/etc/fstab || true
    
    log_succ "Base system installed."
}

configure_target_system() {
    log_step "System Configuration (Chroot)"
    
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

# Replica pacman config
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
if ! grep -q "ILoveCandy" /etc/pacman.conf; then
    sed -i '/Color/a ILoveCandy' /etc/pacman.conf
fi

# --- 2. ENVIRONMENT & TUNING ---
cat > /etc/environment <<ENV
# Force Wayland on Qt/Mozilla
QT_QPA_PLATFORM=wayland
MOZ_ENABLE_WAYLAND=1
_JAVA_AWT_WM_NONREPARENTING=1

# Visual Uniformity (Themes)
GTK_THEME=Adwaita:dark
# Force Qt to use configured theme via qt5ct/qt6ct
QT_QPA_PLATFORMTHEME=qt5ct
ENV

# LVM TRIM Support (SSD Health)
sed -i 's/issue_discards = 0/issue_discards = 1/' /etc/lvm/lvm.conf

# Sysctl Performance Tuning
cat > /etc/sysctl.d/99-performance.conf <<SYSCTL
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
SYSCTL

# --- 3. USERS ---
useradd -m -G wheel,video,input,storage,docker -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

runuser -l "$USER_NAME" -c "xdg-user-dirs-update"

# --- 4. EXTRA REPOS ---
if [ "$OPT_GAME" == "y" ]; then
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm
fi

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# --- 5. SWAY CONFIG (Auto-Generate) ---
if [[ "$DE_NAME" == "sway" ]]; then
    echo "XDG_CURRENT_DESKTOP=sway" >> /etc/environment
    mkdir -p /home/$USER_NAME/.config/sway
    
    if [ ! -f /home/$USER_NAME/.config/sway/config ]; then
        cp /etc/sway/config /home/$USER_NAME/.config/sway/config
        
        cat <<SWAYCONF >> /home/$USER_NAME/.config/sway/config

# --- Vanilla Overrides ---
set \\\$term foot
set \\\$menu dmenu_path | dmenu | xargs swaymsg exec --

# --- Plumbing (Infrastructure) ---
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec nm-applet --indicator
exec blueman-applet
exec gnome-keyring-daemon --start --components=secrets
exec mako
exec wl-paste -t text --watch clipman store

# --- Visuals ---
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
SWAYCONF

        if [ "$IS_LAPTOP" == "true" ]; then
             echo "exec kanshi" >> /home/$USER_NAME/.config/sway/config
        fi
    fi
    chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config
fi

# --- 6. BOOTLOADER & PLYMOUTH ---
bootctl install
UUID_CRYPT=\$(blkid -s UUID -o value $P_ROOT)

SEC_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1 apparmor=1 security=apparmor"

# FIX: Added sd-plymouth for Graphical Boot. Must come after systemd.
# Order: systemd -> plymouth -> encrypt -> lvm
HOOKS="systemd sd-plymouth autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2"

if [ "$OPT_HIBERNATE" == "y" ]; then
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS resume filesystems fsck)/" /etc/mkinitcpio.conf
    # Note: 'splash' param enables Plymouth
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root resume=/dev/mapper/vg0-swap rw quiet splash \$SEC_PARAMS"
else
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root rw quiet splash \$SEC_PARAMS"
    echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
fi

mkinitcpio -P

# Setup Plymouth Theme (BGRT = OEM Logo, cleanest look)
plymouth-set-default-theme -R bgrt

# Loader Config
cat > /boot/loader/loader.conf <<LCONF
default arch.conf
timeout 3
console-mode max
editor no
LCONF

INITRD_UCODE=""
[ -n "$UCODE_IMG" ] && INITRD_UCODE="initrd $UCODE_IMG"

# Entry 1: Main Kernel
cat > /boot/loader/entries/arch.conf <<LENTRY
title   Arch Linux (Main)
linux   $VMLINUZ
\$INITRD_UCODE
initrd  $INITRAMFS
options \$CMDLINE
LENTRY

# Entry 2: LTS Kernel
cat > /boot/loader/entries/arch-lts.conf <<LENTRY_LTS
title   Arch Linux LTS (Backup)
linux   /vmlinuz-linux-lts
\$INITRD_UCODE
initrd  /initramfs-linux-lts.img
options \$CMDLINE
LENTRY_LTS

# --- 7. SERVICES ---
echo "Enabling Services..."

# Network & Hardware
systemctl enable NetworkManager || echo "WARN: NM failed"
systemctl enable bluetooth || echo "WARN: BT failed"
systemctl enable avahi-daemon || echo "WARN: Avahi failed"
systemctl enable chronyd || echo "WARN: Chrony failed"
systemctl enable firewalld || echo "WARN: Firewalld failed"

# Maintenance & Security
systemctl enable fstrim.timer || echo "WARN: Fstrim failed"
systemctl enable paccache.timer || echo "WARN: Paccache failed"
systemctl enable reflector.timer || echo "WARN: Reflector failed"
systemctl enable earlyoom || echo "WARN: EarlyOOM failed"
systemctl enable apparmor || echo "WARN: Apparmor failed"
systemctl enable pcscd || echo "WARN: Pcscd failed"

# Apps
systemctl enable cups || echo "WARN: Cups failed"
systemctl enable docker || echo "WARN: Docker failed"

if [ "$IS_LAPTOP" == "true" ]; then
    systemctl enable tlp || echo "WARN: TLP failed"
fi

if [[ "$DM" == "ly" ]]; then
    systemctl disable getty@tty2.service || true
    systemctl enable ly@tty2.service || echo "ERROR: Ly failed"
else
    systemctl enable "$DM" || echo "ERROR: $DM failed"
fi

EOF

    chmod +x /mnt/setup_internal.sh
    log_info "Executing internal setup..."
    arch-chroot /mnt /setup_internal.sh
    rm /mnt/setup_internal.sh
    log_succ "Internal configuration complete."
}

# --- MAIN ---
pre_flight_checks
collect_user_input
# Hardware detect runs again inside install_packages
prepare_storage
install_packages
configure_target_system

echo ""
log_step "INSTALLATION COMPLETE"
log_succ "System installed and configured."
log_info "1. Remove installation media."
log_info "2. Type 'reboot'."
log_info "3. Post-boot: Setup 'Timeshift' snapshots and install 'yay' (AUR)."
