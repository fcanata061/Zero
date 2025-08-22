#!/bin/bash
set -euo pipefail

export LFS=${LFS:-/mnt/lfs}

[ "$(id -u)" = "0" ] || { echo "Rode como root"; exit 1; }
[ -d "$LFS/tools" ] || { echo "Toolchain não encontrada. Rode a Parte 2."; exit 1; }

echo "[*] Montando sistemas de arquivos virtuais"
mount -v --bind /dev  $LFS/dev
mount -vt devpts devpts $LFS/dev/pts -o gid=5,mode=620
mount -vt proc   proc   $LFS/proc
mount -vt sysfs  sysfs  $LFS/sys
mount -vt tmpfs  tmpfs  $LFS/run
if [ -h $LFS/dev/shm ]; then
  mkdir -pv $LFS/$(readlink $LFS/dev/shm)
else
  mount -vt tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
fi

echo "[*] Arquivos básicos de config"
cat > $LFS/etc/hosts <<'EOF'
127.0.0.1 localhost
::1       localhost
EOF

cat > $LFS/etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF

cat > $LFS/etc/group <<'EOF'
root:x:0:
bin:x:1:
sys:x:2:
kmem:x:3:
tty:x:5:
daemon:x:6:
disk:x:8:
lp:x:7:
dialout:x:18:
audio:x:63:
video:x:28:
utmp:x:22:
EOF

echo "[*] Gerando /etc/profile básico (inclui zero futuramente)"
cat > $LFS/etc/profile <<'EOF'
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export LC_ALL=C
umask 022
EOF

echo "[*] Entrando em chroot (inicia Parte 4 automaticamente)..."
cat > $LFS/root/in-chroot-next.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "[*] Agora dentro do chroot."
/root/setup-zero.sh
EOF
chmod +x $LFS/root/in-chroot-next.sh

chroot "$LFS" /usr/bin/env -i \
  HOME=/root                  \
  TERM="$TERM"                \
  PS1='(lfs chroot) \u:\w\$ ' \
  PATH=/usr/bin:/usr/sbin     \
  /bin/bash --login -c "/root/in-chroot-next.sh"
