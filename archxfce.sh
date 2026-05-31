#!/usr/bin/env bash
set -euo pipefail

### ===== CONFIGURAÇÕES BÁSICAS =====

DISK="/dev/sda"              # ATENÇÃO: disco será APAGADO
HOSTNAME="archlinux"
USERNAME="carlos"
USER_PASSWORD="senha123"     # troque depois
ROOT_PASSWORD="root123"      # troque depois
LOCALE="pt_BR.UTF-8"
LOCALE_FALLBACK="pt_BR.UTF-8"
KEYMAP="br-abnt2"
TIMEZONE="America/Recife"

EFI_SIZE="512MiB"

### ===== CHECAGENS INICIAIS =====

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (no live do Arch)."
  exit 1
fi

if ! ls /sys/firmware/efi/efivars &>/dev/null; then
  echo "Sistema não está em UEFI. Ative UEFI na BIOS."
  exit 1
fi

echo "=== AVISO FORTE ==="
echo "O disco $DISK será APAGADO COMPLETAMENTE."
read -rp "Digite 'SIM' para continuar: " CONFIRM
if [[ "$CONFIRM" != "SIM" ]]; then
  echo "Cancelado."
  exit 1
fi

### ===== TECLADO E REDE =====

echo ">> Ajustando teclado para $KEYMAP"
loadkeys "$KEYMAP"

echo ">> Ativando NTP"
timedatectl set-ntp true

echo ">> Verifique se tem rede (ping archlinux.org)"
ping -c 3 archlinux.org || echo "Sem resposta de ping, mas continuando..."

### ===== PARTICIONAMENTO (GPT, EFI + BTRFS) =====

echo ">> Limpando partições antigas em $DISK"
wipefs -a "$DISK"
sgdisk -Z "$DISK"

echo ">> Criando tabela GPT e partições"
parted -s "$DISK" \
  mklabel gpt \
  mkpart ESP fat32 1MiB "$EFI_SIZE" \
  set 1 esp on \
  mkpart primary btrfs "$EFI_SIZE" 100%

EFI_PART="${DISK}1"
BTRFS_PART="${DISK}2"

sleep 2
partprobe "$DISK"

echo "EFI:   $EFI_PART"
echo "BTRFS: $BTRFS_PART"

### ===== FORMATAR PARTIÇÕES =====

echo ">> Formatando EFI em FAT32"
mkfs.fat -F32 "$EFI_PART"

echo ">> Formatando Btrfs"
mkfs.btrfs -f "$BTRFS_PART"

### ===== CRIAR SUBVOLUMES BTRFS =====

echo ">> Criando subvolumes Btrfs"
mount "$BTRFS_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@snapshots

umount /mnt

### ===== MONTAGEM COM OPÇÕES OTIMIZADAS =====

echo ">> Montando subvolumes Btrfs"

mount -o noatime,compress=zstd,space_cache=v2,ssd,subvol=@ "$BTRFS_PART" /mnt

mkdir -p /mnt/{home,var/log,var/cache,.snapshots,boot}
mount -o noatime,compress=zstd,space_cache=v2,ssd,subvol=@home "$BTRFS_PART" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,ssd,subvol=@log "$BTRFS_PART" /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,ssd,subvol=@cache "$BTRFS_PART" /mnt/var/cache
mount -o noatime,compress=zstd,space_cache=v2,ssd,subvol=@snapshots "$BTRFS_PART" /mnt/.snapshots

mount "$EFI_PART" /mnt/boot

### ===== INSTALAÇÃO BASE =====

echo ">> Atualizando mirrors (opcional, pode comentar se quiser)"
pacman -Sy --noconfirm reflector
reflector --country Brazil --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true

echo ">> Instalando sistema base"
pacstrap -K /mnt \
  base linux linux-firmware \
  btrfs-progs \
  vim nano \
  networkmanager \
  intel-ucode \
  sudo

echo ">> Gerando fstab"
genfstab -U /mnt >> /mnt/etc/fstab

### ===== CHROOT E CONFIGURAÇÃO INTERNA =====

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo ">> Configurando timezone"
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo ">> Configurando locale"
sed -i "s/#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen
sed -i "s/#$LOCALE_FALLBACK UTF-8/$LOCALE_FALLBACK UTF-8/" /etc/locale.gen
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo ">> Configurando hostname e hosts"
echo "$HOSTNAME" > /etc/hostname

cat <<HOSTS >/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo ">> Senha do root"
echo "root:$ROOT_PASSWORD" | chpasswd

echo ">> Criando usuário $USERNAME"
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

echo ">> Habilitando sudo para grupo wheel"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo ">> Ativando NetworkManager"
systemctl enable NetworkManager

echo ">> Instalando bootloader (GRUB UEFI)"
pacman -S --noconfirm grub efibootmgr

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> Instalando XFCE, LightDM e Xorg"
pacman -S --noconfirm \
  xorg-server xorg-xinit \
  xfce4 xfce4-goodies \
  lightdm lightdm-gtk-greeter

systemctl enable lightdm

echo ">> Drivers Intel, áudio, rede, bluetooth"
pacman -S --noconfirm \
  mesa xf86-video-intel vulkan-intel \
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol \
  network-manager-applet \
  bluez bluez-utils blueman \
  cups system-config-printer \
  networkmanager iwd dialog firefox chromium

systemctl enable bluetooth
systemctl enable cups
systemctl enable NetworkManager

echo ">> Ativando PipeWire (user services serão ativados no login)"
# Em muitos casos não precisa habilitar manualmente, mas deixamos assim:
systemctl --global enable pipewire pipewire-pulse wireplumber || true

echo ">> Kit Office, gráfica, imagem e vídeo"
pacman -S --noconfirm \
  libreoffice-fresh libreoffice-fresh-pt-br \
  evince \
  gimp inkscape krita blender \
  kdenlive obs-studio handbrake vlc ffmpeg \
  qalculate-gtk qbittorrent uget yt-dlp \
  neovim hardinfo tmux tmate okular kate geany \
  rawtherapee darktable digikam \
  qcad librecad kicad shotcut \
  p7zip unrar unzip zip file-roller ark xarchiver \
  aria2 transmission-qt qgis octave

echo ">> Navegadores"
pacman -S --noconfirm --needed base-devel git
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay 
makepkg -si --noconfirm
yay -S --noconfirm google-chrome brave-bin

echo ">> Otimizações: pacman, energia, TRIM, firewall"
echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
sed -i 's/#Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

if ! grep -q "^

\[multilib\]

" /etc/pacman.conf; then
  cat <<MULTILIB >>/etc/pacman.conf

[multilib]
Include = /etc/pacman.d/mirrorlist
MULTILIB
fi

pacman -Syu --noconfirm

pacman -S --noconfirm tlp powertop ufw util-linux zram-generator

systemctl enable tlp
systemctl enable fstrim.timer
systemctl enable ufw
ufw --force enable

cat <<ZRAM >/etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
ZRAM

echo ">> Configuração interna concluída."
EOF

### ===== FINAL =====

echo ">> Desmontando partições e finalizando"
swapoff -a || true
umount -R /mnt

echo "Instalação concluída. Remova o pendrive e dê reboot:"
echo "reboot"
reboot
