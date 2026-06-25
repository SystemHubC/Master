#!/usr/bin/env bash
# FunPay Pulse Master
# GitHub-ready VPS helper for FunPay Pulse Worker.
# Safe-by-default: never uploads secrets anywhere except user-confirmed SCP to user's VPS.

set -u
set -o pipefail

VERSION="1.0.0"
INSTALL_DIR="/opt/funpay-worker"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
MIGRATION_DIR="/root/pulse-migration"
OFFICIAL_INSTALL_URL="https://funpaypulse.com/install.sh"
HEALTH_URL="http://localhost:8000/health"
DATA_VOL="funpay-worker_funpay-data"
RUNTIME_VOL="funpay-worker_funpay-plugin-runtime"
WORKER_CONTAINER="funpay-worker"
RUNNER_CONTAINER="funpay-plugin-runner"

# Optional: set your GitHub raw URL before publishing.
# Example: PULSE_MASTER_URL="https://raw.githubusercontent.com/andreycatser/funpay-pulse-master/main/pulse-master.sh"
PULSE_MASTER_URL="${PULSE_MASTER_URL:-}"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'

line() { echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; }
ok() { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
err() { echo -e "${C_RED}✖${C_RESET} $*" >&2; }
info() { echo -e "${C_CYAN}•${C_RESET} $*"; }

pause() {
  echo ""
  read -r -p "Нажмите Enter, чтобы вернуться в меню... " _ || true
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local answer suffix
  if [[ "$default" == "y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  read -r -p "$prompt $suffix: " answer || return 1
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[YyДд]$ ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Запустите мастер от root: curl -fsSL <URL> | sudo bash"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Не найдена команда: $1"
    return 1
  }
}

compose_down() {
  if [[ -d "$INSTALL_DIR" ]]; then
    (cd "$INSTALL_DIR" && docker compose down) >/dev/null 2>&1 && return 0
    (cd "$INSTALL_DIR" && docker-compose down) >/dev/null 2>&1 && return 0
  fi
  docker stop "$WORKER_CONTAINER" >/dev/null 2>&1 || true
  docker stop "$RUNNER_CONTAINER" >/dev/null 2>&1 || true
  return 0
}

compose_up() {
  if [[ -d "$INSTALL_DIR" ]]; then
    (cd "$INSTALL_DIR" && docker compose up -d) && return 0
    (cd "$INSTALL_DIR" && docker-compose up -d) && return 0
  fi
  return 1
}

read_env_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 1
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed "s/^'//;s/'$//;s/^\"//;s/\"$//"
}

detect_public_ip() {
  local ip=""
  for svc in "https://ifconfig.me" "https://icanhazip.com" "https://api.ipify.org"; do
    ip=$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$ip" =~ ^[0-9a-fA-F:]{3,}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "не удалось определить"
}

mask_secret() {
  local s="$1"
  local n=${#s}
  if (( n <= 10 )); then
    echo "********"
  else
    echo "${s:0:4}…${s: -4}"
  fi
}

banner() {
  clear 2>/dev/null || true
  echo -e "${C_MAGENTA}${C_BOLD}"
  cat <<'ASCII'
██████╗ ██╗   ██╗██╗     ███████╗███████╗
██╔══██╗██║   ██║██║     ██╔════╝██╔════╝
██████╔╝██║   ██║██║     ███████╗█████╗  
██╔═══╝ ██║   ██║██║     ╚════██║██╔══╝  
██║     ╚██████╔╝███████╗███████║███████╗
╚═╝      ╚═════╝ ╚══════╝╚══════╝╚══════╝
ASCII
  echo -e "${C_RESET}${C_BOLD}FunPay Pulse Master v${VERSION}${C_RESET} ${C_DIM}by @AndreyCatser${C_RESET}"
  line
}

show_token() {
  banner
  echo -e "${C_BOLD}1) Узнать токен соединения${C_RESET}"
  line

  if [[ ! -f "$ENV_FILE" ]]; then
    err "Файл $ENV_FILE не найден. Worker, похоже, ещё не установлен."
    echo ""
    echo "Установить Worker можно из меню: пункт 4."
    pause
    return
  fi

  local token signing ip health
  token=$(read_env_value "CONNECTION_TOKEN" || true)
  signing=$(read_env_value "SIGNING_SECRET" || true)
  ip=$(detect_public_ip)

  if [[ -z "$token" ]]; then
    err "CONNECTION_TOKEN не найден в $ENV_FILE"
    pause
    return
  fi

  echo -e "${C_GREEN}${C_BOLD}Данные для подключения VPS в FunPay Pulse:${C_RESET}"
  echo ""
  echo -e "IP:      ${C_BOLD}${ip}${C_RESET}"
  echo -e "Порт:    ${C_BOLD}8000${C_RESET}"
  echo -e "Токен:   ${C_BOLD}${token}${C_RESET}"
  echo ""
  echo -e "${C_DIM}Безопасная короткая проверка: CONNECTION_TOKEN=$(mask_secret "$token")${C_RESET}"
  [[ -n "$signing" ]] && echo -e "${C_DIM}SIGNING_SECRET найден: $(mask_secret "$signing")${C_RESET}"
  echo ""
  warn "Не отправляйте токен в публичные чаты и не публикуйте .env."
  echo ""

  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "Health-check отвечает: Worker работает."
  else
    warn "Health-check не ответил. Это не всегда критично, но можно проверить статус в пункте 3."
  fi

  pause
}

install_official_worker() {
  banner
  echo -e "${C_BOLD}Установка официального FunPay Pulse Worker${C_RESET}"
  line
  warn "Будет запущен официальный установщик: $OFFICIAL_INSTALL_URL"
  echo "Во время установки может понадобиться код из Telegram-бота FunPay Pulse через /vps."
  echo ""
  confirm "Запустить установку сейчас?" "n" || { pause; return; }
  need_cmd curl || { pause; return; }
  curl -fsSL "$OFFICIAL_INSTALL_URL" | bash
  echo ""
  ok "Установщик завершил работу."
  pause
}

update_worker() {
  banner
  echo -e "${C_BOLD}Обновление Worker${C_RESET}"
  line
  if [[ -x "${INSTALL_DIR}/update.sh" ]]; then
    confirm "Запустить ${INSTALL_DIR}/update.sh?" "y" || { pause; return; }
    "${INSTALL_DIR}/update.sh"
  else
    warn "${INSTALL_DIR}/update.sh не найден. Можно повторно запустить официальный установщик."
    confirm "Запустить официальный install.sh?" "n" && curl -fsSL "$OFFICIAL_INSTALL_URL" | bash
  fi
  pause
}

show_status() {
  banner
  echo -e "${C_BOLD}Статус и диагностика${C_RESET}"
  line

  echo -e "${C_BOLD}Система:${C_RESET}"
  echo "Host: $(hostname 2>/dev/null || echo unknown)"
  echo "IP:   $(detect_public_ip)"
  echo "Disk:"
  df -h / 2>/dev/null | sed 's/^/  /' || true
  echo ""

  echo -e "${C_BOLD}Docker:${C_RESET}"
  if command -v docker >/dev/null 2>&1; then
    docker --version 2>/dev/null || true
    echo ""
    echo "Контейнеры FunPay:"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -E 'NAMES|funpay' || warn "Контейнеры funpay не найдены."
    echo ""
    echo "Volumes FunPay:"
    docker volume ls 2>/dev/null | grep funpay || warn "Volumes funpay не найдены."
  else
    warn "Docker не установлен."
  fi

  echo ""
  echo -e "${C_BOLD}Worker health:${C_RESET}"
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "$HEALTH_URL"; then
    echo ""
    ok "Worker отвечает."
  else
    warn "Worker не ответил на $HEALTH_URL"
  fi

  echo ""
  echo -e "${C_BOLD}.env:${C_RESET}"
  if [[ -f "$ENV_FILE" ]]; then
    ok "$ENV_FILE найден"
    local token
    token=$(read_env_value "CONNECTION_TOKEN" || true)
    [[ -n "$token" ]] && echo "CONNECTION_TOKEN=$(mask_secret "$token")"
  else
    warn "$ENV_FILE не найден"
  fi

  pause
}

backup_volume() {
  local volume="$1"
  local output="$2"
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    return 2
  fi
  docker run --rm \
    -v "${volume}:/volume:ro" \
    -v "${MIGRATION_DIR}:/backup" \
    alpine sh -c "cd /volume && tar czf /backup/${output} ."
}

create_migration_backup() {
  banner
  echo -e "${C_BOLD}Миграция: старый VPS → создать бэкап${C_RESET}"
  line

  need_cmd docker || { pause; return; }

  warn "Worker будет остановлен на время бэкапа, чтобы данные не изменялись во время архивации."
  warn "В архиве и env.backup могут быть токены, секреты, cookies и данные плагинов. Не публикуйте их."
  echo ""
  confirm "Продолжить создание бэкапа?" "n" || { pause; return; }

  mkdir -p "$MIGRATION_DIR"
  chmod 700 "$MIGRATION_DIR"

  info "Останавливаю Worker..."
  compose_down

  info "Создаю архив основного volume: $DATA_VOL"
  if backup_volume "$DATA_VOL" "funpay-data.tar.gz"; then
    ok "Создан: ${MIGRATION_DIR}/funpay-data.tar.gz"
  else
    err "Не удалось создать бэкап $DATA_VOL. Проверьте docker volume ls | grep funpay"
    pause
    return
  fi

  info "Создаю архив runtime volume плагинов: $RUNTIME_VOL"
  if backup_volume "$RUNTIME_VOL" "funpay-plugin-runtime.tar.gz"; then
    ok "Создан: ${MIGRATION_DIR}/funpay-plugin-runtime.tar.gz"
  else
    warn "Volume $RUNTIME_VOL не найден или не использовался. Продолжаю без него."
  fi

  if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "${MIGRATION_DIR}/env.backup"
    chmod 600 "${MIGRATION_DIR}/env.backup"
    ok "Сохранён: ${MIGRATION_DIR}/env.backup"
  else
    warn "$ENV_FILE не найден — SECRET_KEY не получится перенести автоматически."
  fi

  if [[ -f "$COMPOSE_FILE" ]]; then
    cp "$COMPOSE_FILE" "${MIGRATION_DIR}/docker-compose.backup.yml"
    ok "Сохранён: ${MIGRATION_DIR}/docker-compose.backup.yml"
  fi

  {
    echo "FunPay Pulse migration backup"
    echo "Created: $(date -Is)"
    echo "Host: $(hostname 2>/dev/null || echo unknown)"
    echo "IP: $(detect_public_ip)"
    echo "Files:"
    ls -lah "$MIGRATION_DIR"
    echo ""
    echo "SHA256:"
    (cd "$MIGRATION_DIR" && sha256sum *.tar.gz env.backup docker-compose.backup.yml 2>/dev/null || true)
  } > "${MIGRATION_DIR}/MANIFEST.txt"

  echo ""
  ok "Бэкап готов: $MIGRATION_DIR"
  ls -lah "$MIGRATION_DIR"
  echo ""

  if confirm "Отправить бэкап на новый VPS по SCP прямо сейчас?" "y"; then
    send_backup_scp
  fi

  echo ""
  if confirm "Запустить Worker обратно на старом VPS? Обычно при миграции лучше оставить старый выключенным до проверки нового." "n"; then
    compose_up && ok "Worker запущен." || warn "Не удалось запустить через compose. Проверьте вручную."
  else
    warn "Старый Worker оставлен выключенным, чтобы не было расхождения данных."
  fi

  pause
}

send_backup_scp() {
  need_cmd scp || { warn "scp не найден. Установите openssh-client или перенесите папку вручную."; return 1; }
  local ip user port target
  read -r -p "IP нового VPS: " ip
  [[ -n "$ip" ]] || { warn "IP не указан."; return 1; }
  read -r -p "SSH пользователь [root]: " user
  user="${user:-root}"
  read -r -p "SSH порт [22]: " port
  port="${port:-22}"
  target="${user}@${ip}:/root/"
  echo ""
  info "Передаю $MIGRATION_DIR → $target"
  scp -P "$port" -r "$MIGRATION_DIR" "$target" && ok "Бэкап отправлен на новый VPS: /root/pulse-migration" || warn "SCP не прошёл. Можно перенести папку вручную через WinSCP/SFTP."
}

copy_secret_key_only() {
  if [[ ! -f "${MIGRATION_DIR}/env.backup" ]]; then
    warn "${MIGRATION_DIR}/env.backup не найден. SECRET_KEY не будет перенесён."
    return 0
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    err "$ENV_FILE не найден. Сначала установите Worker на новом VPS."
    return 1
  fi

  cp "$ENV_FILE" "${ENV_FILE}.before-migration.$(date +%Y%m%d-%H%M%S)"

  python3 - <<'PY'
from pathlib import Path
old_env = Path('/root/pulse-migration/env.backup')
new_env = Path('/opt/funpay-worker/.env')

def read_env(path):
    data = {}
    for line in path.read_text(encoding='utf-8', errors='ignore').splitlines():
        if not line or line.strip().startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        data[key.strip()] = value.strip()
    return data

old = read_env(old_env)
lines = new_env.read_text(encoding='utf-8', errors='ignore').splitlines()

if 'SECRET_KEY' in old:
    done = False
    for i, line in enumerate(lines):
        if line.startswith('SECRET_KEY='):
            lines[i] = 'SECRET_KEY=' + old['SECRET_KEY']
            done = True
            break
    if not done:
        lines.append('SECRET_KEY=' + old['SECRET_KEY'])

new_env.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
  chmod 600 "$ENV_FILE"
  ok "SECRET_KEY перенесён в новый .env. CONNECTION_TOKEN и SIGNING_SECRET нового VPS сохранены."
}

restore_volume() {
  local volume="$1"
  local archive="$2"
  [[ -f "${MIGRATION_DIR}/${archive}" ]] || return 2
  docker volume create "$volume" >/dev/null
  docker run --rm \
    -v "${volume}:/volume" \
    -v "${MIGRATION_DIR}:/backup:ro" \
    alpine sh -c "cd /volume && find . -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar xzf /backup/${archive}"
}

restore_migration_backup() {
  banner
  echo -e "${C_BOLD}Миграция: новый VPS → восстановить данные${C_RESET}"
  line

  need_cmd docker || { pause; return; }
  need_cmd python3 || { pause; return; }

  if [[ ! -d "$MIGRATION_DIR" ]]; then
    err "Папка $MIGRATION_DIR не найдена. Сначала отправьте бэкап со старого VPS."
    pause
    return
  fi

  echo "Найдено в $MIGRATION_DIR:"
  ls -lah "$MIGRATION_DIR"
  echo ""

  if [[ ! -f "$ENV_FILE" ]]; then
    warn "Worker на новом VPS ещё не установлен или $ENV_FILE не найден."
    if confirm "Запустить официальный установщик FunPay Pulse Worker сейчас?" "y"; then
      curl -fsSL "$OFFICIAL_INSTALL_URL" | bash
    else
      warn "Без установленного нового Worker восстановление лучше не продолжать."
      pause
      return
    fi
  fi

  warn "Восстановление перезапишет Docker volumes на новом VPS данными из бэкапа."
  warn "Старый .env целиком НЕ будет скопирован. Будет перенесён только SECRET_KEY."
  echo ""
  confirm "Продолжить восстановление на этом VPS?" "n" || { pause; return; }

  info "Останавливаю новый Worker..."
  compose_down

  info "Переношу только SECRET_KEY из старого env.backup..."
  copy_secret_key_only || { pause; return; }

  info "Восстанавливаю основной volume: $DATA_VOL"
  if restore_volume "$DATA_VOL" "funpay-data.tar.gz"; then
    ok "Основной volume восстановлен."
  else
    err "Архив ${MIGRATION_DIR}/funpay-data.tar.gz не найден или не восстановился."
    pause
    return
  fi

  info "Восстанавливаю runtime volume плагинов: $RUNTIME_VOL"
  if restore_volume "$RUNTIME_VOL" "funpay-plugin-runtime.tar.gz"; then
    ok "Runtime volume восстановлен."
  else
    warn "Архив runtime volume не найден. Этот шаг пропущен."
  fi

  info "Запускаю Worker..."
  if compose_up; then
    ok "Worker запущен."
  else
    warn "Не удалось запустить через compose. Проверьте: cd /opt/funpay-worker && docker compose up -d"
  fi

  echo ""
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "Health-check отвечает: Worker работает."
  else
    warn "Health-check пока не ответил. Посмотрите логи через меню."
  fi

  echo ""
  local token ip
  token=$(read_env_value "CONNECTION_TOKEN" || true)
  ip=$(detect_public_ip)
  if [[ -n "$token" ]]; then
    echo -e "${C_GREEN}${C_BOLD}Данные нового VPS для подключения:${C_RESET}"
    echo "IP:    $ip"
    echo "Token: $token"
    echo ""
  fi

  warn "Не удаляйте старый VPS, пока не проверите плагины и заказы в приложении."
  pause
}

migration_menu() {
  while true; do
    banner
    echo -e "${C_BOLD}2) Перенести данные на другой VPS${C_RESET}"
    line
    echo "1. Я на СТАРОМ VPS — создать бэкап и отправить на новый"
    echo "2. Я на НОВОМ VPS — установить Worker и восстановить бэкап"
    echo "3. Только создать локальный бэкап"
    echo "4. Только отправить уже готовый бэкап по SCP"
    echo "5. Только восстановить уже полученный бэкап"
    echo "0. Назад"
    echo ""
    read -r -p "Выберите пункт: " choice
    case "$choice" in
      1) create_migration_backup ;;
      2) restore_migration_backup ;;
      3) create_migration_backup ;;
      4) banner; send_backup_scp; pause ;;
      5) restore_migration_backup ;;
      0) return ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

logs_menu() {
  banner
  echo -e "${C_BOLD}Логи FunPay Pulse Worker${C_RESET}"
  line
  echo "1. Последние 100 строк funpay-worker"
  echo "2. Последние 100 строк funpay-plugin-runner"
  echo "3. Следить за funpay-worker"
  echo "4. Следить за funpay-plugin-runner"
  echo "0. Назад"
  echo ""
  read -r -p "Выберите пункт: " choice
  case "$choice" in
    1) docker logs --tail=100 "$WORKER_CONTAINER" 2>&1 || true; pause ;;
    2) docker logs --tail=100 "$RUNNER_CONTAINER" 2>&1 || true; pause ;;
    3) echo "Ctrl+C чтобы выйти"; docker logs -f "$WORKER_CONTAINER" 2>&1 || true; pause ;;
    4) echo "Ctrl+C чтобы выйти"; docker logs -f "$RUNNER_CONTAINER" 2>&1 || true; pause ;;
    0) return ;;
    *) warn "Неизвестный пункт"; sleep 1 ;;
  esac
}

self_update() {
  banner
  echo -e "${C_BOLD}Самообновление мастера${C_RESET}"
  line
  if [[ -z "$PULSE_MASTER_URL" ]]; then
    warn "PULSE_MASTER_URL не задан. После публикации на GitHub укажи raw-ссылку в переменной внутри скрипта."
    echo "Пример: https://raw.githubusercontent.com/USER/REPO/main/pulse-master.sh"
    pause
    return
  fi
  need_cmd curl || { pause; return; }
  local target="/usr/local/bin/pulse-master"
  confirm "Скачать свежую версию в $target?" "y" || { pause; return; }
  curl -fsSL "$PULSE_MASTER_URL" -o "$target"
  chmod 755 "$target"
  ok "Готово. Теперь можно запускать: pulse-master"
  pause
}

main_menu() {
  require_root
  while true; do
    banner
    echo -e "${C_BOLD}Главное меню${C_RESET}"
    echo ""
    echo "1. 🔑 Узнать токен соединения"
    echo "2. 🚚 Перенести данные на другой VPS"
    echo "3. 🩺 Статус / health / диагностика"
    echo "4. ⚙️  Установить официальный Worker"
    echo "5. ⬆️  Обновить Worker"
    echo "6. 📜 Логи контейнеров"
    echo "7. 🧰 Установить этот мастер как команду pulse-master"
    echo "0. Выход"
    echo ""
    read -r -p "Выберите пункт: " choice
    case "$choice" in
      1) show_token ;;
      2) migration_menu ;;
      3) show_status ;;
      4) install_official_worker ;;
      5) update_worker ;;
      6) logs_menu ;;
      7) self_update ;;
      0) echo "Пока 👋"; exit 0 ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
