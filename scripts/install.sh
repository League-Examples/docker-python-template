#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Terminal colors and helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  CYAN=$(tput setaf 6)
else
  BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN=""
fi

header() { echo ""; echo "${BLUE}${BOLD}$1${RESET}"; echo "${BLUE}$(printf '%.0s-' $(seq 1 ${#1}))${RESET}"; }
info()    { echo "  ${GREEN}$1${RESET}"; }
detail()  { echo "  ${DIM}$1${RESET}"; }
warn()    { echo "  ${YELLOW}WARNING:${RESET} $1"; }
err()     { echo "  ${RED}ERROR:${RESET} $1"; }
success() { echo "  ${GREEN}ok${RESET} $1"; }
bullet()  { echo "  ${CYAN}*${RESET} $1"; }

# ---------------------------------------------------------------------------
# 1. Python dependencies
# ---------------------------------------------------------------------------
header "Python Dependencies"

if ! command -v pip3 &>/dev/null && ! command -v pip &>/dev/null; then
  err "pip is not installed. Please install Python 3.10+ and pip."
  exit 1
fi

PIP=$(command -v pip3 2>/dev/null || command -v pip)

if [ -d ".venv" ]; then
  success "Virtual environment already exists (.venv)"
else
  info "Creating virtual environment..."
  python3 -m venv .venv
  success "Created .venv"
fi

# Activate venv
# shellcheck disable=SC1091
source .venv/bin/activate

info "Installing Python dependencies..."
pip install --quiet -r requirements-dev.txt
success "Dependencies installed"

# ---------------------------------------------------------------------------
# 2. Check for Docker and detect contexts
# ---------------------------------------------------------------------------
header "Docker"

DEV_CONTEXT="default"
PROD_CONTEXT="swarm1"

if ! command -v docker &>/dev/null; then
  info "Docker is not installed (optional — SQLite mode works without it)"
  detail "To use Docker later: https://docs.docker.com/get-docker/"
else
  available_contexts=$(docker context ls --format '{{.Name}}' 2>/dev/null || true)

  for candidate in orbstack desktop-linux; do
    if echo "$available_contexts" | grep -qx "$candidate"; then
      DEV_CONTEXT="$candidate"
      break
    fi
  done
  success "Dev context: ${BOLD}$DEV_CONTEXT${RESET}"

  if echo "$available_contexts" | grep -qx "swarm1"; then
    PROD_CONTEXT="swarm1"
    success "Prod context: ${BOLD}$PROD_CONTEXT${RESET}"
  else
    detail "No ${BOLD}swarm1${RESET} context found (needed for production deployment only)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Check for age and SOPS
# ---------------------------------------------------------------------------
header "Encryption Tools"

MISSING_TOOLS=()

if command -v age &>/dev/null; then
  success "age installed"
else
  MISSING_TOOLS+=("age")
fi

if command -v sops &>/dev/null; then
  success "sops installed"
else
  MISSING_TOOLS+=("sops")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  warn "Missing: ${MISSING_TOOLS[*]}"
  detail "These are needed by dotconfig for secrets encryption."
  echo ""
  bullet "macOS:  brew install ${MISSING_TOOLS[*]}"
  bullet "Linux:  See https://github.com/FiloSottile/age and https://github.com/getsops/sops"
  echo ""
fi

# ---------------------------------------------------------------------------
# 4. CLASI / dotconfig / rundbat
# ---------------------------------------------------------------------------
header "Python Tools (CLASI, dotconfig, rundbat)"

pipx_install() {
  local cmd="$1" pkg="$2" name="$3"
  if command -v "$cmd" &>/dev/null; then
    success "$name already installed"
  else
    info "Installing $name via pipx..."
    if pipx install "$pkg" 2>/dev/null; then
      success "$name installed"
    else
      err "Failed to install $name"
      detail "Try manually: pipx install $pkg"
    fi
  fi
}

if ! command -v pipx &>/dev/null; then
  warn "pipx is not installed"
  bullet "macOS:  brew install pipx && pipx ensurepath"
  bullet "Linux:  python3 -m pip install --user pipx && pipx ensurepath"
else
  pipx_install clasi     "git+https://github.com/ericbusboom/claude-agent-skills.git" "CLASI"
  pipx_install dotconfig "git+https://github.com/ericbusboom/dotconfig.git"           "dotconfig"
  pipx_install rundbat   "git+https://github.com/ericbusboom/rundbat.git"             "rundbat"
fi

if command -v dotconfig &>/dev/null; then
  info "Initializing dotconfig..."
  dotconfig init -q 2>/dev/null && success "dotconfig initialized" || warn "dotconfig init failed — run manually"
fi

if command -v clasi &>/dev/null; then
  info "Initializing CLASI project..."
  clasi init 2>/dev/null && success "CLASI initialized" || warn "clasi init failed — run manually"
fi

# ---------------------------------------------------------------------------
# 5. CLASI directory reset (new project from template)
# ---------------------------------------------------------------------------
header "Project Initialization"

CLASI_DIR="docs/clasi"
TEMPLATE_REMOTE="ericbusboom/docker-python-template"

origin_url=$(git remote get-url origin 2>/dev/null || true)

if echo "$origin_url" | grep -q "$TEMPLATE_REMOTE"; then
  success "CLASI retained (template development)"
elif [ -f .template ]; then
  info "New project detected — clearing template history..."
  if [ -d "$CLASI_DIR" ]; then
    rm -rf "$CLASI_DIR/sprints/done"/*
    rm -rf "$CLASI_DIR/todo/done"/*
    rm -rf "$CLASI_DIR/todo/for-later"/*
    rm -f  "$CLASI_DIR/todo"/*.md
    rm -rf "$CLASI_DIR/reflections"/*
    rm -rf "$CLASI_DIR/architecture/done"/*
    rm -f  .clasi.db
  fi
  rm -f .template
  success "CLASI reset — ready for your project"
else
  success "CLASI directory unchanged"
fi

# ---------------------------------------------------------------------------
# 6. Generate .env
# ---------------------------------------------------------------------------
header "Environment File"

if [ -f .env ]; then
  if [ -t 0 ]; then
    warn ".env already exists"
    echo ""
    echo "  ${CYAN}1${RESET}) Overwrite with fresh .env"
    echo "  ${CYAN}2${RESET}) Keep existing .env"
    echo ""
    while true; do
      read -rp "  ${BOLD}Choose [1/2]:${RESET} " env_choice
      case "$env_choice" in
        1) info "Overwriting .env..."; rm -f .env; break ;;
        2) success "Keeping existing .env"; echo ""; echo "${GREEN}${BOLD}Setup complete.${RESET}"; exit 0 ;;
        *) err "Please enter 1 or 2." ;;
      esac
    done
  else
    info "Overwriting .env (non-interactive)..."
    rm -f .env
  fi
fi

info "Generating .env..."

{
  echo "# --- public (dev) ---"
  cat config/dev/public.env
  echo ""
  echo "# --- docker contexts ---"
  echo "DEV_DOCKER_CONTEXT=$DEV_CONTEXT"
  echo "PROD_DOCKER_CONTEXT=$PROD_CONTEXT"
} > .env

if command -v dotconfig &>/dev/null; then
  info "Loading secrets via dotconfig..."
  if dotconfig env dev >> .env 2>/dev/null; then
    success "Secrets appended to .env"
  else
    warn "dotconfig failed — add secrets manually to .env"
  fi
else
  echo "" >> .env
  echo "# --- secrets (add manually or install dotconfig) ---" >> .env
  if [ -f config/dev/secrets.env.example ]; then
    cat config/dev/secrets.env.example >> .env
  fi
  warn "dotconfig not installed — secrets placeholders added to .env"
fi

success "Created .env"

# ---------------------------------------------------------------------------
# 7. Run database migrations
# ---------------------------------------------------------------------------
header "Database"

mkdir -p data
info "Running Alembic migrations..."
alembic upgrade head 2>/dev/null && success "Migrations applied" || warn "Migration failed — run: alembic upgrade head"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo "  Next step: ${CYAN}./scripts/dev.sh${RESET}"
echo ""
