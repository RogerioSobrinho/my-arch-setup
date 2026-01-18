#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Installer v4.0 (AUR Automation)
# DESCRIPTION:  Automated, encrypted, hardware-aware Arch Linux installation.
# TARGET:       Workstation (Laptop/Desktop) & Gaming
# AUTHOR:       Rogerio Sobrinho (Reviewed by Gemini AI)
# DATE:         2026-01-18
# CHANGES:      Added automated Paru installation and AUR packages
# ==============================================================================

# --- STRICT MODE ---
set -euo pipefail
IFS=$'\n\t'

# --- LOGGING INFRASTRUCTURE ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

timestamp() { date +'%H:%M:%S'; }

log_info()  { echo -e "${CYAN}[$(timestamp)] [INFO]${NC} $1"; }
log_succ()  { echo -e "${GREEN}[$(timestamp)] [OK]${NC}   $1"; }
log_warn()  { echo -e "${YELLOW}[$(timestamp)] [WARN]${NC} $1"; }
log_step()  { echo -e "\n${MAGENTA}[$(timestamp)] === $1 ===${NC}"; }
log_error() { echo -e "${RED}[$(timestamp)] [ERROR]${NC} $1" >&2; exit 1; }

error_handler() {
    local line_no=$1
    log_error "Critical failure at line $line_no. Installation aborted."
}
trap 'error_handler $LINENO' ERR

# --- CONFIG DEFAULTS ---
LOCALE="en_US.UTF-8"
KEYMAP="us-intl"
TIMEZONE="America/Sao_Paulo"
HOSTNAME_DEFAULT="archlinux"

# --- PACKAGE LISTS ---

# 1. CORE SYSTEM
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware archlinux-keyring linux-lts linux-lts-headers)

# 2. SENIOR CLI TOOLKIT
PKGS_SYS=(
    sudo neovim vim git man-db man-pages pacman-contrib fwupd 
    bash-completion fzf fastfetch trash-cli ripgrep fd jq
    htop ncdu plocate
    unzip p7zip unrar atool tree
    rsync wget curl bind reflector
    restic
    plymouth
)

# 3. SECURITY & STABILITY
PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor timeshift earlyoom)

# 4. NETWORK STACK
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils openssh avahi)

# 5. FILESYSTEM
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g xdg-user-dirs usbutils)

# 6. AUDIO STACK
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware pavucontrol)

# 7. PRINTING
PKGS_PRINT=(cups)

# 8. FONTS
PKGS_FONTS=(
    noto-fonts noto-fonts-emoji 
    ttf-liberation ttf-roboto ttf-fira-sans 
    ttf-jetbrains-mono-nerd
)

# 9. APPS
PKGS_APPS=(firefox thunderbird flatpak)

# 10. DEV INFRA
PKGS_DEV=(docker docker-compose docker-buildx)

# 11. VISUALS (Official Repos)
PKGS_THEMES=(
    gnome-themes-extra adwaita-icon-theme glib2
    qt5-wayland qt6-wayland qt5ct qt6ct
)

# 12. AUR PACKAGES (Installed via Paru)
# adwaita-qt5/6: Matches Qt apps to Adwaita Dark theme
PKGS_AUR=(adwaita-qt5 adwaita-qt6)

# --- DE SPECIFIC LISTS ---

# SWAY PROFILE
PKGS_SWAY_BASE=(
    sway swaybg swayidle swaylock dmenu ly 
    foot 
    xdg-desktop-portal-wlr xdg-desktop-portal-gtk
    thunar thunar-volman gvfs tumbler file-roller
    polkit-gnome gnome-keyring libsecret
    blueman network-manager-applet
    zathura zathura-pdf-mupdf imv mpv
    mako grim slurp cliphist
)

PKGS_LAPTOP_TOOLS=(tlp kanshi brightnessctl)
PKGS_GAME_TOOLS=(steam lutris gamemode mangohud wine-staging winetricks openrgb)

PKGS_GNOME=(gnome-shell gdm gnome-console nautilus xdg-desktop-portal-gnome gnome-control-center)
PKGS_KDE=(plasma-desktop sddm dolphin konsole xdg-desktop-portal-kde ark spectacle)

# --- HARDWARE DETECTION ---

detect_hardware() {
    log_step "Hardware Detection"
    
    local cpu_vendor
    cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        log_info "CPU: Intel"
        UCODE_PKG="intel-ucode"; UCODE_IMG="/intel-ucode.img"
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        log_info "CPU: AMD"
        UCODE_PKG="amd-ucode"; UCODE_IMG="/amd-ucode.img"
    else
        UCODE_PKG=""; UCODE_IMG=""
    fi

    GPU_PKGS=()
    local gpu_info
    gpu_info=$(lspci -mm | grep -E "VGA|3D")
    
    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        log_info "GPU: NVIDIA"
        GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings)
    elif echo "$gpu_info" | grep -iq "AMD"; then
        log_info "GPU: AMD"
        GPU_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu libva-mesa-driver)
    elif echo "$gpu_info" | grep -iq "Intel"; then
        log_info "GPU: Intel"
        GPU_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver)
    else
        GPU_PKGS+=(mesa lib32-mesa)
    fi

    IS_LAPTOP="false"
    if grep -EEq "^(8|9|10|14|31|32)$" /sys/class/dmi/id/chassis_type 2>/dev/null; then
        IS_LAPTOP="true"
        log_info "Chassis: Laptop"
    else
        log_info "Chassis: Desktop"
    fi
}

# --- PRE-FLIGHT ---

pre_flight_checks() {
    [[ $EUID -ne 0 ]] && log_error "Run as ROOT."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_error "UEFI Required."
    ping -c 1 archlinux.org &>/dev/null || log_error "No Internet."
    log_succ "Checks Passed."
}

# --- INPUT ---

collect_user_input() {
    clear
    echo -e "${MAGENTA}=== ARCH LINUX INSTALLER v4.0 ===${NC}"
    
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_INPUT
    HOSTNAME_VAL=${HOSTNAME_INPUT:-$HOSTNAME_DEFAULT}

    echo ""; lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk; echo ""
    read -r -p "Target Disk (e.g., nvme0n1): " DISK
    TARGET="/dev/$DISK"
    [[ ! -b "$TARGET" ]] && log_error "Invalid Disk."
    
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"
    P_ROOT="${TARGET}${P_SUF}2"

    echo ""; read -r -p "Gamer Profile? (y/N): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL_PKG="linux-zen"; HEADER_PKG="linux-zen-headers"
        VMLINUZ="/vmlinuz-linux-zen"; INITRAMFS="/initramfs-linux-zen.img"
    else
        KERNEL_PKG="linux"; HEADER_PKG="linux-headers"
        VMLINUZ="/vmlinuz-linux"; INITRAMFS="/initramfs-linux.img"
        GPU_PKGS=()
    fi

    echo ""; read -r -p "Hibernation? (y/N): " OPT_HIBERNATE

    echo ""; echo "Desktop Environment:"
    select opt in "Sway" "Gnome" "KDE"; do
        case $opt in
            "Sway") DE_PKGS=("${PKGS_SWAY_BASE[@]}"); DM="ly"; DE_NAME="sway"; break ;;
            "Gnome") DE_PKGS=("${PKGS_GNOME[@]}"); DM="gdm"; DE_NAME="gnome"; break ;;
            "KDE") DE_PKGS=("${PKGS_KDE[@]}"); DM="sddm"; DE_NAME="kde"; break ;;
            *) log_warn "Invalid." ;;
        esac
    done

    echo ""; read -r -p "User: " USER_NAME
    read -r -s -p "Pass: " USER_PASS; echo ""
}

# --- INSTALLATION ---

prepare_storage() {
    log_step "Storage"
    wipefs -af "$TARGET"
    sgdisk -Zo "$TARGET"
    
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    partprobe "$TARGET" && sleep 2

    log_info "Encryption (LUKS2)..."
    cryptsetup luksFormat --type luks2 --sector-size 4096 --verify-passphrase "$P_ROOT"
    cryptsetup open "$P_ROOT" cryptroot \
        --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

    log_info "LVM..."
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

    mount /dev/mapper/vg0-root /mnt
    mkdir -p /mnt/boot
    mount -o fmask=0077,dmask=0077 "$P_EFI" /mnt/boot
    [[ -n "$SWAP_DEVICE" ]] && swapon "$SWAP_DEVICE"
}

install_packages() {
    log_step "Packages"
    
    log_info "Keyring..."
    pacman -Sy --noconfirm archlinux-keyring

    log_info "Pacman Tuning..."
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
    if ! grep -q "ILoveCandy" /etc/pacman.conf; then
        sed -i '/Color/a ILoveCandy' /etc/pacman.conf
    fi
    
    # Enable Multilib in Live ISO for proper dependency resolution
    log_info "Enabling Multilib on Live ISO..."
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy

    log_info "Mirrors..."
    reflector --country Brazil --country 'United States' --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    detect_hardware
    
    FINAL_PKG_LIST=(
        "${PKGS_BASE[@]}" "$KERNEL_PKG" "$HEADER_PKG" ${UCODE_PKG:+"$UCODE_PKG"}
        "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" 
        "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" "${PKGS_DEV[@]}" "${PKGS_THEMES[@]}"
        "${PKGS_APPS[@]}" "${DE_PKGS[@]}" "${GPU_PKGS[@]}"
    )
    
    if [ "$IS_LAPTOP" == "true" ] && [ "$DE_NAME" == "sway" ]; then
        FINAL_PKG_LIST+=("${PKGS_LAPTOP_TOOLS[@]}")
    elif [ "$IS_LAPTOP" == "true" ]; then
        FINAL_PKG_LIST+=("tlp")
    fi
    
    if [ "$OPT_GAME" == "y" ]; then
        FINAL_PKG_LIST+=("${PKGS_GAME_TOOLS[@]}")
    fi

    [[ "$OPT_HIBERNATE" != "y" ]] && FINAL_PKG_LIST+=("zram-generator")

    log_info "Installing Base..."
    pacstrap -K /mnt "${FINAL_PKG_LIST[@]}"
    
    log_info "Fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    sed -i 's/fmask=0022/fmask=0077/g' /mnt/etc/fstab || true
    sed -i 's/dmask=0022/dmask=0077/g' /mnt/etc/fstab || true
}

configure_target_system() {
    log_step "System Config (Chroot)"
    
    cat <<EOF > /mnt/setup_internal.sh
#!/bin/bash
set -euo pipefail

# --- Locale ---
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

# Pacman Config Replica
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
if ! grep -q "ILoveCandy" /etc/pacman.conf; then
    sed -i '/Color/a ILoveCandy' /etc/pacman.conf
fi

# --- Tuning ---
cat > /etc/environment <<ENV
QT_QPA_PLATFORM=wayland
MOZ_ENABLE_WAYLAND=1
_JAVA_AWT_WM_NONREPARENTING=1
GTK_THEME=Adwaita:dark
QT_QPA_PLATFORMTHEME=qt5ct
ENV

sed -i 's/issue_discards = 0/issue_discards = 1/' /etc/lvm/lvm.conf

cat > /etc/sysctl.d/99-performance.conf <<SYSCTL
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
SYSCTL

# --- User ---
useradd -m -G wheel,video,input,storage,docker -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

runuser -l "$USER_NAME" -c "xdg-user-dirs-update"

# --- Repos & AUR ---
# Enable Multilib inside target
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# AUR HELPER INSTALLATION (Paru)
echo "Installing Paru (AUR Helper)..."

# 1. Grant temp sudo to user
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/temp_install

# 2. Build as User (Root cannot build)
su - $USER_NAME <<AUR
# Install paru-bin to save time
git clone https://aur.archlinux.org/paru-bin.git
cd paru-bin
makepkg -si --noconfirm
cd ..
rm -rf paru-bin

# Install AUR Themes
echo "Installing AUR Themes..."
paru -S --noconfirm ${PKGS_AUR[@]}
AUR

# 3. Revoke temp sudo
rm /etc/sudoers.d/temp_install

# --- Sway Config ---
if [[ "$DE_NAME" == "sway" ]]; then
    echo "XDG_CURRENT_DESKTOP=sway" >> /etc/environment
    mkdir -p /home/$USER_NAME/.config/sway
    
    if [ ! -f /home/$USER_NAME/.config/sway/config ]; then
        cp /etc/sway/config /home/$USER_NAME/.config/sway/config
        
        cat <<SWAYCONF >> /home/$USER_NAME/.config/sway/config

# --- Vanilla Overrides ---
set \\\$term foot
set \\\$menu dmenu_path | dmenu | xargs swaymsg exec --

# --- Plumbing ---
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec nm-applet --indicator
exec blueman-applet
exec gnome-keyring-daemon --start --components=secrets
exec mako
exec wl-paste --watch cliphist store

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

# --- Bootloader ---
bootctl install
UUID_CRYPT=\$(blkid -s UUID -o value $P_ROOT)

SEC_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1 apparmor=1 security=apparmor"
HOOKS="systemd sd-plymouth autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2"

if [ "$OPT_HIBERNATE" == "y" ]; then
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS resume filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root resume=/dev/mapper/vg0-swap rw quiet splash \$SEC_PARAMS"
else
    sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS filesystems fsck)/" /etc/mkinitcpio.conf
    CMDLINE="rd.luks.name=\$UUID_CRYPT=cryptroot root=/dev/mapper/vg0-root rw quiet splash \$SEC_PARAMS"
    echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
fi

mkinitcpio -P
plymouth-set-default-theme -R bgrt

cat > /boot/loader/loader.conf <<LCONF
default arch.conf
timeout 3
console-mode max
editor no
LCONF

INITRD_UCODE=""
[ -n "$UCODE_IMG" ] && INITRD_UCODE="initrd $UCODE_IMG"

cat > /boot/loader/entries/arch.conf <<LENTRY
title   Arch Linux (Main)
linux   $VMLINUZ
\$INITRD_UCODE
initrd  $INITRAMFS
options \$CMDLINE
LENTRY

cat > /boot/loader/entries/arch-lts.conf <<LENTRY_LTS
title   Arch Linux LTS (Backup)
linux   /vmlinuz-linux-lts
\$INITRD_UCODE
initrd  /initramfs-linux-lts.img
options \$CMDLINE
LENTRY_LTS

# --- Services ---
echo "Services..."

systemctl enable NetworkManager || echo "WARN: NM failed"
systemctl enable bluetooth || echo "WARN: BT failed"
systemctl enable avahi-daemon || echo "WARN: Avahi failed"
systemctl enable chronyd || echo "WARN: Chrony failed"
systemctl enable firewalld || echo "WARN: Firewalld failed"

systemctl enable fstrim.timer || echo "WARN: Fstrim failed"
systemctl enable paccache.timer || echo "WARN: Paccache failed"
systemctl enable reflector.timer || echo "WARN: Reflector failed"
systemctl enable earlyoom || echo "WARN: EarlyOOM failed"
systemctl enable apparmor || echo "WARN: Apparmor failed"
systemctl enable pcscd || echo "WARN: Pcscd failed"

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
    log_info "Running internal setup..."
    arch-chroot /mnt /setup_internal.sh
    rm /mnt/setup_internal.sh
    log_succ "Config Done."
}

# --- MAIN ---
pre_flight_checks
collect_user_input
prepare_storage
install_packages
configure_target_system

echo ""
log_step "INSTALLATION COMPLETE"
log_succ "System installed."
log_info "1. Remove USB."
log_info "2. Type 'reboot'."
