#!/bin/bash
set -euo pipefail

## ========= CONFIG =========
# Onde ficará o zero e seus diretórios
ZERO_HOME=/root/.zero
ZERO_RECIPES=$ZERO_HOME/recipes
ZERO_LOGS=$ZERO_HOME/logs
ZERO_DB=$ZERO_HOME/db
ZERO_BUILD=$ZERO_HOME/build
ZERO_DESTDIR=$ZERO_HOME/destdir
ZERO_REPO=$ZERO_HOME/repo
JOBS=${JOBS:-$(nproc)}

# Repositório com suas receitas (para o zero assumir)
# Coloque seu git aqui, por exemplo:
RECIPE_REPO="https://github.com/SEU_USUARIO/seu-repo-zero.git"  # <<< AJUSTE OU DEIXE EM BRANCO
RECIPE_REPO_BRANCH=main

## ========= PREP =========
echo "[*] Preparando diretórios do zero"
mkdir -p "$ZERO_RECIPES" "$ZERO_LOGS" "$ZERO_DB" "$ZERO_BUILD" "$ZERO_DESTDIR" "$ZERO_REPO"

## ========= INSTALAR SCRIPT 'zero' =========
cat > /usr/bin/zero <<'EOF_ZERO'
#!/bin/bash
set -euo pipefail

: "${ZERO_HOME:=${HOME}/.zero}"
: "${ZERO_RECIPES:=$ZERO_HOME/recipes}"
: "${ZERO_LOGS:=$ZERO_HOME/logs}"
: "${ZERO_DB:=$ZERO_HOME/db}"
: "${ZERO_BUILD:=$ZERO_HOME/build}"
: "${ZERO_DESTDIR:=$ZERO_HOME/destdir}"
: "${ZERO_REPO:=$ZERO_HOME/repo}"
: "${ZERO_SOURCES:=$ZERO_HOME/sources}"
: "${ZERO_STAGE:=$ZERO_HOME/stage}"
: "${ZERO_FLAGS_DIR:=$ZERO_HOME/flags}"
: "${ZERO_REMOTES_DIR:=$ZERO_REPO/remotos}"
: "${ZERO_PREFIX:=/}"

mkdir -p "$ZERO_RECIPES" "$ZERO_LOGS" "$ZERO_DB" "$ZERO_BUILD" "$ZERO_DESTDIR" "$ZERO_REPO" "$ZERO_SOURCES" "$ZERO_STAGE" "$ZERO_FLAGS_DIR" "$ZERO_REMOTES_DIR"

log() { echo "[$(date '+%F %T')] $*"; }
die(){ echo "ERRO: $*" >&2; exit 1; }

find_recipe() {
  [[ -d "$ZERO_RECIPES/$1" ]] && { echo "$ZERO_RECIPES/$1"; return 0; }
  for r in "$ZERO_REMOTES_DIR"/*/recipes; do [[ -d "$r/$1" ]] && { echo "$r/$1"; return 0; }; done
  return 1
}
get_deps(){ local R; R="$(find_recipe "$1")" || return 0; [[ -f "$R/deps" ]] && cat "$R/deps"; }
get_flags(){ local R; R="$(find_recipe "$1")" || { echo ""; return; }; { [[ -f "$R/flags" ]] && cat "$R/flags"; [[ -f "$ZERO_FLAGS_DIR/$1" ]] && cat "$ZERO_FLAGS_DIR/$1"; } | xargs -r echo; }

download_source(){
  local pkg="$1" R url file
  R="$(find_recipe "$pkg")" || die "Receita não encontrada: $pkg"
  url="$(head -n1 "$R/source")"
  file="$ZERO_SOURCES/${url##*/}"
  [[ -f "$file" ]] || curl -L "$url" -o "$file"
  echo "$file"
}
extract_source(){
  local pkg="$1" tarball="$2" dir="$ZERO_BUILD/$pkg"
  rm -rf "$dir"; mkdir -p "$dir"
  case "$tarball" in
    *.tar.xz|*.txz) tar -C "$dir" --strip-components=1 -xf "$tarball" ;;
    *.tar.gz|*.tgz) tar -C "$dir" --strip-components=1 -xzf "$tarball" ;;
    *.tar.bz2)      tar -C "$dir" --strip-components=1 -xjf "$tarball" ;;
    *.zip)          unzip -q "$tarball" -d "$dir" && shopt -s dotglob && mv "$dir"/*/* "$dir" 2>/dev/null || true ;;
    *) die "Formato não suportado: $tarball" ;;
  esac
}

apply_patches(){
  local pkg="$1" R; R="$(find_recipe "$pkg")" || return 0
  [[ -d "$R/patch" ]] || return 0
  ( cd "$ZERO_BUILD/$pkg"
    for p in "$R"/patch/*.patch; do [ -f "$p" ] && patch -p1 < "$p"; done
  )
}

deps_resolve_recursive(){
  local pkg="$1"
  for d in $(get_deps "$pkg"); do
    deps_resolve_recursive "$d"
    echo "$d"
  done | awk '!seen[$0]++'
}

build_pkg(){
  local pkg="$1" R; R="$(find_recipe "$pkg")" || die "Receita não encontrada: $pkg"
  LOGFILE="$ZERO_LOGS/$pkg.log"
  for dep in $(deps_resolve_recursive "$pkg"); do
    [[ -f "$ZERO_DB/$dep" ]] || { build_pkg "$dep"; install_pkg "$dep"; }
  done
  local tarball; tarball="$(download_source "$pkg")"
  extract_source "$pkg" "$tarball"; apply_patches "$pkg"
  local FLAGS; FLAGS="$(get_flags "$pkg")"
  ( cd "$ZERO_BUILD/$pkg" && ZERO_FLAGS="$FLAGS" DESTDIR="$ZERO_STAGE/$pkg" bash "$R/build" ) | tee -a "$LOGFILE"
  ( cd "$ZERO_STAGE/$pkg" && find . -type f -o -type l | sed 's#^\./#/#' ) > "$ZERO_DB/$pkg.files"
}

install_pkg(){
  local pkg="$1" R; R="$(find_recipe "$pkg")" || die "Receita não encontrada: $pkg"
  [[ -f "$ZERO_DB/$pkg.files" ]] || die "Sem manifesto (build antes?): $pkg"
  ( cd "$ZERO_STAGE/$pkg" && cp -a . "$ZERO_PREFIX" )
  [[ -x "$R/post-install" ]] && "$R/post-install" || true
  echo "$pkg $(cat "$R/version")" > "$ZERO_DB/$pkg"
}

remove_pkg(){
  local pkg="$1" man="$ZERO_DB/$pkg.files"
  [[ -f "$ZERO_DB/$pkg" ]] || die "$pkg não instalado"
  if [[ -f "$man" ]]; then
    tac "$man" | while read -r f; do [[ -e "$f" || -L "$f" ]] && rm -f "$f" || true; rmdir -p "$(dirname "$f")" 2>/dev/null || true; done
  fi
  rm -f "$ZERO_DB/$pkg" "$ZERO_DB/$pkg.files"
}

show_pkg(){
  local pkg="$1" R; R="$(find_recipe "$pkg")" || die "Receita não encontrada: $pkg"
  echo "Pacote:     $pkg"
  if [[ -f "$ZERO_DB/$pkg" ]]; then awk '{print "Instalado:  "$2}' "$ZERO_DB/$pkg"; else echo "Instalado:  (não)"; fi
  echo "Disponível: $(cat "$R/version")"
  echo -n "Deps:       "; get_deps "$pkg" | xargs -r echo
  echo "Fonte:      $(head -n1 "$R/source")"
}

list_cmd(){
  case "$1" in
    installed) awk '{print $1"@"$2}' "$ZERO_DB"/* 2>/dev/null | sort || true ;;
    available)
      (cd "$ZERO_RECIPES" 2>/dev/null && ls -1) || true
      for r in "$ZERO_REMOTES_DIR"/*/recipes; do (cd "$r" 2>/dev/null && ls -1) || true; done | sort -u ;;
    *) echo "uso: zero list {installed|available}";;
  esac
}

world_cmd(){ for p in $(list_cmd installed | cut -d@ -f1); do build_pkg "$p"; install_pkg "$p"; done; }

sync_repo(){
  ( cd "$ZERO_REPO"; git add -A || true; git commit -m "zero sync $(date '+%F %T')" || true; git push || true; )
}

repo_add(){ local url="$1"; local name=$(basename "$url" .git); git clone "$url" "$ZERO_REMOTES_DIR/$name"; }
repo_update(){ for d in "$ZERO_REMOTES_DIR"/*; do [[ -d "$d/.git" ]] && (cd "$d"; git pull --rebase) || true; done; }

case "$1" in
  build) shift; build_pkg "$1" ;;
  install) shift; install_pkg "$1" ;;
  remove) shift; remove_pkg "$1" ;;
  show) shift; show_pkg "$1" ;;
  list) shift; list_cmd "$1" ;;
  world) world_cmd ;;
  sync) sync_repo ;;
  repo-add) shift; repo_add "$1" ;;
  repo-update) repo_update ;;
  *)
    cat <<EOF
uso: zero <cmd>
  build <pkg>     - compila (com deps)
  install <pkg>   - instala
  remove <pkg>    - remove
  show <pkg>      - info
  list installed  - lista instalados
  list available  - receitas disponíveis
  world           - recompila instalados
  sync            - git add/commit/push
  repo-add <git>  - adiciona repositório remoto
  repo-update     - atualiza repositórios remotos
EOF
  ;;
esac
EOF_ZERO
chmod +x /usr/bin/zero

## ========= PERFIL DO ZERO =========
cat > /etc/profile.d/zero.sh <<EOF
export ZERO_HOME="$ZERO_HOME"
export ZERO_RECIPES="$ZERO_RECIPES"
export ZERO_LOGS="$ZERO_LOGS"
export ZERO_DB="$ZERO_DB"
export ZERO_BUILD="$ZERO_BUILD"
export ZERO_DESTDIR="$ZERO_DESTDIR"
export ZERO_REPO="$ZERO_REPO"
export ZERO_SOURCES="$ZERO_HOME/sources"
export ZERO_STAGE="$ZERO_HOME/stage"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin"
EOF

## ========= CLONAR RECEITAS (OPCIONAL) =========
if [ -n "$RECIPE_REPO" ]; then
  echo "[*] Clonando receitas: $RECIPE_REPO"
  mkdir -p "$ZERO_REPO/remotos"
  cd "$ZERO_REPO/remotos"
  git clone -b "$RECIPE_REPO_BRANCH" "$RECIPE_REPO" recipes-main || true
fi

## ========= RECEITA MÍNIMA (zlib) PARA TESTE =========
# Caso não tenha repo, cria uma receita simples real (zlib) para validar o zero.
mkdir -p "$ZERO_RECIPES/zlib/patch"
cat > "$ZERO_RECIPES/zlib/source" <<'EOT'
https://zlib.net/zlib-1.3.1.tar.xz
EOT
cat > "$ZERO_RECIPES/zlib/version" <<'EOT'
1.3.1
EOT
cat > "$ZERO_RECIPES/zlib/deps" <<'EOT'
EOT
cat > "$ZERO_RECIPES/zlib/build" <<'EOT'
#!/bin/bash
set -e
./configure --prefix=/usr
make -j"$(nproc)"
make DESTDIR="$DESTDIR" install
EOT
chmod +x "$ZERO_RECIPES/zlib/build"

echo "[OK] zero instalado no chroot."
echo "Exemplo de uso dentro do chroot:"
echo "  zero build zlib && zero install zlib"
