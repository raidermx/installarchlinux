#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================================
# Instalador de pós-instalação para Debian + XFCE + Btrfs
# Perfil: desktop leve para OptiPlex i5 3ª geração / 8 GB RAM / HDD 500 GB
# Uso: sudo bash instalar_debian_xfce_btrfs_optiplex.sh
# Observação: este script NÃO particiona nem instala o Debian base.
# Ele automatiza a configuração completa APÓS a instalação base do Debian.
# ================================================================

LOG="/var/log/instalar_debian_xfce_btrfs_optiplex.log"
exec > >(tee -a "$LOG") 2>&1

trap 'echo "[ERRO] Falha na linha $LINENO. Veja o log em: $LOG"' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Execute como root: sudo bash $0"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" && ! -f "$f.bak" ]]; then
    cp -a "$f" "$f.bak"
  fi
}

apt_install() {
  local pkgs=()
  for p in "$@"; do
    pkgs+=("$p")
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

apt_install_recommends() {
  local pkgs=()
  for p in "$@"; do
    pkgs+=("$p")
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

msg() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

ensure_debian() {
  if [[ ! -f /etc/debian_version ]]; then
    echo "Este script foi feito para Debian. Abortando."
    exit 1
  fi
}

enable_nonfree_repos() {
  msg "Habilitando componentes contrib, non-free e non-free-firmware"

  local sources_files=(/etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list)
  for f in "${sources_files[@]}"; do
    [[ -e "$f" ]] || continue
    backup_file "$f"

    if [[ "$f" == *.sources ]]; then
      sed -Ei '/^Components:/ {
        /contrib/! s/$/ contrib/
        /non-free([ -]firmware)?/! s/$/ non-free non-free-firmware/
      }' "$f"
    else
      sed -Ei '/^[[:space:]]*deb / {
        / contrib /! s/$/ contrib/
        / non-free([[:space:]]|$)/! s/$/ non-free/
        / non-free-firmware([[:space:]]|$)/! s/$/ non-free-firmware/
      }' "$f"
    fi
  done
}

update_system() {
  msg "Atualizando índices e sistema"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_base_tools() {
  msg "Instalando ferramentas base"
  apt_install_recommends \
    sudo curl wget ca-certificates gnupg2 software-properties-common \
    apt-transport-https lsb-release git unzip zip p7zip-full unrar-free \
    htop btop neofetch fastfetch vim nano rsync bash-completion \
    network-manager network-manager-gnome \
    policykit-1 gvfs gvfs-backends udisks2 dosfstools ntfs-3g exfatprogs \
    file-roller thunar-archive-plugin thunar-volman tumbler tumbler-plugins-extra \
    cups system-config-printer simple-scan avahi-daemon
}

install_xfce() {
  msg "Instalando ambiente gráfico XFCE"
  export DEBIAN_FRONTEND=noninteractive
  echo 'lightdm shared/default-x-display-manager select lightdm' | debconf-set-selections || true
  apt_install_recommends task-xfce-desktop xfce4-goodies lightdm lightdm-gtk-greeter
  systemctl enable lightdm || true
  systemctl enable NetworkManager || true
}

install_office_suite() {
  msg "Instalando suíte de escritório"
  apt_install_recommends \
    libreoffice libreoffice-l10n-pt-br hunspell-pt-br hyphen-pt-br mythes-pt-br \
    evince okular thunderbird firefox-esr
}

install_graphics_stack() {
  msg "Instalando kit gráfico / imagem / áudio / vídeo"
  apt_install_recommends \
    gimp inkscape krita blender darktable scribus font-manager \
    vlc mpv ffmpeg handbrake audacity obs-studio kdenlive \
    cheese simplescreenrecorder
}

install_dev_and_utilities() {
  msg "Instalando utilitários e ferramentas extras"
  apt_install_recommends \
    synaptic gdebi gparted dmidecode smartmontools lm-sensors \
    build-essential pkg-config python3 python3-pip
}

install_btrfs_and_snapshots() {
  msg "Instalando ferramentas Btrfs e snapshots"
  apt_install_recommends btrfs-progs timeshift

  # Instala grub-btrfs apenas se disponível no repositório da versão atual.
  if apt-cache show grub-btrfs >/dev/null 2>&1; then
    apt_install_recommends grub-btrfs
  fi
}

install_codecs_and_firmware() {
  msg "Instalando codecs e firmware"
  apt_install_recommends \
    firmware-linux firmware-linux-nonfree firmware-realtek firmware-iwlwifi \
    intel-microcode \
    gstreamer1.0-libav gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
}

configure_zram() {
  msg "Configurando ZRAM"
  apt_install_recommends zram-tools
  backup_file /etc/default/zramswap || true
  cat > /etc/default/zramswap <<'EOF'
# ZRAM para desktop com 8 GB RAM
ALGO=zstd
PERCENT=75
PRIORITY=100
EOF
  systemctl enable zramswap.service || true
  systemctl restart zramswap.service || true
}

configure_sysctl() {
  msg "Aplicando ajustes de sysctl"
  cat > /etc/sysctl.d/99-desktop-optiplex.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=15
fs.inotify.max_user_watches=524288
EOF
  sysctl --system || true
}

configure_journald() {
  msg "Limitando uso de logs do journald"
  backup_file /etc/systemd/journald.conf
  if grep -q '^#\?SystemMaxUse=' /etc/systemd/journald.conf; then
    sed -Ei 's/^#?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
  else
    printf '\nSystemMaxUse=200M\n' >> /etc/systemd/journald.conf
  fi
  if grep -q '^#\?RuntimeMaxUse=' /etc/systemd/journald.conf; then
    sed -Ei 's/^#?RuntimeMaxUse=.*/RuntimeMaxUse=100M/' /etc/systemd/journald.conf
  else
    printf 'RuntimeMaxUse=100M\n' >> /etc/systemd/journald.conf
  fi
  systemctl restart systemd-journald || true
}

configure_btrfs_mounts_if_needed() {
  msg "Verificando se a raiz está em Btrfs para aplicar otimizações de montagem"

  local rootfs
  rootfs="$(findmnt -n -o FSTYPE / || true)"
  if [[ "$rootfs" != "btrfs" ]]; then
    echo "Raiz não está em Btrfs. Pulando otimizações específicas do Btrfs."
    return 0
  fi

  backup_file /etc/fstab
  python3 - <<'PY'
from pathlib import Path
fstab = Path('/etc/fstab')
text = fstab.read_text(encoding='utf-8')
lines = text.splitlines()
out = []
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        out.append(line)
        continue
    parts = stripped.split()
    if len(parts) < 4:
        out.append(line)
        continue
    mountpoint = parts[1]
    fstype = parts[2]
    options = parts[3].split(',')
    if mountpoint == '/' and fstype == 'btrfs':
        wanted = ['noatime', 'compress=zstd:3', 'space_cache=v2', 'autodefrag']
        for w in wanted:
            key = w.split('=')[0]
            if not any(o == w or o.startswith(key+'=') for o in options):
                options.append(w)
        parts[3] = ','.join(options)
        out.append('\t'.join(parts))
    elif mountpoint == '/home' and fstype == 'btrfs':
        wanted = ['noatime', 'compress=zstd:3', 'space_cache=v2', 'autodefrag']
        for w in wanted:
            key = w.split('=')[0]
            if not any(o == w or o.startswith(key+'=') for o in options):
                options.append(w)
        parts[3] = ','.join(options)
        out.append('\t'.join(parts))
    else:
        out.append(line)
fstab.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY

  mkdir -p /.snapshots
  if command -v btrfs >/dev/null 2>&1; then
    if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
      echo "Subvolume /.snapshots já existe."
    else
      if ! btrfs subvolume create /.snapshots; then
        echo "Não foi possível criar /.snapshots automaticamente."
      fi
    fi
  fi
}

configure_apt_and_cleanup() {
  msg "Otimizando APT e limpando pacotes"
  cat > /etc/apt/apt.conf.d/80lean-desktop <<'EOF'
APT::Install-Recommends "true";
APT::Install-Suggests "false";
Acquire::Retries "3";
DPkg::Use-Pty "0";
EOF

  apt-get autoremove -y
  apt-get autoclean -y
  apt-get clean
}

configure_ssd_trim_if_applicable() {
  msg "Verificando se o disco do sistema é SSD"
  local root_source disk pkname rotational
  root_source="$(findmnt -n -o SOURCE / || true)"
  if [[ -z "$root_source" ]]; then
    return 0
  fi

  pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  if [[ -z "$pkname" ]]; then
    disk="$(basename "$root_source" | sed 's/[0-9]*$//')"
  else
    disk="$pkname"
  fi

  if [[ -n "$disk" && -r "/sys/block/$disk/queue/rotational" ]]; then
    rotational="$(cat "/sys/block/$disk/queue/rotational")"
    if [[ "$rotational" == "0" ]]; then
      echo "SSD detectado: ativando fstrim.timer"
      systemctl enable fstrim.timer || true
      systemctl start fstrim.timer || true
    else
      echo "Disco rotacional detectado (HDD): fstrim não será ativado."
    fi
  fi
}

configure_lightdm_greeter() {
  msg "Ajustando greeter do LightDM"
  mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d
  cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/99-local.conf <<'EOF'
[greeter]
theme-name=Adwaita
icon-theme-name=Adwaita
font-name=Sans 10
clock-format=%d/%m/%Y %H:%M
EOF
}

final_message() {
  msg "Concluído"
  echo "Script finalizado com sucesso."
  echo "Log: $LOG"
  echo
  echo "Recomendações finais:"
  echo "1) Reinicie o sistema."
  echo "2) Abra o Timeshift e configure snapshots."
  echo "3) Se você ainda estiver usando HDD, o maior ganho de desempenho virá de trocar para SSD."
}

main() {
  require_root
  ensure_debian
  enable_nonfree_repos
  update_system
  install_base_tools
  install_xfce
  install_office_suite
  install_graphics_stack
  install_dev_and_utilities
  install_btrfs_and_snapshots
  install_codecs_and_firmware
  configure_zram
  configure_sysctl
  configure_journald
  configure_btrfs_mounts_if_needed
  configure_ssd_trim_if_applicable
  configure_lightdm_greeter
  configure_apt_and_cleanup
  final_message
}

main "$@"
