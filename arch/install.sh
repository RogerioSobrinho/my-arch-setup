#!/usr/bin/env bash
# ==============================================================================
# PROJECT:      Arch Linux Installer v4.2 (Official Repos Only)
# DESCRIPTION:  Fast, stable, encrypted installation. NO AUR. NO PLYMOUTH.
# TARGET:       Workstation & Gaming
# AUTHOR:       Rogerio Sobrinho (Reviewed by Gemini AI)
# DATE:         2026-01-18
# CHANGES:      Removed AUR/Plymouth completely. Fixed Multilib.
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

error_handler() {
    log_err "Falha na linha $1. Instalação abortada."
}
trap 'error_handler $LINENO' ERR

# --- CONFIGURAÇÃO ---
HOSTNAME_DEFAULT="archlinux"
KEYMAP="us-intl" # Mapa correto para console TTY

# --- LISTAS DE PACOTES (Apenas Repositórios Oficiais) ---

# Base do Sistema
PKGS_BASE=(base base-devel linux-firmware lvm2 sof-firmware archlinux-keyring linux-lts linux-lts-headers)

# Ferramentas Essenciais
# Removido: plymouth (AUR), yay/paru (AUR)
PKGS_SYS=(
    sudo neovim vim git man-db man-pages pacman-contrib fwupd 
    bash-completion fzf fastfetch trash-cli ripgrep fd jq
    htop ncdu plocate
    unzip p7zip unrar atool tree
    rsync wget curl bind reflector
    restic
)

# Segurança
PKGS_SEC=(pcsclite ccid yubikey-manager bitwarden apparmor timeshift earlyoom)

# Rede
PKGS_NET=(networkmanager chrony firewalld bluez bluez-utils openssh avahi)

# Arquivos e Boot
PKGS_FS=(efibootmgr cryptsetup dosfstools e2fsprogs ntfs-3g xdg-user-dirs usbutils)

# Áudio
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber alsa-firmware pavucontrol)

# Impressão
PKGS_PRINT=(cups)

# Fontes
PKGS_FONTS=(noto-fonts noto-fonts-emoji ttf-liberation ttf-roboto ttf-fira-sans ttf-jetbrains-mono-nerd)

# Apps Básicos
PKGS_APPS=(firefox thunderbird flatpak)

# Dev
PKGS_DEV=(docker docker-compose docker-buildx)

# Temas (Apenas Oficiais)
# Removido: adwaita-qt5/6 (AUR)
PKGS_THEMES=(gnome-themes-extra adwaita-icon-theme glib2 qt5-wayland qt6-wayland qt5ct qt6ct)

# Sway (Sway + Utils Oficiais)
# Substituído: clipman -> cliphist (Oficial)
PKGS_SWAY=(sway swaybg swayidle swaylock dmenu ly foot xdg-desktop-portal-wlr xdg-desktop-portal-gtk thunar thunar-volman gvfs tumbler file-roller polkit-gnome gnome-keyring libsecret blueman network-manager-applet zathura zathura-pdf-mupdf imv mpv mako grim slurp cliphist)

# Perfis Opcionais
PKGS_LAPTOP=(tlp kanshi brightnessctl)
# Nota: openrgb está no [extra]
PKGS_GAME=(steam lutris gamemode mangohud wine-staging winetricks openrgb)

# --- FUNÇÕES ---

pre_flight() {
    [[ $EUID -ne 0 ]] && log_err "Execute como ROOT."
    [[ ! -d /sys/firmware/efi/efivars ]] && log_err "Sistema não é UEFI."
    ping -c 1 archlinux.org &>/dev/null || log_err "Sem Internet."
}

collect_input() {
    clear
    echo -e "${CYAN}=== Arch Installer v4.2 (Official Only) ===${NC}"
    
    read -r -p "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME_VAL
    HOSTNAME_VAL=${HOSTNAME_VAL:-$HOSTNAME_DEFAULT}
    
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep disk
    echo ""
    read -r -p "Disco Alvo (ex: nvme0n1): " DISK
    TARGET="/dev/$DISK"
    
    if [[ ! -b "$TARGET" ]]; then log_err "Disco inválido."; fi
    
    # Partição NVMe tem 'p', SATA não tem
    if [[ "$DISK" =~ "nvme" ]]; then P_SUF="p"; else P_SUF=""; fi
    P_EFI="${TARGET}${P_SUF}1"
    P_ROOT="${TARGET}${P_SUF}2"

    read -r -p "Perfil Gamer (Kernel Zen)? (y/n): " OPT_GAME
    if [[ "$OPT_GAME" == "y" ]]; then
        KERNEL="linux-zen"; K_HEADERS="linux-zen-headers"
    else
        KERNEL="linux"; K_HEADERS="linux-headers"
    fi
    
    read -r -p "Hibernação (Swap em Disco)? (y/n): " OPT_HIB
    read -r -p "Usuário: " USER_NAME
    read -r -s -p "Senha: " USER_PASS; echo ""
}

prepare_disk() {
    log_info "Limpando disco $TARGET..."
    wipefs -af "$TARGET"
    sgdisk -Zo "$TARGET"
    
    log_info "Particionando..."
    parted -s "$TARGET" mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB set 1 esp on \
        mkpart cryptroot 512MiB 100%
    
    # Wait for kernel to register partitions
    sleep 2
    
    log_info "Criptografando (LUKS2)..."
    echo -n "$USER_PASS" | cryptsetup luksFormat --type luks2 --sector-size 4096 -d - "$P_ROOT"
    echo -n "$USER_PASS" | cryptsetup open -d - "$P_ROOT" cryptroot --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

    log_info "LVM..."
    pvcreate /dev/mapper/cryptroot
    vgcreate vg0 /dev/mapper/cryptroot

    if [[ "$OPT_HIB" == "y" ]]; then
        lvcreate -L 34G -n swap vg0; mkswap /dev/mapper/vg0-swap
        SWAP_DEV="/dev/mapper/vg0-swap"
    else
        SWAP_DEV=""
    fi

    lvcreate -l 100%FREE -n root vg0
    mkfs.ext4 /dev/mapper/vg0-root
    mkfs.fat -F 32 -n EFI "$P_EFI"

    log_info "Montando..."
    mount /dev/mapper/vg0-root /mnt
    mkdir -p /mnt/boot
    mount -o fmask=0077,dmask=0077 "$P_EFI" /mnt/boot
    
    if [[ -n "$SWAP_DEV" ]]; then swapon "$SWAP_DEV"; fi
}

detect_hw() {
    log_info "Detectando Hardware..."
    CPU_V=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    [[ "$CPU_V" == "GenuineIntel" ]] && UCODE="intel-ucode" || UCODE="amd-ucode"
    
    GPU_PKGS=()
    if lspci | grep -qi "NVIDIA"; then 
        log_info "GPU: NVIDIA"
        GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils)
    fi
    if lspci | grep -qi "AMD"; then 
        log_info "GPU: AMD"
        GPU_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon)
    fi
    if lspci | grep -qi "Intel"; then 
        log_info "GPU: Intel"
        GPU_PKGS+=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel)
    fi
    
    IS_LAPTOP="false"
    if grep -EEq "^(8|9|10|14|31|32)$" /sys/class/dmi/id/chassis_type 2>/dev/null; then
        IS_LAPTOP="true"
        log_info "Tipo: Laptop"
    else
        log_info "Tipo: Desktop"
    fi
}

install_base() {
    log_info "Configurando Pacman..."
    sed -i 's/^#Parallel/Parallel/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    
    # CRÍTICO: Habilitar Multilib na ISO AGORA para o pacstrap encontrar lib32-*
    log_info "Habilitando Multilib na ISO..."
    cat >> /etc/pacman.conf <<EOF
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    pacman -Syy

    log_info "Atualizando Mirrors..."
    reflector --country Brazil --country 'United States' --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    detect_hw
    
    # Lista consolidada (Sem AUR)
    PKG_LIST=(
        "${PKGS_BASE[@]}" "$KERNEL" "$K_HEADERS" "$UCODE" 
        "${PKGS_SYS[@]}" "${PKGS_SEC[@]}" "${PKGS_NET[@]}" "${PKGS_FS[@]}" 
        "${PKGS_AUDIO[@]}" "${PKGS_PRINT[@]}" "${PKGS_FONTS[@]}" 
        "${PKGS_APPS[@]}" "${PKGS_DEV[@]}" "${PKGS_THEMES[@]}" 
        "${PKGS_SWAY[@]}" "${GPU_PKGS[@]}"
    )
    
    if [[ "$IS_LAPTOP" == "true" ]]; then PKG_LIST+=("${PKGS_LAPTOP[@]}"); fi
    if [[ "$OPT_GAME" == "y" ]]; then PKG_LIST+=("${PKGS_GAME[@]}"); fi
    if [[ "$OPT_HIB" != "y" ]]; then PKG_LIST+=("zram-generator"); fi

    log_info "Instalando pacotes (Isso pode demorar)..."
    pacstrap -K /mnt "${PKG_LIST[@]}"
    
    log_info "Gerando fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
}

config_system() {
    log_info "Configurando sistema interno..."
    cat <<EOF > /mnt/setup.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME_VAL" > /etc/hostname

# Habilitar Multilib no sistema ALVO
cat >> /etc/pacman.conf <<PAC
[multilib]
Include = /etc/pacman.d/mirrorlist
PAC
pacman -Sy

useradd -m -G wheel,video,storage,docker -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Bootloader (Sem Plymouth, apenas Systemd padrão)
bootctl install
# Hooks padrão do Arch + LVM + Encrypt
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "title Arch Linux" > /boot/loader/entries/arch.conf
echo "linux /vmlinuz-$KERNEL" >> /boot/loader/entries/arch.conf
echo "initrd /$UCODE.img" >> /boot/loader/entries/arch.conf
echo "initrd /initramfs-$KERNEL.img" >> /boot/loader/entries/arch.conf
echo "options rd.luks.name=\$(blkid -s UUID -o value $P_ROOT)=cryptroot root=/dev/mapper/vg0-root rw quiet" >> /boot/loader/entries/arch.conf

echo "default arch.conf" > /boot/loader/loader.conf

# Serviços
systemctl enable NetworkManager bluetooth firewalld apparmor docker fstrim.timer reflector.timer ly
[[ "$IS_LAPTOP" == "true" ]] && systemctl enable tlp

# Config Sway Básica
mkdir -p /home/$USER_NAME/.config/sway
cat <<SWAY > /home/$USER_NAME/.config/sway/config
# Default Config
include /etc/sway/config
set \\\$mod Mod4
set \\\$term foot
set \\\$menu dmenu_path | dmenu | xargs swaymsg exec --

exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec nm-applet --indicator
exec blueman-applet
exec mako
exec wl-paste --watch cliphist store

# Theme settings
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
SWAY
chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config

EOF
    chmod +x /mnt/setup.sh
    arch-chroot /mnt /setup.sh
    rm /mnt/setup.sh
}

# --- EXECUÇÃO ---
pre_flight
collect_input
prepare_disk
install_base
config_system

echo ""
log_succ "Instalação Finalizada!"
log_info "1. Remova o pendrive."
log_info "2. Digite 'reboot'."
log_info "3. Instale 'yay' manualmente depois para temas e extras."
