#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ASSUME_YES=0
FORCE_INSTALL_NM=0
DISABLE_CURVE25519=1

for arg in "$@"; do
  case "$arg" in
    --assume-yes|-y)
      ASSUME_YES=1
      ;;
    --force-install-networkmanager)
      FORCE_INSTALL_NM=1
      ;;
    --no-curve25519-disable)
      DISABLE_CURVE25519=0
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  setup-ikev2-gui.sh [options]

Options:
  -y, --assume-yes                 Не задавать интерактивных вопросов
      --force-install-networkmanager
                                   Установить NetworkManager, если он отсутствует
      --no-curve25519-disable      Не отключать curve25519
  -h, --help                       Показать эту справку
EOF
      exit 0
      ;;
    *)
      echo "[ERROR] Неизвестный аргумент: $arg" >&2
      exit 1
      ;;
  esac
done

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

service_exists() {
  systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi

  read -r -p "$prompt [$default]: " reply
  case "${reply:-$default}" in
    Y|y) return 0 ;;
    *)   return 1 ;;
  esac
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  fail "Запустите скрипт от root или через sudo."
fi

if ! has_cmd apt || ! has_cmd dpkg; then
  fail "Скрипт рассчитан на Debian-based системы с apt/dpkg."
fi

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  log "Обнаружена система: ${PRETTY_NAME:-unknown}"
else
  warn "Не удалось определить версию ОС через /etc/os-release."
fi

log "Обновляем индекс пакетов..."
apt update

if [[ "${ID:-}" == "ubuntu" ]] && ! pkg_available network-manager-strongswan; then
  warn "Пакет network-manager-strongswan пока не найден в apt-cache."
  warn "В Ubuntu он обычно находится в репозитории universe."
  if pkg_available software-properties-common; then
    if ! pkg_installed software-properties-common; then
      log "Устанавливаем software-properties-common..."
      apt install -y software-properties-common
    fi
    log "Пробуем включить репозиторий universe..."
    add-apt-repository -y universe || warn "Не удалось автоматически включить universe."
    apt update || true
  fi
fi

REQUIRED_PKGS=(
  network-manager
  strongswan-nm
  network-manager-strongswan
)

OPTIONAL_PKGS=(
  libstrongswan-standard-plugins
  libstrongswan-extra-plugins
  libcharon-extra-plugins
)

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! pkg_available "$pkg"; then
    fail "Не найден обязательный пакет: $pkg. Проверьте подключённые репозитории."
  fi
done

NM_PRESENT=0
if pkg_installed network-manager || has_cmd nmcli; then
  NM_PRESENT=1
fi

if [[ "$NM_PRESENT" -eq 0 ]]; then
  warn "NetworkManager не установлен."
  warn "Для GUI-настройки IKEv2 strongSwan требуется NetworkManager."
  if [[ "$FORCE_INSTALL_NM" -eq 1 ]] || ask_yes_no "Установить NetworkManager?" "N"; then
    log "Устанавливаем NetworkManager..."
    apt install -y network-manager
    NM_PRESENT=1
  else
    fail "Без NetworkManager GUI-настройка IKEv2 через strongSwan невозможна."
  fi
fi

INSTALL_PKGS=(
  strongswan-nm
  network-manager-strongswan
)

for pkg in "${OPTIONAL_PKGS[@]}"; do
  if pkg_available "$pkg"; then
    INSTALL_PKGS+=("$pkg")
  fi
done

log "Устанавливаем пакеты для GUI-настройки IKEv2..."
apt install -y "${INSTALL_PKGS[@]}"

if [[ "$DISABLE_CURVE25519" -eq 1 ]]; then
  OVERRIDE_FILE="/etc/strongswan.d/charon/zz-local-curve25519.conf"
  log "Создаем override для отключения curve25519: $OVERRIDE_FILE"
  mkdir -p /etc/strongswan.d/charon
  cat > "$OVERRIDE_FILE" <<'EOF'
curve25519 {
    load = no
}
EOF
else
  log "Отключение curve25519 пропущено по флагу."
fi

if has_cmd systemctl; then
  if service_exists NetworkManager.service; then
    log "Включаем и перезапускаем NetworkManager..."
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl restart NetworkManager
  else
    warn "Сервис NetworkManager.service не найден."
  fi
else
  warn "systemctl не найден, перезапуск NetworkManager пропущен."
fi

log "Проверяем наличие NM-плагина strongSwan..."
if pkg_installed network-manager-strongswan && pkg_installed strongswan-nm; then
  log "Пакеты GUI-плагина установлены."
else
  fail "Не удалось подтвердить установку GUI-плагина strongSwan."
fi

cat <<'EOF'

Готово.

Ожидаемый путь в GUI:
  Settings -> Network -> VPN -> Add -> IPsec/IKEv2 (strongSwan)

Если VPN не появляется в GUI:
  1. Перелогиньтесь в графическую сессию
  2. Проверьте:
     journalctl -u NetworkManager -b --no-pager | tail -n 100
  3. Убедитесь, что установлен пакет:
     network-manager-strongswan

EOF
