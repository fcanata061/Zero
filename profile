# ================================
# Configuração do Gerenciador ZERO
# ================================

# Diretórios principais
export ZERO_HOME="$HOME/zero"
export ZERO_RECIPES="$ZERO_HOME/recipes"
export ZERO_SRC="$ZERO_HOME/sources"
export ZERO_BUILD="$ZERO_HOME/build"
export ZERO_STAGE="$ZERO_HOME/stage"
export ZERO_DB="$ZERO_HOME/db"
export ZERO_LOG="$ZERO_HOME/logs"
export ZERO_GIT="$ZERO_HOME/repo"

# Sistema
export ZERO_PREFIX="/"
export ZERO_WORLD="$ZERO_HOME/world.list"

# Compilação
export ZERO_JOBS="$(nproc)"
export ZERO_MAKE="-j${ZERO_JOBS}"
export ZERO_STRIP="strip --strip-unneeded"

# Aparência
export ZERO_COLOR="1"

# PATH (para chamar o zero facilmente se estiver em $HOME/bin)
export PATH="$HOME/bin:$PATH"

# ================================
# Funções auxiliares de conveniência
# ================================

# Atalho para entrar no diretório de receitas
zr() { cd "$ZERO_RECIPES/$1" || echo "Pacote $1 não existe em $ZERO_RECIPES"; }

# Mostrar status rápido do zero
zstatus() {
  echo "Zero Package Manager"
  echo "Home:     $ZERO_HOME"
  echo "Recipes:  $ZERO_RECIPES"
  echo "Sources:  $ZERO_SRC"
  echo "Build:    $ZERO_BUILD"
  echo "Stage:    $ZERO_STAGE"
  echo "DB:       $ZERO_DB"
  echo "Logs:     $ZERO_LOG"
  echo "Repo:     $ZERO_GIT"
  echo "Prefix:   $ZERO_PREFIX"
  echo "Jobs:     $ZERO_JOBS"
}
