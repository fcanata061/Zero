#!/bin/bash
# zero - gerenciador de pacotes minimalista (evolução N2) - Parte 1

set -e

# ==============================
# Core util (carregado do .profile)
# ==============================
: "${ZERO_HOME:=$HOME/.zero}"
: "${ZERO_RECIPES:=$ZERO_HOME/recipes}"
: "${ZERO_LOGS:=$ZERO_HOME/logs}"
: "${ZERO_DB:=$ZERO_HOME/db}"
: "${ZERO_BUILD:=$ZERO_HOME/build}"
: "${ZERO_DESTDIR:=$ZERO_HOME/destdir}"
: "${ZERO_REPO:=$ZERO_HOME/repo}"

mkdir -p "$ZERO_RECIPES" "$ZERO_LOGS" "$ZERO_DB" "$ZERO_BUILD" "$ZERO_DESTDIR" "$ZERO_REPO"

# ==============================
# Logging
# ==============================
log_info() { echo "[$(date '+%F %T')] [INFO] $*" | tee -a "$LOGFILE"; }
log_ok()   { echo "[$(date '+%F %T')] [OK]   $*" | tee -a "$LOGFILE"; }
log_err()  { echo "[$(date '+%F %T')] [ERRO] $*" | tee -a "$LOGFILE" >&2; }

# ==============================
# Funções util
# ==============================
spinner() {
  local pid=$1
  local spin='|/-\'
  local i=0
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r[%c] " "${spin:$i:1}"
    sleep 0.1
  done
  printf "\r"
}

run_with_spinner() {
  "$@" &
  local pid=$!
  spinner $pid
  wait $pid
}

# ==============================
# Dependências
# ==============================
resolve_deps() {
  local pkg="$1"
  local depsfile="$ZERO_RECIPES/$pkg/deps"
  if [[ -f "$depsfile" ]]; then
    for dep in $(cat "$depsfile"); do
      if [[ ! -f "$ZERO_DB/$dep" ]]; then
        log_info "Resolvendo dependência: $dep"
        zero build "$dep"
        zero install "$dep"
      fi
    done
  fi
}

# ==============================
# Build
# ==============================
build_pkg() {
  local pkg="$1"
  local recipe="$ZERO_RECIPES/$pkg"
  LOGFILE="$ZERO_LOGS/${pkg}.log"

  [[ -d "$recipe" ]] || { log_err "Receita não encontrada: $pkg"; exit 1; }
  resolve_deps "$pkg"

  log_info "Baixando source..."
  local url=$(cat "$recipe/source")
  local tarball="$ZERO_BUILD/${pkg}.tar"
  run_with_spinner curl -L "$url" -o "$tarball"

  log_ok "Extraindo..."
  mkdir -p "$ZERO_BUILD/$pkg"
  tar -xf "$tarball" -C "$ZERO_BUILD/$pkg" --strip-components=1

  cd "$ZERO_BUILD/$pkg"

  # hook pre-build
  if [[ -x "$recipe/pre-build" ]]; then
    log_info "Executando pre-build de $pkg..."
    "$recipe/pre-build"
  fi

  log_info "Compilando $pkg..."
  run_with_spinner bash "$recipe/build"

  log_ok "Build concluído para $pkg"
}

# ==============================
# Install
# ==============================
install_pkg() {
  local pkg="$1"
  local recipe="$ZERO_RECIPES/$pkg"
  LOGFILE="$ZERO_LOGS/${pkg}.log"

  log_info "Instalando $pkg..."
  cd "$ZERO_BUILD/$pkg"
  make DESTDIR="$ZERO_DESTDIR" install

  cp -a "$ZERO_DESTDIR"/* /

  # hook post-install
  if [[ -x "$recipe/post-install" ]]; then
    log_info "Executando post-install de $pkg..."
    "$recipe/post-install"
  fi

  echo "$pkg $(cat $recipe/version)" > "$ZERO_DB/$pkg"
  log_ok "$pkg instalado com sucesso"
}
# ==============================
# Config extra (padrões seguros)
# ==============================
: "${ZERO_PREFIX:=/}"
: "${ZERO_SOURCES:=$ZERO_HOME/sources}"
: "${ZERO_STAGE:=$ZERO_HOME/stage}"
: "${ZERO_FLAGS_DIR:=$ZERO_HOME/flags}"
: "${ZERO_REMOTES_DIR:=$ZERO_REPO/remotos}"

mkdir -p "$ZERO_SOURCES" "$ZERO_STAGE" "$ZERO_FLAGS_DIR" "$ZERO_REMOTES_DIR"

# ==============================
# Util extra
# ==============================
find_recipe() {
  # 1) local
  if [[ -d "$ZERO_RECIPES/$1" ]]; then echo "$ZERO_RECIPES/$1"; return 0; fi
  # 2) remotos/*/recipes
  local r
  for r in "$ZERO_REMOTES_DIR"/*/recipes; do
    [[ -d "$r/$1" ]] && { echo "$r/$1"; return 0; }
  done
  return 1
}

get_deps() { local R; R="$(find_recipe "$1")" || return 0; [[ -f "$R/deps" ]] && cat "$R/deps"; }
get_flags() {
  local R; R="$(find_recipe "$1")" || { echo ""; return 0; }
  local f1="$R/flags" f2="$ZERO_FLAGS_DIR/$1"
  { [[ -f "$f1" ]] && cat "$f1"; [[ -f "$f2" ]] && cat "$f2"; } | xargs -r echo
}
get_provides() { local R; R="$(find_recipe "$1")" || return 0; [[ -f "$R/provides" ]] && cat "$R/provides"; }

deps_resolve_recursive() { # imprime deps em ordem (únicos)
  local pkg="$1"
  for d in $(get_deps "$pkg"); do
    deps_resolve_recursive "$d"
    echo "$d"
  done | awk '!seen[$0]++'
}

# ==============================
# Download + extração robusta
# (substitui parte da Parte 1)
# ==============================
download_source() {
  local pkg="$1" R url file
  R="$(find_recipe "$pkg")" || { log_err "Receita não encontrada: $pkg"; exit 1; }
  url="$(head -n1 "$R/source")"
  file="$ZERO_SOURCES/${url##*/}"
  if [[ ! -f "$file" ]]; then
    log_info "Baixando: $url"
    run_with_spinner curl -L "$url" -o "$file"
    log_ok "Download concluído: $file"
  else
    log_info "Usando cache de source: $file"
  fi
  echo "$file"
}

extract_source() {
  local pkg="$1" tarball="$2"
  local dir="$ZERO_BUILD/$pkg"
  rm -rf "$dir"; mkdir -p "$dir"
  log_info "Extraindo $tarball → $dir"
  case "$tarball" in
    *.tar.xz|*.txz) tar -C "$dir" --strip-components=1 -xf "$tarball" ;;
    *.tar.gz|*.tgz) tar -C "$dir" --strip-components=1 -xzf "$tarball" ;;
    *.tar.bz2)      tar -C "$dir" --strip-components=1 -xjf "$tarball" ;;
    *.zip)          unzip -q "$tarball" -d "$dir" && shopt -s dotglob && mv "$dir"/*/* "$dir" 2>/dev/null || true ;;
    *) log_err "Formato de source desconhecido: $tarball"; exit 1 ;;
  esac
}

apply_patches2() {
  local pkg="$1" R; R="$(find_recipe "$pkg")" || return 0
  [[ -d "$R/patch" ]] || return 0
  if ls "$R/patch"/*.patch >/dev/null 2>&1; then
    log_info "Aplicando patches em $pkg"
    ( cd "$ZERO_BUILD/$pkg"
      for p in "$R"/patch/*.patch; do
        log_info "patch: $(basename "$p")"
        patch -p1 < "$p"
      done
    )
    log_ok "Patches aplicados"
  fi
}

# ==============================
# Hooks + Flags no build
# (estende build_pkg da Parte 1)
# ==============================
build_pkg() {
  local pkg="$1" R; R="$(find_recipe "$pkg")" || { log_err "Receita não encontrada: $pkg"; exit 1; }
  LOGFILE="$ZERO_LOGS/${pkg}.log"

  # deps
  for dep in $(deps_resolve_recursive "$pkg"); do
    if [[ ! -f "$ZERO_DB/$dep" ]]; then
      log_info "Dependência: $dep"
      build_pkg "$dep"
      install_pkg "$dep"
    fi
  done

  # baixar + extrair + patches
  local tarball; tarball="$(download_source "$pkg")"
  extract_source "$pkg" "$tarball"
  apply_patches2 "$pkg"

  # hook pre-build
  if [[ -x "$R/pre-build" ]]; then
    log_info "pre-build: $pkg"
    ( cd "$ZERO_BUILD/$pkg" && "$R/pre-build" )
  fi

  # flags
  local FLAGS; FLAGS="$(get_flags "$pkg")"

  # Se o build consumir FLAGS via env, exportamos:
  export ZERO_FLAGS="$FLAGS"

  log_info "Compilando $pkg (FLAGS: $FLAGS)"
  ( cd "$ZERO_BUILD/$pkg" && \
    ZERO_FLAGS="$FLAGS" DESTDIR="$ZERO_STAGE/$pkg" bash "$R/build" ) | tee -a "$LOGFILE"
  log_ok "Build OK: $pkg"
}

# ==============================
# Gestão de conflitos
# ==============================
manifest_generate() {
  local pkg="$1" man="$ZERO_DB/$pkg.files"
  ( cd "$ZERO_STAGE/$pkg" && find . -type f -o -type l | sed 's#^\./#/#' ) > "$man"
  echo "$man"
}

check_conflicts() {
  local pkg="$1" man="$ZERO_DB/$pkg.files"
  [[ -f "$man" ]] || return 0
  local f other
  while read -r f; do
    [[ -e "$f" ]] || continue
    # descobrir se pertence a outro pacote (varrendo manifests)
    for other in "$ZERO_DB"/*.files; do
      [[ "$other" == "$man" ]] && continue
      if grep -qx -- "$f" "$other" 2>/dev/null; then
        echo "${f}:::${other##*/}" # arquivo:::pacote.files
      fi
    done
  done < "$man"
}

resolve_conflicts_interactive() {
  local pkg="$1"; local conflicts tmp
  tmp=$(mktemp)
  check_conflicts "$pkg" > "$tmp" || true
  if [[ -s "$tmp" ]]; then
    log_info "Conflitos detectados:"
    while IFS=":::" read -r f o; do
      echo " - $f (de: ${o%.files})"
    done < "$tmp"
    echo
    read -r -p "Deseja substituir arquivos conflitantes? [s/N] " ans
    if [[ ! "$ans" =~ ^[sS]$ ]]; then
      rm -f "$tmp"; log_err "Instalação abortada por conflito"; exit 1
    fi
    log_info "Prosseguindo, conflitos serão sobrescritos."
  fi
  rm -f "$tmp"
}

# ==============================
# Instalação + post-install + provides
# (substitui install_pkg da Parte 1)
# ==============================
install_pkg() {
  local pkg="$1" R; R="$(find_recipe "$pkg")" || { log_err "Receita não encontrada: $pkg"; exit 1; }
  LOGFILE="$ZERO_LOGS/${pkg}.log"

  # garantir DESTDIR por pacote
  mkdir -p "$ZERO_STAGE/$pkg"
  # se a receita instalou dentro do build, garanta cópia do stage
  if [[ -d "$ZERO_BUILD/$pkg" && ! -d "$ZERO_STAGE/$pkg" ]]; then
    log_err "Nada em $ZERO_STAGE/$pkg. Garanta 'make DESTDIR=$ZERO_STAGE/$pkg install' no build."; exit 1
  fi

  # monta manifest do que VAI instalar
  manifest_generate "$pkg" >/dev/null

  # conflitos
  resolve_conflicts_interactive "$pkg"

  log_info "Instalando $pkg em $ZERO_PREFIX"
  ( cd "$ZERO_STAGE/$pkg" && cp -a . "$ZERO_PREFIX" ) | tee -a "$LOGFILE"

  # post-install
  if [[ -x "$R/post-install" ]]; then
    log_info "post-install: $pkg"
    "$R/post-install" | tee -a "$LOGFILE"
  fi

  # banco + versão
  echo "$pkg $(cat "$R/version")" > "$ZERO_DB/$pkg"

  # registra provides (para consultas/conflitos no futuro)
  if [[ -f "$R/provides" ]]; then
    cp -f "$R/provides" "$ZERO_DB/$pkg.provides"
  fi

  log_ok "Instalação concluída: $pkg"
}

# ==============================
# Remove + órfãos
# ==============================
is_needed_by_others() {
  local target="$1" p
  for p in "$ZERO_DB"/*; do
    [[ -f "$p" ]] || continue
    local name=$(basename "$p")
    name=${name%.*}
    [[ "$name" == "$target" ]] && continue
    if grep -qw "$target" "$(find_recipe "$name")/deps" 2>/dev/null; then
      echo "$name"
    fi
  done
}

remove_pkg() {
  local pkg="$1"
  [[ -f "$ZERO_DB/$pkg" ]] || { log_err "$pkg não está instalado"; return 1; }
  log_info "Removendo $pkg"

  # remover usando manifest
  local man="$ZERO_DB/$pkg.files"
  if [[ -f "$man" ]]; then
    tac "$man" | while read -r f; do
      [[ -e "$f" || -L "$f" ]] && rm -f "$f" || true
      # tentar limpar diretórios vazios
      d=$(dirname "$f"); rmdir -p "$d" 2>/dev/null || true
    done
  else
    log_err "Manifesto ausente ($man). Remoção pode ser incompleta."
  fi

  rm -f "$ZERO_DB/$pkg" "$ZERO_DB/$pkg.files" "$ZERO_DB/$pkg.provides"
  log_ok "$pkg removido"

  # checar órfãos das suas dependências
  local dep needed
  for dep in $(get_deps "$pkg"); do
    if [[ -f "$ZERO_DB/$dep" ]]; then
      needed=$(is_needed_by_others "$dep")
      if [[ -z "$needed" ]]; then
        read -r -p "Dependência órfã '$dep' encontrada. Remover? [s/N] " ans
        [[ "$ans" =~ ^[sS]$ ]] && remove_pkg "$dep" || log_info "Mantendo $dep"
      fi
    fi
  done
}

orphans_cmd() {
  local p needed
  for p in "$ZERO_DB"/*; do
    [[ -f "$p" ]] || continue
    p=$(basename "$p"); p=${p%.*}
    needed=$(is_needed_by_others "$p")
    [[ -z "$needed" ]] && echo "$p"
  done
}

# ==============================
# Show / List / World / Upgrade / Sync
# ==============================
show_pkg() {
  local pkg="$1" R; R="$(find_recipe "$pkg")" || { log_err "Receita não encontrada: $pkg"; exit 1; }
  echo "Pacote:        $pkg"
  if [[ -f "$ZERO_DB/$pkg" ]]; then
    awk '{print "Instalado:     "$2}' "$ZERO_DB/$pkg"
  else
    echo "Instalado:     (não instalado)"
  fi
  echo "Disponível:    $(cat "$R/version")"
  echo -n "Dependências:  "; get_deps "$pkg" | xargs -r echo
  echo "Fonte:         $(head -n1 "$R/source")"
  [[ -f "$ZERO_LOGS/$pkg.log" ]] && echo "Log:           $ZERO_LOGS/$pkg.log"
  [[ -f "$ZERO_DB/$pkg.files" ]] && echo "Manifesto:     $ZERO_DB/$pkg.files"
  [[ -f "$ZERO_DB/$pkg.provides" ]] && echo "Provides:      $(tr '\n' ' ' < "$ZERO_DB/$pkg.provides")"
}

list_cmd() {
  case "$1" in
    installed) awk '{print $1"@"$2}' "$ZERO_DB"/* 2>/dev/null | sort || true ;;
    available)
      # locais
      (cd "$ZERO_RECIPES" 2>/dev/null && ls -1) || true
      # remotos
      for r in "$ZERO_REMOTES_DIR"/*/recipes; do
        (cd "$r" 2>/dev/null && ls -1) || true
      done | sort -u
      ;;
    *) echo "uso: zero list {installed|available}";;
  esac
}

world_cmd() {
  log_info "Recompilando mundo"
  for p in $(list_cmd installed | cut -d@ -f1); do
    build_pkg "$p"; install_pkg "$p"
  done
  log_ok "World concluído"
}

upgrade_cmd() {
  local p cur new R
  for p in $(list_cmd installed | cut -d@ -f1); do
    R="$(find_recipe "$p")" || continue
    cur=$(awk '{print $2}' "$ZERO_DB/$p")
    new=$(cat "$R/version")
    if [[ "$new" > "$cur" ]]; then
      log_info "Upgrade $p: $cur → $new"
      build_pkg "$p"; install_pkg "$p"
    fi
  done
}

sync_repo() {
  log_info "Sync Git"
  ( cd "$ZERO_REPO"
    git add recipes || true
    git add db || true
    git add logs || true
    git commit -m "zero sync $(date '+%F %T')" || true
    git push || true
  )
  log_ok "Sync concluído"
}

# ==============================
# Repositórios remotos
# ==============================
repo_add() { # zero repo-add <url>
  local url="$1" name
  [[ -n "$url" ]] || { echo "uso: zero repo-add <git-url>"; exit 1; }
  name=$(basename "$url" .git)
  if [[ -d "$ZERO_REMOTES_DIR/$name" ]]; then
    log_info "Remoto já existe: $name"
  else
    log_info "Clonando $url → $ZERO_REMOTES_DIR/$name"
    git clone "$url" "$ZERO_REMOTES_DIR/$name"
  fi
  log_ok "Repo remoto adicionado: $name"
}

repo_update() {
  local d
  for d in "$ZERO_REMOTES_DIR"/*; do
    [[ -d "$d/.git" ]] || continue
    log_info "Atualizando remoto: $(basename "$d")"
    ( cd "$d" && git pull --rebase ) || log_err "Falha ao atualizar $(basename "$d")"
  done
  log_ok "Repos remotos atualizados"
}

# ==============================
# Autocomplete (bash/zsh) - arquivos de apoio
# ==============================
completion_print_instructions() {
cat <<'EOF'
# Autocomplete bash:
#   Salve em: /usr/share/zero/zero-completion.bash
#   Conteúdo:
_zero_complete() {
    local cur opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="build install remove show list world upgrade orphans sync repo-add repo-update help"
    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
}
complete -F _zero_complete zero

# No ~/.bashrc:
#   source /usr/share/zero/zero-completion.bash


# Autocomplete zsh (simples):
#   Salve em: /usr/share/zero/zero-completion.zsh
#   Conteúdo:
#compdef zero
_arguments "1: :(build install remove show list world upgrade orphans sync repo-add repo-update help)"

# No ~/.zshrc:
#   fpath=(/usr/share/zero $fpath)
#   autoload -Uz compinit && compinit
#   source /usr/share/zero/zero-completion.zsh
EOF
}

# ==============================
# CLI (comandos novos e antigos)
# ==============================
case "$1" in
  build)     shift; build_pkg "$1" ;;
  install)   shift; install_pkg "$1" ;;
  remove)    shift; remove_pkg "$1" ;;
  show)      shift; show_pkg "$1" ;;
  list)      shift; list_cmd "$1" ;;
  world)     world_cmd ;;
  upgrade)   upgrade_cmd ;;
  orphans)   orphans_cmd ;;
  sync)      sync_repo ;;
  repo-add)  shift; repo_add "$@" ;;
  repo-update) repo_update ;;
  completion) completion_print_instructions ;;
  help|"")
    cat <<EOF
uso: zero <cmd> [args]
cmds:
  build <pkg>       - compila (com deps recursivas)
  install <pkg>     - instala do stage → /
  remove <pkg>      - remove via manifesto + pergunta órfãos
  show <pkg>        - exibe metadados do pacote
  list installed    - lista instalados
  list available    - lista receitas locais e remotas
  world             - recompila todo o sistema
  upgrade           - atualiza pacotes se versão > instalada
  orphans           - lista pacotes órfãos
  sync              - git add/commit/push (recipes, db, logs)
  repo-add <git>    - adiciona repositório remoto de receitas
  repo-update       - atualiza todos remotos
  completion        - instruções de autocomplete bash/zsh
EOF
  ;;
esac
