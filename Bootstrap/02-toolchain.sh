#!/bin/bash
set -euo pipefail

## ========= CONFIG DE VERSÕES =========
export LFS=${LFS:-/mnt/lfs}
SRC=$LFS/sources
JOBS=${JOBS:-$(nproc)}

# Versões (ajuste se quiser)
BINUTILS_V=2.42
GCC_V=14.2.0
LINUX_V=6.10
GLIBC_V=2.40
MPFR_V=4.2.1
GMP_V=6.3.0
MPC_V=1.3.1

# URLs oficiais
GNU=https://ftp.gnu.org/gnu
KERNEL=https://www.kernel.org/pub

BINUTILS_T=binutils-$BINUTILS_V.tar.xz
GCC_T=gcc-$GCC_V.tar.xz
LINUX_T=linux-$LINUX_V.tar.xz
GLIBC_T=glibc-$GLIBC_V.tar.xz
MPFR_T=mpfr-$MPFR_V.tar.xz
GMP_T=gmp-$GMP_V.tar.xz
MPC_T=mpc-$MPC_V.tar.gz

## ========= PREP =========
[ "$(id -u)" = "0" ] || { echo "Rode como root"; exit 1; }
[ -d "$LFS/tools" ] || { echo "Crie $LFS/tools (rode Parte 1)"; exit 1; }

mkdir -pv "$SRC"
chmod -v a+wt "$SRC"

download() {
  local url="$1" out="$2"
  [ -f "$SRC/$out" ] || curl -L "$url" -o "$SRC/$out"
}

echo "[*] Baixando fontes (cache em $SRC)"
download $GNU/binutils/$BINUTILS_T            $BINUTILS_T
download $GNU/gcc/$GCC_T                      $GCC_T
download $KERNEL/linux/kernel/v6.x/$LINUX_T   $LINUX_T
download $GNU/glibc/$GLIBC_T                  $GLIBC_T
download $GNU/mpfr/$MPFR_T                    $MPFR_T
download $GNU/gmp/$GMP_T                      $GMP_T
download $GNU/mpc/$MPC_T                      $MPC_T

chown -v lfs $SRC/*

## ========= EXECUTAR COMO USUÁRIO LFS =========
su - lfs <<'EOF_LFS'
set -euo pipefail

JOBS=${JOBS:-'$(nproc)'}
LFS=${LFS:-/mnt/lfs}
SRC=$LFS/sources

enter() { cd "$SRC"; tar -xf "$1"; cd "${1%.tar.*}"; }

## ===== Binutils - Pass 1 =====
cd "$SRC"
tar -xf binutils-*.tar.xz
cd binutils-*/
mkdir -v build && cd build
../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT   \
             --disable-nls       \
             --enable-gprofng=no \
             --disable-werror
make -j"$JOBS"
make install
cd "$SRC"
rm -rf binutils-*/

## ===== GCC - Pass 1 =====
cd "$SRC"
tar -xf gcc-*.tar.xz
cd gcc-*/
# Incluir gmp, mpfr, mpc dentro da árvore do gcc
tar -xf $SRC/gmp-*.tar.xz
tar -xf $SRC/mpfr-*.tar.xz
tar -xf $SRC/mpc-*.tar.gz
mv -v gmp-* gmp
mv -v mpfr-* mpfr
mv -v mpc-* mpc

mkdir -v build && cd build
../configure                                      \
  --target=$LFS_TGT                               \
  --prefix=$LFS/tools                             \
  --with-glibc-version=2.40                       \
  --with-sysroot=$LFS                             \
  --with-newlib                                   \
  --without-headers                               \
  --enable-default-pie                            \
  --enable-default-ssp                            \
  --disable-nls                                   \
  --disable-shared                                \
  --disable-multilib                              \
  --disable-threads                               \
  --disable-libatomic                             \
  --disable-libgomp                               \
  --disable-libquadmath                           \
  --disable-libssp                                \
  --disable-libvtv                                \
  --enable-languages=c
make -j"$JOBS"
make install
cd "$SRC"
rm -rf gcc-*/

## ===== Linux API Headers =====
cd "$SRC"
tar -xf linux-*.tar.xz
cd linux-*/
make mrproper
make headers
find usr/include -name '.*' -delete
rm -f usr/include/Makefile
mkdir -pv $LFS/usr
cp -rv usr/include $LFS/usr
cd "$SRC"
rm -rf linux-*/

## ===== Glibc =====
cd "$SRC"
tar -xf glibc-*.tar.xz
cd glibc-*/
mkdir -v build && cd build
../configure                             \
      --prefix=/usr                      \
      --host=$LFS_TGT                    \
      --build=$(../scripts/config.guess) \
      --enable-kernel=4.19               \
      --with-headers=$LFS/usr/include    \
      libc_cv_slibdir=/usr/lib
make -j"$(nproc)"
make DESTDIR=$LFS install
# Config mínimos
echo 'roots:x:0:0:root:/root:/bin/bash' > $LFS/etc/passwd || true
echo 'root:x:0:' > $LFS/etc/group || true
ln -sv $LFS/tools/bin/{bash,cat,echo,pwd,stty} $LFS/bin/ || true
ln -sv $LFS/tools/bin/perl $LFS/usr/bin || true
ln -sv $LFS/tools/lib/libgcc_s.so{,.1} $LFS/usr/lib || true || true
ln -sv $LFS/tools/lib/libstdc++.so{.6,} $LFS/usr/lib || true
cd "$SRC"
rm -rf glibc-*/

## ===== Libstdc++ (a partir do GCC pass1) =====
cd "$SRC"
tar -xf gcc-*.tar.xz
cd gcc-*/
mkdir -v build && cd build
../libstdc++-v3/configure         \
    --host=$LFS_TGT               \
    --build=$(../config.guess)    \
    --prefix=/usr                 \
    --disable-multilib            \
    --disable-nls                 \
    --disable-libstdcxx-pch
make -j"$(nproc)"
make DESTDIR=$LFS install
cd "$SRC"
rm -rf gcc-*/

## ===== Binutils - Pass 2 =====
cd "$SRC"
tar -xf binutils-*.tar.xz
cd binutils-*/
mkdir -v build && cd build
CC=$LFS_Tools/bin/cc CXX=$LFS_Tools/bin/c++ \
../configure --prefix=/usr          \
             --build=$(../config.guess) \
             --host=$LFS_TGT        \
             --disable-nls          \
             --enable-shared        \
             --enable-gold=yes      \
             --enable-plugins
make -j"$(nproc)"
make DESTDIR=$LFS install
install -vm755 libctf/.libs/libctf.so.0.0.0 $LFS/usr/lib || true
cd "$SRC"
rm -rf binutils-*/

## ===== GCC - Pass 2 =====
cd "$SRC"
tar -xf gcc-*.tar.xz
cd gcc-*/
# Incluir deps
tar -xf $SRC/gmp-*.tar.xz; mv -v gmp-* gmp
tar -xf $SRC/mpfr-*.tar.xz; mv -v mpfr-* mpfr
tar -xf $SRC/mpc-*.tar.gz;  mv -v mpc-*  mpc

mkdir -v build && cd build
../configure                                      \
  --build=$(../config.guess)                      \
  --host=$LFS_TGT                                 \
  --target=$LFS_TGT                               \
  --prefix=/usr                                   \
  --with-build-sysroot=$LFS                       \
  --enable-default-pie                            \
  --enable-default-ssp                            \
  --disable-multilib                              \
  --disable-bootstrap                             \
  --disable-nls                                   \
  --enable-languages=c,c++
make -j"$(nproc)"
make DESTDIR=$LFS install
ln -sv gcc $LFS/usr/bin/cc || true

echo "[OK] Toolchain temporária concluída."
EOF_LFS

echo "[OK] Parte 2 concluída. Próximo: ./03-chroot-and-prepare-zero.sh"
