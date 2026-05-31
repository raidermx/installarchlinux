#!/bin/bash
set -euo pipefail

# --- Ajuste estes valores antes de rodar ---
DISK=/dev/sda
EFI_PART=${DISK}1
SWAP_PART=${DISK}2
BTRFS_PART=${DISK}3
HOSTNAME=archlinux
USER=raidermx
TIMEZONE="America/Recife"
LOCALE="pt_BR.UTF-8"

# 1 Partitionamento (GPT)
sgdisk -Z $DISK
sgdisk -n1:0:+512M -t1:ef00 $DISK
sgdisk -n2:0:+4G -t2:8200 $DISK
sgdisk -n3:0:0 -t3:8300 $DISK
partprobe $DISK

# 2 Formatar
mkfs.fat -F32 $EFI_PART
mkswap $SWAP_PART
swapon $SWAP_PART
mkfs.btrfs -f $BTRFS_PART

# 3 Subvolumes Btrfs e montagem com compressão zstd
mount -o defaults,compress=zstd:3,ssd,space_cache=v2 $BTRFS_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ $BTRFS_PART /mnt
mkdir -p /mnt/{boot,home,var,.snapshots}
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@home $BTRFS_PART /mnt/home
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@var $BTRFS_PART /mnt/var
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@snapshots $BTRFS_PART /mnt/.snapshots
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

# 4 Instalar base
pacstrap /mnt base linux linux-firmware btrfs-progs vim sudo networkmanager
genfstab -U /mnt >> /mnt/etc/fstab

# 5 Chroot e configuração
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo $HOSTNAME > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
passwd root
useradd -m -G wheel $USER
passwd $USER
pacman -Syu --noconfirm grub efibootmgr intel-ucode

# 6 Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 7 Ambiente gráfico, drivers e serviços
pacman -S --noconfirm plasma kde-applications sddm
pacman -S --noconfirm mesa vulkan-intel pipewire pipewire-pulse wireplumber intel-ucode
systemctl enable sddm
systemctl enable NetworkManager

# 8 Pacotes multimídia, office, CAD, editores e utilitários
pacman -S --noconfirm libreoffice-fresh \
  gimp krita darktable inkscape imagemagick \
  kdenlive blender ffmpeg vlc obs-studio \
  audacity ardour \
  freecad \
  thunderbird firefox chromium \
  tlp powertop fstrim

# 9 Compactadores e utilitários de arquivo
pacman -S --noconfirm p7zip unrar unzip zip file-roller ark xarchiver

# 10 Gerenciadores de download e utilitários de rede
pacman -S --noconfirm aria2 uget axel wget curl qBittorrent transmission-gtk

# 11 AUR helper (paru) e navegadores AUR
pacman -S --noconfirm --needed base-devel git
cd /tmp
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
paru -S --noconfirm google-chrome brave-bin

# 12 Snapper e integração com Btrfs
pacman -S --noconfirm snapper grub-btrfs
snapper -c root create-config /
systemctl enable fstrim.timer
systemctl enable tlp

# 13 Otimizações de sistema
# reduzir swappiness
echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
# journal em memória para reduzir writes em SSD
sed -i 's/#Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
# habilitar parallel downloads para pacman (opcional)
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
EOF

echo ">> Desmontando partições e finalizando"
swapoff -a || true
umount -R /mnt

echo "Instalação concluída. Remova o USB e reinicie."
