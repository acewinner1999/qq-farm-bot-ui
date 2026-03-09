#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# QQ Farm Bot UI - One-Click Install / Update / Manage Script
# Repo: https://github.com/Penty-d/qq-farm-bot-ui
#
# Features:
# - Auto install Docker + docker compose
# - Configure 1ms Docker registry mirror: https://docker.1ms.run
# - GitHub pull/clone fallback (CN-friendly): default ghproxy
# - First install: choose host port + panel password
# - Re-run: detect updates, update, rebuild & restart
#
# Notes:
# - Menu is NO-COLOR (stable display everywhere)
# - Other logs use "stable color": only enabled when terminal supports it
# ==========================================================

# -------------------------
# Config (override by env)
# -------------------------
REPO_URL_PRIMARY="${REPO_URL_PRIMARY:-https://github.com/Penty-d/qq-farm-bot-ui.git}"
REPO_URL_FALLBACK="${REPO_URL_FALLBACK:-https://ghproxy.com/${REPO_URL_PRIMARY}}"

BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/qq-farm-bot-ui}"

# Project defaults
PANEL_PORT_DEFAULT="${PANEL_PORT_DEFAULT:-3000}"
ADMIN_PASSWORD_DEFAULT="${ADMIN_PASSWORD_DEFAULT:-admin}"

# Docker mirror
DOCKER_MIRROR_URL="${DOCKER_MIRROR_URL:-https://docker.1ms.run}"

# Summary behavior
SHOW_PASSWORD_IN_SUMMARY="${SHOW_PASSWORD_IN_SUMMARY:-1}"

# Stable color switches:
# - NO_COLOR=1    -> force disable
# - FORCE_COLOR=1 -> force enable (may show escape codes in some environments)
NO_COLOR="${NO_COLOR:-0}"
FORCE_COLOR="${FORCE_COLOR:-0}"

# -------------------------
# Stable color (robust)
# -------------------------
supports_color() {
  [[ "$FORCE_COLOR" == "1" ]] && return 0
  [[ "$NO_COLOR" == "1" ]] && return 1
  [[ -t 1 ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1

  if command -v tput >/dev/null 2>&1; then
    local ncolors
    ncolors="$(tput colors 2>/dev/null || echo 0)"
    [[ "$ncolors" =~ ^[0-9]+$ ]] || ncolors=0
    (( ncolors >= 8 )) || return 1
  fi
  return 0
}

init_styles() {
  if supports_color; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
  fi
}

init_styles

# -------------------------
# UI helpers (printf only)
# -------------------------
hr()   { printf '%s\n' "${DIM}------------------------------------------------------------${RESET}"; }
title(){ printf '\n%s\n' "${BOLD}${CYAN}==> $*${RESET}"; }
ok()   { printf '%s\n' "${GREEN}[OK]${RESET} $*"; }
info() { printf '%s\n' "${BLUE}[INFO]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[WARN]${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

trap 'die "脚本在第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

# -------------------------
# Privilege helpers
# -------------------------
need_root_or_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
  else
    have_cmd sudo || die "需要 root 权限或 sudo。请使用 root 运行或先安装 sudo。"
    SUDO="sudo"
  fi
}

repo_user() {
  # prefer original user if running via sudo
  local u="${SUDO_USER:-$USER}"
  [[ -n "$u" ]] || u="root"
  printf '%s' "$u"
}

run_as_repo_user() {
  # run command as repo user if possible (helps avoid root-owned git dirs)
  local u
  u="$(repo_user)"
  if [[ -n "${SUDO:-}" && "$u" != "root" ]]; then
    sudo -u "$u" bash -lc "$*"
  else
    bash -lc "$*"
  fi
}

# -------------------------
# Safe FS helpers
# -------------------------
assert_safe_install_dir() {
  local dir="$1"

  [[ -n "$dir" ]] || die "INSTALL_DIR 为空，拒绝继续。"
  [[ "$dir" == /* ]] || die "INSTALL_DIR 必须为绝对路径：$dir"

  # 防止误设为顶级目录导致灾难性 chown/rm 等风险
  case "$dir" in
    "/"|"/opt"|"/usr"|"/bin"|"/sbin"|"/lib"|"/lib64"|"/etc"|"/var"|"/root"|"/home")
      die "INSTALL_DIR 指向危险目录：$dir（拒绝继续）"
      ;;
  esac
}

safe_chown_install_dir() {
  local dir="$1"
  local u="$2"

  [[ "$u" != "root" ]] || return 0

  assert_safe_install_dir "$dir"
  $SUDO chown -R -- "$u":"$u" "$dir" >/dev/null 2>&1 || true
}

# -------------------------
# Safe .env reader (NO source)
# -------------------------
read_env_value() {
  # Usage: read_env_value "/path/.env" "KEY"
  # Output: value to stdout; return 0 if found else 1
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1

  # match lines like: KEY=VALUE   (ignore leading spaces, ignore commented lines)
  local line val
  line="$(
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
      | grep -Ev "^[[:space:]]*#" \
      | tail -n 1 \
      || true
  )"
  [[ -n "$line" ]] || return 1

  val="${line#*=}"

  # trim spaces
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"

  # remove wrapping quotes (one layer)
  if [[ "$val" =~ ^\".*\"$ ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" =~ ^\'.*\'$ ]]; then
    val="${val:1:${#val}-2}"
  fi

  printf '%s' "$val"
}

# -------------------------
# Package manager helpers
# -------------------------
install_pkg() {
  local pkgs=("$@")
  if have_cmd apt-get; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y "${pkgs[@]}"
  elif have_cmd dnf; then
    $SUDO dnf install -y "${pkgs[@]}"
  elif have_cmd yum; then
    $SUDO yum install -y "${pkgs[@]}"
  else
    die "无法识别包管理器(apt/yum/dnf)。请手动安装：curl git python3"
  fi
}

ensure_basic_deps() {
  title "检查基础依赖"
  local need=()
  have_cmd curl || need+=("curl")
  have_cmd git || need+=("git")
  have_cmd python3 || need+=("python3")
  if (( ${#need[@]} > 0 )); then
    info "安装依赖：${need[*]}"
    install_pkg "${need[@]}"
  else
    ok "基础依赖已就绪（curl/git/python3）"
  fi
}

# -------------------------
# Docker install & compose
# -------------------------
ensure_docker_installed() {
  title "检查 / 安装 Docker"
  if have_cmd docker; then
    ok "Docker 已安装：$(docker --version 2>/dev/null || true)"
    return 0
  fi

  info "未检测到 Docker，开始安装（get.docker.com）"
  curl -fsSL https://get.docker.com | $SUDO sh

  if have_cmd systemctl; then
    $SUDO systemctl enable docker >/dev/null 2>&1 || true
    $SUDO systemctl restart docker >/dev/null 2>&1 || true
  else
    $SUDO service docker restart >/dev/null 2>&1 || true
  fi

  have_cmd docker || die "Docker 安装失败，请检查网络/系统。"
  ok "Docker 安装完成：$(docker --version 2>/dev/null || true)"
}

ensure_compose_available() {
  title "检查 docker compose"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose 可用：$(docker compose version 2>/dev/null | head -n 1 || true)"
    return 0
  fi

  warn "未检测到 docker compose，尝试安装 docker-compose-plugin"
  install_pkg docker-compose-plugin || true

  docker compose version >/dev/null 2>&1 || die "docker compose 仍不可用，请手动安装 Docker Compose v2 插件。"
  ok "docker compose 已安装：$(docker compose version 2>/dev/null | head -n 1 || true)"
}

configure_docker_mirror() {
  title "配置 Docker 镜像加速器（1ms）"
  info "写入 registry-mirrors：${DOCKER_MIRROR_URL}"
  $SUDO mkdir -p /etc/docker

  $SUDO python3 - <<PY
import json, os
path = "/etc/docker/daemon.json"
mirror = "${DOCKER_MIRROR_URL}"

data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read().strip()
            if content:
                data = json.loads(content)
    except Exception:
        data = {}

mirrors = data.get("registry-mirrors", [])
if not isinstance(mirrors, list):
    mirrors = []

if mirror not in mirrors:
    mirrors.insert(0, mirror)

data["registry-mirrors"] = mirrors

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

os.replace(tmp, path)
print("OK:", path)
PY

  if have_cmd systemctl; then
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    $SUDO systemctl restart docker >/dev/null 2>&1 || true
  else
    $SUDO service docker restart >/dev/null 2>&1 || true
  fi

  ok "镜像加速器已配置完成（/etc/docker/daemon.json）等待docker重启完成后进行下一步操作"
}

ensure_docker_group() {
  title "配置 Docker 用户组（可选）"
  local u
  u="$(repo_user)"
  if [[ "$u" == "root" ]]; then
    info "当前为 root 或无法识别普通用户，跳过 docker 组配置"
    return 0
  fi

  if getent group docker >/dev/null 2>&1; then
    if id -nG "$u" | tr ' ' '\n' | grep -qx docker; then
      ok "用户 ${u} 已在 docker 组"
    else
      warn "将用户 ${u} 加入 docker 组（可能需要重新登录生效）"
      $SUDO usermod -aG docker "$u" || true
      ok "已尝试添加 ${u} 到 docker 组"
    fi
  else
    warn "docker 组不存在？跳过"
  fi
}

# -------------------------
# Input helpers
# -------------------------
prompt_value() {
  local prompt="$1"
  local def="$2"
  local __outvar="$3"
  local val=""
  read -r -p "${prompt} (默认: ${def}): " val || true
  val="${val:-$def}"
  printf -v "$__outvar" "%s" "$val"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

# -------------------------
# Git with fallback
# -------------------------
git_clone_with_fallback() {
  # $1 branch, $2 dir
  local branch="$1"
  local dir="$2"

  title "拉取项目代码"
  info "主地址：${REPO_URL_PRIMARY}"
  if run_as_repo_user "git clone -b '${branch}' '${REPO_URL_PRIMARY}' '${dir}'"; then
    ok "克隆成功（主地址）"
    return 0
  fi

  warn "主地址克隆失败，尝试备用地址：${REPO_URL_FALLBACK}"
  run_as_repo_user "git clone -b '${branch}' '${REPO_URL_FALLBACK}' '${dir}'"
  ok "克隆成功（备用地址）"
}

git_remote_head_hash() {
  # $1 url, $2 branch
  local url="$1"
  local branch="$2"
  git ls-remote --heads "$url" "$branch" 2>/dev/null | awk '{print $1}' | head -n 1 || true
}

git_pull_rebase_with_fallback() {
  # run inside repo dir
  local branch="$1"

  if run_as_repo_user "cd '${INSTALL_DIR}' && git pull --rebase '${REPO_URL_PRIMARY}' '${branch}'"; then
    return 0
  fi

  warn "从主地址 pull 失败，改用备用地址 pull：${REPO_URL_FALLBACK}"
  run_as_repo_user "cd '${INSTALL_DIR}' && git pull --rebase '${REPO_URL_FALLBACK}' '${branch}'"
}

# -------------------------
# Repo / compose operations
# -------------------------
prepare_install_dir() {
  title "准备安装目录"
  info "安装目录：${INSTALL_DIR}"

  assert_safe_install_dir "$INSTALL_DIR"

  # ✅ 只创建 INSTALL_DIR（不会误操作父目录）
  $SUDO mkdir -p -- "$INSTALL_DIR"

  # ✅ 只对 INSTALL_DIR 做 chown（不会 chown /opt 等父目录）
  local u
  u="$(repo_user)"
  safe_chown_install_dir "$INSTALL_DIR" "$u"

  ok "目录准备完成"
}

clone_or_keep_repo() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    ok "检测到已存在仓库：${INSTALL_DIR}"
    return 0
  fi

  prepare_install_dir
  git_clone_with_fallback "$BRANCH" "$INSTALL_DIR"
}

write_override_compose() {
  local panel_port="$1"
  local admin_password="$2"

  title "写入运行配置"
  info "写入：${INSTALL_DIR}/.env"
  cat > "${INSTALL_DIR}/.env" <<EOF
# Generated by qq-farm-bot-ui.sh
ADMIN_PASSWORD=${admin_password}
EOF

  info "写入：${INSTALL_DIR}/docker-compose.override.yml（端口映射 + 环境变量覆盖）"
  cat > "${INSTALL_DIR}/docker-compose.override.yml" <<EOF
services:
  qq-farm-bot-ui:
    environment:
      ADMIN_PASSWORD: "\${ADMIN_PASSWORD}"
    ports:
      - "${panel_port}:3000"
EOF

  ok "配置文件写入完成"
}

compose_up() {
  title "构建并启动（docker compose up -d --build）"
  (cd "$INSTALL_DIR" && docker compose up -d --build)
  ok "容器已启动"
}

compose_down() {
  title "停止并删除容器（docker compose down）"
  (cd "$INSTALL_DIR" && docker compose down) || true
  ok "容器已停止"
}

compose_logs() {
  title
