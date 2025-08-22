#!/bin/bash
# ========================
# Zero Package Manager
# Minimalista, Source-Based
# ========================

# ----- Utils -----
msg()   { [ "$ZERO_COLOR" = "1" ] && echo -e "\033[1;32m==>\033[0m $*" || echo "==> $*"; }
warn()  { [ "$ZERO_COLOR" = "1" ] && echo -e "\033[1;33m[!] \033[0m$*" || echo "[!] $*"; }
err()   { echo "[erro] $*" >&2; exit 1; }
spinner() {
  while kill -0 $1 2>/dev/null; do
    for s in / - \\ \|; do
      echo -ne "\r[$s] $2 $s"
      sleep 0.1
    done
  done
  echo -ne "\r[✔] $2\n"
}

# ----- Helpers -----
deps_of()    { [ -f "$ZERO_RECIPES/$1/deps" ] && cat "$ZERO_RECIPES/$1/deps"; }
version_of() { [ -f "$ZERO_RECIPES/$1/version" ] && cat "$ZERO_RECIPES/$1/version"; }
source_of()  { [ -f "$ZERO_RECIPES/$1/source" ] && cat "$ZERO_RECIPES/$1/source"; }

resolve_deps() {
  local pkg=$1
  for dep in $(deps_of $pkg); do
    resolve_deps $dep
    echo $dep
  done | awk '!seen[$0]++'
}

# ----- Core Actions -----
fetch_sources() {
  local pkg=$1 url=$(source_of $pkg)
  [ -z "$url" ] && return
  mkdir -p "$ZERO_SRC"
  cd "$ZERO_SRC" || err "Não consegui entrar em $ZERO_SRC"
  case $url in
    *.git) git clone --depth 1 "$url" "$pkg" ;;
    *) curl -LO "$url" ;;
  esac
}

extract_sources() {
  local pkg=$1 url=$(source_of $pkg)
  mkdir -p "$ZERO_BUILD/$pkg"
  cd "$ZERO_BUILD/$pkg" || err "Falha em $ZERO_BUILD/$pkg"
  case $url in
    *.tar.gz|*.tgz)   tar xf "$ZERO_SRC/$(basename $url)" ;;
    *.tar.xz)         tar xf "$ZERO_SRC/$(basename $url)" ;;
    *.tar.bz2)        tar xf "$ZERO_SRC/$(basename $url)" ;;
    *.zip)            unzip -q "$ZERO_SRC/$(basename $url)" ;;
    *.git)            cp -r "$ZERO_SRC/$pkg"/* . ;;
  esac
}

apply_patches() {
  local pkg=$1
  [ -d "$ZERO_RECIPES/$pkg/patch" ] || return
  for p in "$ZERO_RECIPES/$pkg/patch/"*.patch; do
    [ -f "$p" ] && patch -p1 < "$p"
  done
}

build_pkg() {
  local pkg=$1
  local build="$ZERO_RECIPES/$pkg/build"
  [ -x "$build" ] || err "Sem script de build para $pkg"
  DESTDIR="$ZERO_STAGE/$pkg" bash "$build" >"$ZERO_LOG/$pkg.build.log" 2>&1 &
  spinner $! "compilando $pkg"
}

install_pkg() {
  local pkg=$1
  msg "Instalando $pkg"
  cp -a "$ZERO_STAGE/$pkg"/* "$ZERO_PREFIX" || err "Falha ao instalar $pkg"
  version_of $pkg > "$ZERO_DB/$pkg.version"
}

remove_pkg() {
  local pkg=$1
  [ -f "$ZERO_DB/$pkg.version" ] || { warn "$pkg não está instalado"; return; }
  msg "Removendo $pkg"
  # Simples: remove arquivos listados no DESTDIR
  # (poderia gerar lista na instalação para remoção mais precisa)
  rm -rf "$ZERO_PREFIX/$(ls "$ZERO_STAGE/$pkg")"
  rm -f "$ZERO_DB/$pkg.version"
}

upgrade_pkg() {
  local pkg=$1
  local newv=$(version_of $pkg)
  local oldv=$(cat "$ZERO_DB/$pkg.version" 2>/dev/null || echo 0)
  [ "$newv" \> "$oldv" ] && { $0 build $pkg; $0 install $pkg; }
}

world() {
  while read -r pkg; do
    $0 build $pkg
  done < "$ZERO_WORLD"
}

orphans() {
  for f in "$ZERO_DB"/*.version; do
    pkg=$(basename "$f" .version)
    needed=$(grep -R "$pkg" "$ZERO_RECIPES"/*/deps || true)
    [ -z "$needed" ] && echo "$pkg"
  done
}

sync_repo() {
  cd "$ZERO_GIT" || err "Sem repo git"
  git add .
  git commit -m "sync"
  git push
}

# ----- CLI -----
case $1 in
  fetch)    shift; fetch_sources $1 ;;
  extract)  shift; extract_sources $1 ;;
  patch)    shift; apply_patches $1 ;;
  build)
    shift
    for dep in $(resolve_deps $1); do
      [ -f "$ZERO_DB/$dep.version" ] || { 
        fetch_sources $dep
        extract_sources $dep
        apply_patches $dep
        build_pkg $dep
        install_pkg $dep
      }
    done
    fetch_sources $1
    extract_sources $1
    apply_patches $1
    build_pkg $1
    install_pkg $1
    ;;
  install)  shift; install_pkg $1 ;;
  remove)   shift; remove_pkg $1 ;;
  upgrade)  shift; upgrade_pkg $1 ;;
  world)    world ;;
  orphans)  orphans ;;
  sync)     sync_repo ;;
  *) echo "Uso: $0 {fetch|extract|patch|build|install|remove|upgrade|world|orphans|sync} pkg" ;;
esac
