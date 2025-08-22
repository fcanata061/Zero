#!/bin/bash
# =============================
# Zero — Gerenciador de Pacotes
# =============================

set -euo pipefail

# -------- Utils --------------
msg() { [ "$ZERO_COLOR" = "1" ] && echo -e "\033[1;32m==>\033[0m $*" || echo "==> $*"; }
warn() { [ "$ZERO_COLOR" = "1" ] && echo -e "\033[1;33m[!] \033[0m$*" || echo "[!] $*"; }
err() { echo "[erro] $*" >&2; exit 1; }
spinner() {
  while kill -0 $1 2>/dev/null; do
    for s in / - \\ \|; do
      echo -ne "\r[$s] $2"
      sleep 0.1
    done
  done
  echo -ne "\r[✔] $2\n"
}

# -------- Helpers ------------
recipe_dir()   { echo "$ZERO_RECIPES/$1"; }
recipe_file()  { echo "$(recipe_dir $1)/$2"; }
version_of()   { cat "$(recipe_file $1 version)"; }
deps_of()      { [ -f "$(recipe_file $1 deps)" ] && cat "$(recipe_file $1 deps)" || true; }
sources_of()   { cat "$(recipe_file $1 source)"; }

# -------- Fetch --------------
fetch_sources() {
  local pkg=$1
  mkdir -p "$ZERO_SRC/$pkg"
  while read -r src; do
    case $src in
      git+*)
        url=${src#git+}
        ref=""
        [[ $url == *"@"* ]] && ref="${url##*@}" url="${url%@*}"
        dest="$ZERO_SRC/$pkg/$(basename $url .git)"
        if [ ! -d "$dest/.git" ]; then
          git clone "$url" "$dest"
        fi
        (cd "$dest" && git fetch && [ -n "$ref" ] && git checkout "$ref" || true)
        ;;
      *)
        file="$ZERO_SRC/$pkg/$(basename $src)"
        [ -f "$file" ] || curl -L "$src" -o "$file"
        ;;
    esac
  done <<< "$(sources_of $pkg)"
}

# -------- Extract ------------
extract_sources() {
  local pkg=$1
  rm -rf "$ZERO_BUILD/$pkg" && mkdir -p "$ZERO_BUILD/$pkg"
  while read -r src; do
    case $src in
      git+*)
        url=${src#git+}
        url="${url%@*}"
        cp -r "$ZERO_SRC/$pkg/$(basename $url .git)" "$ZERO_BUILD/$pkg/"
        ;;
      *)
        file="$ZERO_SRC/$pkg/$(basename $src)"
        tar -xf "$file" -C "$ZERO_BUILD/$pkg"
        ;;
    esac
  done <<< "$(sources_of $pkg)"
}

# -------- Patch --------------
apply_patches() {
  local pkg=$1
  local dir="$ZERO_BUILD/$pkg"
  [ -d "$(recipe_dir $pkg)/patch" ] || return 0
  for p in $(recipe_dir $pkg)/patch/*.patch; do
    [ -f "$p" ] || continue
    (cd "$dir"/* && patch -Np1 -i "$p")
  done
}

# -------- Build --------------
build_pkg() {
  local pkg=$1
  mkdir -p "$ZERO_STAGE/$pkg" "$ZERO_LOG"
  local logf="$ZERO_LOG/$pkg.build.log"
  ( DESTDIR="$ZERO_STAGE/$pkg" bash "$(recipe_file $pkg build)" ) >"$logf" 2>&1 &
  spinner $! "build $pkg"
}

# -------- Install ------------
install_pkg() {
  local pkg=$1
  local v=$(version_of $pkg)
  [ -d "$ZERO_STAGE/$pkg" ] || err "$pkg não foi compilado"
  cp -a "$ZERO_STAGE/$pkg"/* "$ZERO_PREFIX"/
  echo "$v" > "$ZERO_DB/$pkg.version"
  msg "$pkg $v instalado"
}

# -------- Remove -------------
remove_pkg() {
  local pkg=$1
  [ -f "$ZERO_DB/$pkg.version" ] || err "$pkg não está instalado"
  grep -oP "^/.*" "$ZERO_LOG/$pkg.build.log" | while read -r f; do
    rm -rf "$ZERO_PREFIX/$f"
  done || true
  rm -rf "$ZERO_DB/$pkg.version"
  msg "$pkg removido"
}

# -------- Upgrade ------------
upgrade_pkg() {
  local pkg=$1
  local nv=$(version_of $pkg)
  [ -f "$ZERO_DB/$pkg.version" ] || { msg "$pkg não instalado"; return; }
  local ov=$(cat "$ZERO_DB/$pkg.version")
  [ "$nv" \> "$ov" ] || { msg "$pkg já na versão $ov"; return; }
  zero build $pkg && zero install $pkg
}

# -------- World --------------
world() {
  while read -r pkg; do
    zero build $pkg && zero install $pkg
  done < "$ZERO_WORLD"
}

# -------- Orphans ------------
orphans() {
  for p in $(ls "$ZERO_DB"/*.version 2>/dev/null | xargs -n1 basename | sed 's/.version//'); do
    needed=0
    for q in $(ls "$ZERO_DB"/*.version 2>/dev/null | xargs -n1 basename | sed 's/.version//'); do
      grep -qw "$p" "$(recipe_file $q deps)" 2>/dev/null && needed=1
    done
    [ $needed -eq 0 ] && echo "$p"
  done
}

# -------- Sync ---------------
sync_repo() {
  (cd "$ZERO_GIT" && git add . && git commit -m sync && git push)
}

# -------- CLI ----------------
case ${1:-help} in
  info)     shift; v=$(version_of $1); echo "$1 $v" ;;
  build)    shift; for p in $(deps_of $1); do $0 build $p; done; fetch_sources $1; extract_sources $1; apply_patches $1; build_pkg $1 ;;
  install)  shift; install_pkg $1 ;;
  remove)   shift; remove_pkg $1 ;;
  upgrade)  shift; upgrade_pkg $1 ;;
  list)     ls "$ZERO_DB"/*.version 2>/dev/null | sed 's/.*\\///;s/.version//' ;;
  orphans)  orphans ;;
  sync)     sync_repo ;;
  world)    world ;;
  help|*)   echo "zero [info|build|install|remove|upgrade|list|orphans|sync|world] <pkg>" ;;
esac
