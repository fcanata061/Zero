#!/bin/bash
set -euo pipefail

## ========= CONFIG =========
export LFS=/mnt/lfs                 # ponto de montagem do LFS
DISK=/dev/sdX                       # <<< AJUSTE! disco alvo (ex.: /dev/sda)
PART=${DISK}1                       # partição (ex.: /dev/sda1)
DO_PARTITION=yes                    # yes = cria tabela GPT e partição única
FS_TYPE=ext4
HOST_PKGS="bash coreutils curl gawk file findutils gcc g++ make tar xz gzip bzip2 zstd patch sed grep perl python3 git parted e2fsprogs texinfo"

## ========= CHECKS =========
[ "$(id -u)" = "0" ] || { echo "Precisa ser root"; exit 1; }
command -v parted >/dev/null || { echo "Instale 'parted'"; exit 1; }

echo "[*] Conferindo pacotes do host..."
for p in $HOST_PKGS; do command -v ${p%% *} >/dev/null 2>&1 || echo "  - faltando: $p"; done

## ========= PARTIÇÃO & FS =========
if [ "$DO_PARTITION" = "yes" ]; then
  echo "[*] Criando tabela GPT e partição em $DISK"
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary ${FS_TYPE} 1MiB 100%
fi

echo "[*] Criando sistema de arquivos $FS_TYPE em $PART"
mkfs.$FS_TYPE -F "$PART"

## ========= MONTAGEM E ÁRVORE =========
mkdir -p "$LFS"
mount "$PART" "$LFS"

echo "[*] Criando hierarquia inicial"
mkdir -pv $LFS/{bin,boot,etc,home,lib,lib64,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}
mkdir -pv $LFS/usr/{bin,lib,sbin,share,include}
mkdir -pv $LFS/var/{log,lib,cache,spool}
install -dv -m 0750 $LFS/root
chmod 1777 $LFS/tmp
mkdir -pv $LFS/tools

## ========= USUÁRIO LFS =========
if ! id lfs >/dev/null 2>&1; then
  echo "[*] Criando usuário e grupo 'lfs'"
  groupadd lfs
  useradd -s /bin/bash -g lfs -m -k /dev/null lfs
  echo "lfs:lfs" | chpasswd
fi
chown -v lfs $LFS/{usr,lib,var,etc,bin,sbin,tools,home,root,tmp} || true

## ========= PERFIL DO USUÁRIO LFS =========
su - lfs -c 'cat > ~/.bash_profile << "EOF"
exec env -i HOME=$HOME TERM=$TERM PS1="\\u:\\w\\$ " /bin/bash
EOF'

su - lfs -c 'cat > ~/.bashrc << "EOF"
set +h
umask 022
export LFS='"$LFS"'
export LC_ALL=POSIX
export LFS_TGT=$(uname -m)-lfs-linux-gnu
export PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
export PATH=$LFS/tools/bin:$PATH
EOF'

echo "[OK] Parte 1 concluída. Próximo: ./02-toolchain.sh"
