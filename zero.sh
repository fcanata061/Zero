#!/bin/bash
# zero - gerenciador de pacotes minimalista source-based

### Util ###
msg(){ echo -e "\033[1;32m==>\033[0m $*"; }
warn(){ echo -e "\033[1;33m!!\033[0m $*"; }
err(){ echo -e "\033[1;31mEE\033[0m $*" >&2; exit 1; }
spinner(){ pid=$!; spin='-\|/'; i=0
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r[%c] " "${spin:$i:1}"
    sleep .1
  done
  printf "\r   \r"
}

### Helpers ###
deps_of(){ [ -f "$ZERO_RECIPES/$1/deps" ] && cat "$ZERO_RECIPES/$1/deps"; }
resolve_deps(){ local pkg=$1
  for d in $(deps_of $pkg); do resolve_deps $d; echo $d; done | awk '!seen[$0]++'
}

fetch_sources(){ msg "Baixando fontes $1"
  while read -r url; do
    [ -z "$url" ] && continue
    (cd "$ZERO_SOURCES" && curl -LO $url) &
    spinner
  done < "$ZERO_RECIPES/$1/source"
}

extract_sources(){ msg "Extraindo $1"
  src=$(head -n1 "$ZERO_RECIPES/$1/source")
  file=${src##*/}
  mkdir -p "$ZERO_BUILD/$1"
  cd "$ZERO_BUILD/$1"
  case $file in
    *.tar.gz|*.tgz) tar xzf "$ZERO_SOURCES/$file" ;;
    *.tar.bz2) tar xjf "$ZERO_SOURCES/$file" ;;
    *.tar.xz) tar xJf "$ZERO_SOURCES/$file" ;;
    *.zip) unzip -q "$ZERO_SOURCES/$file" ;;
    *.git) git clone "$src" ;;
    *) err "Formato desconhecido: $file" ;;
  esac
}

apply_patches(){ [ -d "$ZERO_RECIPES/$1/patch" ] || return
  msg "Aplicando patches $1"
  cd "$ZERO_BUILD/$1"/* || return
  for p in "$ZERO_RECIPES/$1"/patch/*.patch; do
    [ -f "$p" ] && patch -p1 < "$p"
  done
}

build_pkg(){ msg "Compilando $1"
  cd "$ZERO_BUILD/$1"/* || return
  DESTDIR="$ZERO_STAGE/$1" bash "$ZERO_RECIPES/$1/build" & spinner
}

install_pkg(){ msg "Instalando $1"
  cd "$ZERO_STAGE/$1" || return
  cp -av . "$ZERO_PREFIX" >>"$ZERO_LOG/$1.log" 2>&1
  echo "$(cat $ZERO_RECIPES/$1/version)" > "$ZERO_DB/$1.version"
}
remove_pkg(){ local pkg=$1
  [ -f "$ZERO_DB/$pkg.version" ] || { warn "$pkg não está instalado"; return; }
  msg "Removendo $pkg"
  rm -rf "$ZERO_PREFIX/$(ls "$ZERO_STAGE/$pkg")"
  rm -f "$ZERO_DB/$pkg.version"
  # verificar órfãos
  for dep in $(deps_of $pkg); do
    local needed=$(grep -R "$dep" "$ZERO_RECIPES"/*/deps | grep -v "/$pkg/deps" || true)
    if [ -z "$needed" ] && [ -f "$ZERO_DB/$dep.version" ]; then
      read -p "O pacote '$dep' ficou órfão, deseja remover também? [s/N] " ans
      if [[ "$ans" =~ ^[sS]$ ]]; then remove_pkg $dep
      else warn "Mantendo $dep instalado"; fi
    fi
  done
}

upgrade_pkg(){ local pkg=$1 new=$(cat "$ZERO_RECIPES/$pkg/version")
  [ -f "$ZERO_DB/$pkg.version" ] || { warn "$pkg não instalado"; return; }
  old=$(cat "$ZERO_DB/$pkg.version")
  [ "$new" \> "$old" ] || { warn "$pkg já está na versão $old"; return; }
  msg "Upgrade $pkg $old → $new"
  $0 build $pkg
}

orphans(){ msg "Listando órfãos"
  for p in $(ls "$ZERO_DB"); do
    pkg=${p%.version}
    needed=$(grep -R "$pkg" "$ZERO_RECIPES"/*/deps || true)
    [ -z "$needed" ] && echo $pkg
  done
}

world(){ msg "Recompilando mundo"
  for p in $(ls "$ZERO_DB" | sed 's/.version//'); do
    $0 build $p
  done
}

sync_repo(){ msg "Sincronizando repo git"
  cd "$ZERO_REPO"
  git add recipes
  git add $(find . -type d -name patch)
  git add db log
  git commit -m "sync $(date)" || true
  git push || true
}

show_pkg(){ local pkg=$1
  [ -d "$ZERO_RECIPES/$pkg" ] || { err "Pacote $pkg não existe"; }
  echo "Pacote:        $pkg"
  if [ -f "$ZERO_DB/$pkg.version" ]; then
    echo "Instalado:     $(cat $ZERO_DB/$pkg.version)"
  else
    echo "Instalado:     (não instalado)"
  fi
  echo "Disponível:    $(cat $ZERO_RECIPES/$pkg/version)"
  echo "Dependências:  $(deps_of $pkg | xargs echo)"
  echo "Fonte:         $(head -n1 $ZERO_RECIPES/$pkg/source)"
  [ -f "$ZERO_LOG/$pkg.log" ] && echo "Log:           $ZERO_LOG/$pkg.log"
}

### CLI ###
case $1 in
  build) shift
    for dep in $(resolve_deps $1); do
      [ -f "$ZERO_DB/$dep.version" ] || { $0 build $dep; $0 install $dep; }
    done
    fetch_sources $1
    extract_sources $1
    apply_patches $1
    build_pkg $1
    $0 install $1 ;;
  install) shift; install_pkg $1 ;;
  remove) shift; remove_pkg $1 ;;
  upgrade) shift; upgrade_pkg $1 ;;
  orphans) orphans ;;
  world) world ;;
  sync) sync_repo ;;
  show) shift; show_pkg $1 ;;
  *) echo "uso: $0 {build|install|remove|upgrade|orphans|world|sync|show} pkg";;
esac
