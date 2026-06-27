#!/usr/bin/env bash
# FunPay Pulse Master
# by @AndreyCatser
# Safe-by-default: secrets are shown only after confirmation and backups are sent only by user-confirmed SCP.

set -u
set -o pipefail

VERSION="2.1.0"
INSTALL_DIR="/opt/funpay-worker"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
MIGRATION_DIR="/root/pulse-migration"
BACKUP_DIR="/root/pulse-backups"
OFFICIAL_INSTALL_URL="https://funpaypulse.com/install.sh"
PULSE_MASTER_URL="https://raw.githubusercontent.com/SystemHubC/Master/refs/heads/main/pulse-master.sh"
HEALTH_URL="http://localhost:8000/health"
DATA_VOL="funpay-worker_funpay-data"
RUNTIME_VOL="funpay-worker_funpay-plugin-runtime"
DEFAULT_WORKER_CONTAINER="funpay-worker"
DEFAULT_RUNNER_CONTAINER="funpay-plugin-runner"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'

line() { echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; }
thin() { echo -e "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"; }
ok() { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
err() { echo -e "${C_RED}✖${C_RESET} $*" >&2; }
info() { echo -e "${C_CYAN}•${C_RESET} $*"; }

have_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

read_input() {
  local __var="$1"
  local prompt="${2:-}"
  local value=""
  if have_tty; then
    printf "%b" "$prompt" > /dev/tty
    IFS= read -r value < /dev/tty || value=""
  else
    printf "%b" "$prompt"
    IFS= read -r value || value=""
  fi
  printf -v "$__var" '%s' "$value"
}

pause() {
  local _x
  echo ""
  read_input _x "Нажмите Enter, чтобы вернуться в меню... "
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix answer
  if [[ "$default" == "y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  read_input answer "${prompt} ${suffix}: "
  answer="${answer:-$default}"
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|[Дд]|[Дд][Аа])$ ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Запустите от root: curl -fsSL ${PULSE_MASTER_URL} | sudo bash"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Не найдена команда: $1"
    return 1
  }
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
  echo -e "${C_DIM}Worker helper • migration • logs • token • diagnostics${C_RESET}"
  line
}

mask_secret() {
  local s="${1:-}"
  local n=${#s}
  if (( n <= 10 )); then
    echo "********"
  else
    echo "${s:0:4}…${s: -4}"
  fi
}

read_env_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 1
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed "s/^'//;s/'$//;s/^\"//;s/\"$//"
}

detect_public_ip() {
  local ip=""
  local svc
  for svc in "https://ifconfig.me" "https://icanhazip.com" "https://api.ipify.org"; do
    ip=$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$ip" =~ ^[0-9a-fA-F:]{3,}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "не удалось определить"
}

worker_container() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DEFAULT_WORKER_CONTAINER"; then
    echo "$DEFAULT_WORKER_CONTAINER"
    return 0
  fi
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei 'funpay.*worker|worker.*funpay|pulse.*worker' | head -n 1
}

runner_container() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DEFAULT_RUNNER_CONTAINER"; then
    echo "$DEFAULT_RUNNER_CONTAINER"
    return 0
  fi
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei 'funpay.*runner|plugin.*runner|runner.*funpay|pulse.*runner' | head -n 1
}

compose_cmd() {
  if [[ -d "$INSTALL_DIR" ]] && (cd "$INSTALL_DIR" && docker compose version >/dev/null 2>&1); then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

compose_up() {
  local cmd
  cmd=$(compose_cmd)
  if [[ -n "$cmd" && -d "$INSTALL_DIR" ]]; then
    (cd "$INSTALL_DIR" && $cmd up -d) && return 0
  fi
  local wc
  wc=$(worker_container)
  [[ -n "$wc" ]] && docker start "$wc" >/dev/null 2>&1 && return 0
  return 1
}

compose_down() {
  local cmd
  cmd=$(compose_cmd)
  if [[ -n "$cmd" && -d "$INSTALL_DIR" ]]; then
    (cd "$INSTALL_DIR" && $cmd down) >/dev/null 2>&1 && return 0
  fi
  local wc rc
  wc=$(worker_container)
  rc=0
  [[ -n "$wc" ]] && docker stop "$wc" >/dev/null 2>&1 || rc=1
  return $rc
}

compose_restart() {
  local cmd
  cmd=$(compose_cmd)
  if [[ -n "$cmd" && -d "$INSTALL_DIR" ]]; then
    (cd "$INSTALL_DIR" && $cmd restart) && return 0
  fi
  local wc
  wc=$(worker_container)
  [[ -n "$wc" ]] && docker restart "$wc" && return 0
  return 1
}

show_token() {
  banner
  echo -e "${C_WHITE}🔑 Данные подключения VPS${C_RESET}"
  line
  warn "Токен соединения даёт доступ к подключению Worker. Не кидайте его в публичные чаты."
  echo ""
  confirm "Показать токен соединения FunPay Pulse?" "n" || { echo "Отменено."; pause; return; }

  if [[ ! -f "$ENV_FILE" ]]; then
    err "Файл $ENV_FILE не найден. Worker ещё не установлен или установлен в другой папке."
    echo "Установить Worker можно в меню: 2 → 1."
    pause
    return
  fi

  local token signing secret ip
  token=$(read_env_value "CONNECTION_TOKEN" || true)
  signing=$(read_env_value "SIGNING_SECRET" || true)
  secret=$(read_env_value "SECRET_KEY" || true)
  ip=$(detect_public_ip)

  if [[ -z "$token" ]]; then
    err "CONNECTION_TOKEN не найден в $ENV_FILE"
    pause
    return
  fi

  echo ""
  echo -e "${C_GREEN}${C_BOLD}Данные для подключения в приложении FunPay Pulse:${C_RESET}"
  echo ""
  echo -e "${C_BOLD}IP сервера:${C_RESET}  $ip"
  echo -e "${C_BOLD}Порт:${C_RESET}       8000"
  echo -e "${C_BOLD}Токен:${C_RESET}      $token"
  echo ""
  thin
  echo "Короткая проверка:"
  echo "CONNECTION_TOKEN=$(mask_secret "$token")"
  [[ -n "$signing" ]] && echo "SIGNING_SECRET=$(mask_secret "$signing")"
  [[ -n "$secret" ]] && echo "SECRET_KEY=$(mask_secret "$secret")"
  echo ""
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "Health-check отвечает: Worker работает."
  else
    warn "Health-check не ответил. Посмотри диагностику в меню."
  fi
  pause
}

install_fp_token_command() {
  banner
  echo -e "${C_WHITE}🧷 Установить короткую команду fp-token${C_RESET}"
  line
  cat <<'TEXT'
Команда fp-token будет показывать IP и токен подключения без запуска всего мастера.
Перед показом токена она спросит подтверждение.
TEXT
  echo ""
  confirm "Установить /usr/local/bin/fp-token?" "y" || { pause; return; }
  cat > /usr/local/bin/fp-token <<'EOS'
#!/usr/bin/env bash
set -u
ENV_FILE="/opt/funpay-worker/.env"
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
read_tty() { local v=""; if [[ -r /dev/tty && -w /dev/tty ]]; then printf "%b" "$1" > /dev/tty; IFS= read -r v < /dev/tty || v=""; else printf "%b" "$1"; IFS= read -r v || v=""; fi; echo "$v"; }
getv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed "s/^'//;s/'$//;s/^\"//;s/\"$//"; }
ans=$(read_tty "Данная команда показывает токен соединения FunPay Pulse. Хотите продолжить? [y/N]: ")
case "$ans" in y|Y|yes|YES|д|Д|да|Да|ДА) ;; *) echo "Отменено."; exit 0 ;; esac
if [[ ! -f "$ENV_FILE" ]]; then echo -e "${C_RED}Файл $ENV_FILE не найден.${C_RESET}"; exit 1; fi
token=$(getv CONNECTION_TOKEN)
if [[ -z "$token" ]]; then echo -e "${C_RED}CONNECTION_TOKEN не найден.${C_RESET}"; exit 1; fi
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}Данные подключения FunPay Pulse${C_RESET}"
echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}IP сервера:${C_RESET} ${ip:-не удалось определить}"
echo -e "${C_BOLD}Токен:${C_RESET} $token"
echo -e "${C_YELLOW}Скопируйте токен и вставьте его в FunPay Pulse.${C_RESET}"
EOS
  chmod 755 /usr/local/bin/fp-token
  ok "Готово. Теперь можно писать: fp-token"
  pause
}

run_official_install() {
  banner
  echo -e "${C_WHITE}⚙️ Установка официального FunPay Pulse Worker${C_RESET}"
  line
  warn "Будет скачан и запущен официальный установщик: $OFFICIAL_INSTALL_URL"
  echo "Во время установки может понадобиться код из Telegram-бота FunPay Pulse через /vps."
  echo ""
  confirm "Запустить установку сейчас?" "n" || { pause; return; }
  need_cmd curl || { pause; return; }

  local tmp="/tmp/fpp-install.sh"
  info "Скачиваю официальный install.sh..."
  curl -fsSL "$OFFICIAL_INSTALL_URL" -o "$tmp" || { err "Не удалось скачать install.sh"; pause; return; }
  chmod +x "$tmp"
  info "Запускаю установщик..."
  bash "$tmp"
  echo ""
  ok "Установщик завершил работу."
  echo ""
  if [[ -f "$ENV_FILE" ]]; then
    local token
    token=$(read_env_value "CONNECTION_TOKEN" || true)
    [[ -n "$token" ]] && ok "Токен найден. Его можно посмотреть в пункте 1 или командой fp-token."
  fi
  pause
}

update_worker() {
  banner
  echo -e "${C_WHITE}⬆️ Обновление Worker${C_RESET}"
  line
  if [[ -x "${INSTALL_DIR}/update.sh" ]]; then
    confirm "Запустить ${INSTALL_DIR}/update.sh?" "y" || { pause; return; }
    "${INSTALL_DIR}/update.sh"
  else
    warn "${INSTALL_DIR}/update.sh не найден. Можно повторно запустить официальный install.sh."
    confirm "Скачать и запустить официальный install.sh?" "n" && {
      local tmp="/tmp/fpp-install.sh"
      curl -fsSL "$OFFICIAL_INSTALL_URL" -o "$tmp" && bash "$tmp"
    }
  fi
  pause
}

restart_worker() {
  banner
  echo -e "${C_WHITE}🔄 Перезапуск Worker${C_RESET}"
  line
  confirm "Перезапустить Worker?" "y" || { pause; return; }
  if compose_restart; then
    ok "Worker перезапущен."
  else
    err "Не удалось перезапустить. Проверь: docker ps -a и $INSTALL_DIR"
  fi
  pause
}

worker_menu() {
  while true; do
    banner
    echo -e "${C_WHITE}⚙️ Worker: установка / обновление / управление${C_RESET}"
    line
    echo "1. Установить официальный Worker"
    echo "2. Обновить Worker"
    echo "3. Перезапустить Worker"
    echo "4. Запустить Worker"
    echo "5. Остановить Worker"
    echo "6. Установить команду fp-token"
    echo "0. Назад"
    echo ""
    local choice
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) run_official_install ;;
      2) update_worker ;;
      3) restart_worker ;;
      4) banner; compose_up && ok "Worker запущен." || err "Не удалось запустить Worker."; pause ;;
      5) banner; confirm "Остановить Worker?" "n" && compose_down && ok "Worker остановлен."; pause ;;
      6) install_fp_token_command ;;
      0) return ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

show_status() {
  banner
  echo -e "${C_WHITE}🩺 Статус / health / диагностика${C_RESET}"
  line
  echo -e "${C_BOLD}Система:${C_RESET}"
  echo "Host: $(hostname 2>/dev/null || echo unknown)"
  echo "IP:   $(detect_public_ip)"
  echo "Uptime: $(uptime -p 2>/dev/null || true)"
  echo ""
  echo -e "${C_BOLD}Диск:${C_RESET}"
  df -h / 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo -e "${C_BOLD}RAM:${C_RESET}"
  free -h 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo -e "${C_BOLD}Docker:${C_RESET}"
  if command -v docker >/dev/null 2>&1; then
    docker --version 2>/dev/null || true
    echo ""
    echo "Контейнеры FunPay/Pulse:"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -Ei 'NAMES|funpay|pulse|plugin-runner' || warn "Контейнеры FunPay/Pulse не найдены."
    echo ""
    echo "Volumes FunPay/Pulse:"
    docker volume ls 2>/dev/null | grep -Ei 'funpay|pulse' || warn "Volumes FunPay/Pulse не найдены."
  else
    warn "Docker не установлен."
  fi
  echo ""
  echo -e "${C_BOLD}Worker health:${C_RESET}"
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 "$HEALTH_URL"; then
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

quick_repair() {
  banner
  echo -e "${C_WHITE}🛠️ Быстрый ремонт${C_RESET}"
  line
  echo "1. Перезапустить Worker"
  echo "2. Перезапустить Docker"
  echo "3. Очистить неиспользуемые Docker-образы"
  echo "4. Показать последние ошибки Worker"
  echo "0. Назад"
  echo ""
  local choice wc
  read_input choice "Выберите пункт: "
  case "$choice" in
    1) restart_worker ;;
    2) confirm "Перезапустить Docker daemon?" "n" && systemctl restart docker && ok "Docker перезапущен."; pause ;;
    3) confirm "Очистить неиспользуемые Docker-образы? Контейнеры и volumes не трогаются." "y" && docker image prune -af; pause ;;
    4) wc=$(worker_container); [[ -n "$wc" ]] && docker logs --tail=120 "$wc" 2>&1 || warn "Worker-контейнер не найден."; pause ;;
    0) return ;;
    *) warn "Неизвестный пункт"; sleep 1 ;;
  esac
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
  echo -e "${C_WHITE}📦 Старый VPS → создать бэкап${C_RESET}"
  line
  need_cmd docker || { pause; return; }
  warn "Worker будет остановлен на время архивации."
  warn "В архивах могут быть токены, cookies, базы и данные плагинов. Не публикуйте их."
  echo ""
  confirm "Создать миграционный бэкап?" "n" || { pause; return; }

  mkdir -p "$MIGRATION_DIR"
  chmod 700 "$MIGRATION_DIR"
  info "Останавливаю Worker..."
  compose_down

  info "Архивирую volume: $DATA_VOL"
  if backup_volume "$DATA_VOL" "funpay-data.tar.gz"; then
    ok "Создан: ${MIGRATION_DIR}/funpay-data.tar.gz"
  else
    err "Volume $DATA_VOL не найден или не архивируется."
    pause
    return
  fi

  info "Архивирую volume: $RUNTIME_VOL"
  if backup_volume "$RUNTIME_VOL" "funpay-plugin-runtime.tar.gz"; then
    ok "Создан: ${MIGRATION_DIR}/funpay-plugin-runtime.tar.gz"
  else
    warn "Runtime volume не найден. Пропускаю."
  fi

  [[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "${MIGRATION_DIR}/env.backup" && chmod 600 "${MIGRATION_DIR}/env.backup" && ok "Сохранён env.backup"
  [[ -f "$COMPOSE_FILE" ]] && cp "$COMPOSE_FILE" "${MIGRATION_DIR}/docker-compose.backup.yml" && ok "Сохранён docker-compose.backup.yml"

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
  if confirm "Отправить бэкап на новый VPS по SCP сейчас?" "y"; then
    send_backup_scp
  fi
  echo ""
  if confirm "Запустить Worker обратно на старом VPS? Обычно при миграции лучше оставить выключенным до проверки нового." "n"; then
    compose_up && ok "Worker запущен." || warn "Не удалось запустить Worker."
  else
    warn "Старый Worker оставлен выключенным."
  fi
  pause
}

send_backup_scp() {
  need_cmd scp || { warn "scp не найден. Установите openssh-client или перенесите папку вручную."; return 1; }
  if [[ ! -d "$MIGRATION_DIR" ]]; then
    warn "$MIGRATION_DIR не найден. Сначала создайте бэкап."
    return 1
  fi
  local ip user port target
  read_input ip "IP нового VPS: "
  [[ -n "$ip" ]] || { warn "IP не указан."; return 1; }
  read_input user "SSH пользователь [root]: "
  user="${user:-root}"
  read_input port "SSH порт [22]: "
  port="${port:-22}"
  target="${user}@${ip}:/root/"
  echo ""
  info "Передаю $MIGRATION_DIR → $target"
  scp -P "$port" -r "$MIGRATION_DIR" "$target" && ok "Бэкап отправлен: /root/pulse-migration" || warn "SCP не прошёл. Можно перенести папку вручную через WinSCP/SFTP."
}

copy_secret_key_only() {
  if [[ ! -f "${MIGRATION_DIR}/env.backup" ]]; then
    warn "env.backup не найден. SECRET_KEY не будет перенесён."
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
    for i, line in enumerate(lines):
        if line.startswith('SECRET_KEY='):
            lines[i] = 'SECRET_KEY=' + old['SECRET_KEY']
            break
    else:
        lines.append('SECRET_KEY=' + old['SECRET_KEY'])
new_env.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
  chmod 600 "$ENV_FILE"
  ok "SECRET_KEY перенесён. CONNECTION_TOKEN и SIGNING_SECRET нового VPS сохранены."
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
  echo -e "${C_WHITE}📥 Новый VPS → восстановить бэкап${C_RESET}"
  line
  need_cmd docker || { pause; return; }
  need_cmd python3 || { pause; return; }

  if [[ ! -d "$MIGRATION_DIR" ]]; then
    err "Папка $MIGRATION_DIR не найдена. Сначала перенесите бэкап на новый VPS."
    pause
    return
  fi
  echo "Найдено в $MIGRATION_DIR:"
  ls -lah "$MIGRATION_DIR"
  echo ""

  if [[ ! -f "$ENV_FILE" ]]; then
    warn "Worker на новом VPS ещё не установлен или $ENV_FILE не найден."
    if confirm "Запустить официальный установщик Worker сейчас?" "y"; then
      local tmp="/tmp/fpp-install.sh"
      curl -fsSL "$OFFICIAL_INSTALL_URL" -o "$tmp" && bash "$tmp"
    else
      pause
      return
    fi
  fi

  warn "Восстановление перезапишет Docker volumes на новом VPS данными из бэкапа."
  warn "Старый .env целиком НЕ копируется: переносится только SECRET_KEY."
  echo ""
  confirm "Продолжить восстановление на этом VPS?" "n" || { pause; return; }

  info "Останавливаю Worker..."
  compose_down
  info "Переношу SECRET_KEY..."
  copy_secret_key_only || { pause; return; }

  info "Восстанавливаю $DATA_VOL"
  if restore_volume "$DATA_VOL" "funpay-data.tar.gz"; then
    ok "Основной volume восстановлен."
  else
    err "Архив funpay-data.tar.gz не найден или не восстановился."
    pause
    return
  fi

  info "Восстанавливаю $RUNTIME_VOL"
  if restore_volume "$RUNTIME_VOL" "funpay-plugin-runtime.tar.gz"; then
    ok "Runtime volume восстановлен."
  else
    warn "Runtime архив не найден. Пропускаю."
  fi

  info "Запускаю Worker..."
  compose_up && ok "Worker запущен." || warn "Не удалось запустить через compose."

  echo ""
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "Health-check отвечает."
  else
    warn "Health-check пока не ответил. Посмотрите логи."
  fi

  local token ip
  token=$(read_env_value "CONNECTION_TOKEN" || true)
  ip=$(detect_public_ip)
  if [[ -n "$token" ]]; then
    echo ""
    echo -e "${C_GREEN}${C_BOLD}Данные нового VPS:${C_RESET}"
    echo "IP:    $ip"
    echo "Token: $token"
  fi
  warn "Не удаляйте старый VPS, пока не проверите заказы и плагины в приложении."
  pause
}

local_backup() {
  banner
  echo -e "${C_WHITE}💾 Локальный быстрый бэкап${C_RESET}"
  line
  need_cmd docker || { pause; return; }
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  local stamp out
  stamp=$(date +%Y%m%d-%H%M%S)
  out="${BACKUP_DIR}/pulse-backup-${stamp}.tar.gz"
  warn "Создаётся локальный архив основных данных. Внутри могут быть секреты."
  confirm "Продолжить?" "n" || { pause; return; }
  mkdir -p "/tmp/pulse-backup-${stamp}"
  if docker volume inspect "$DATA_VOL" >/dev/null 2>&1; then
    docker run --rm -v "${DATA_VOL}:/volume:ro" -v "/tmp/pulse-backup-${stamp}:/backup" alpine sh -c 'cd /volume && tar czf /backup/funpay-data.tar.gz .'
  fi
  if docker volume inspect "$RUNTIME_VOL" >/dev/null 2>&1; then
    docker run --rm -v "${RUNTIME_VOL}:/volume:ro" -v "/tmp/pulse-backup-${stamp}:/backup" alpine sh -c 'cd /volume && tar czf /backup/funpay-plugin-runtime.tar.gz .'
  fi
  [[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "/tmp/pulse-backup-${stamp}/env.backup"
  tar czf "$out" -C "/tmp" "pulse-backup-${stamp}"
  rm -rf "/tmp/pulse-backup-${stamp}"
  ok "Локальный бэкап: $out"
  pause
}

migration_menu() {
  while true; do
    banner
    echo -e "${C_WHITE}🚚 Миграция / бэкапы${C_RESET}"
    line
    echo "1. Я на СТАРОМ VPS — создать бэкап и отправить на новый"
    echo "2. Я на НОВОМ VPS — восстановить полученный бэкап"
    echo "3. Только создать миграционный бэкап"
    echo "4. Только отправить готовый бэкап по SCP"
    echo "5. Локальный быстрый бэкап"
    echo "0. Назад"
    echo ""
    local choice
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) create_migration_backup ;;
      2) restore_migration_backup ;;
      3) create_migration_backup ;;
      4) banner; send_backup_scp; pause ;;
      5) local_backup ;;
      0) return ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

logs_menu() {
  while true; do
    banner
    echo -e "${C_WHITE}📜 Логи контейнеров${C_RESET}"
    line
    local wc rc
    wc=$(worker_container)
    rc=$(runner_container)
    echo "Worker: ${wc:-не найден}"
    echo "Runner: ${rc:-не найден}"
    echo ""
    echo "1. Последние 100 строк Worker"
    echo "2. Последние 100 строк Plugin Runner"
    echo "3. Следить за Worker"
    echo "4. Следить за Plugin Runner"
    echo "5. Ошибки Worker за последние 200 строк"
    echo "0. Назад"
    echo ""
    local choice
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) [[ -n "$wc" ]] && docker logs --tail=100 "$wc" 2>&1 || warn "Worker не найден."; pause ;;
      2) [[ -n "$rc" ]] && docker logs --tail=100 "$rc" 2>&1 || warn "Runner не найден."; pause ;;
      3) [[ -n "$wc" ]] && { echo "Ctrl+C чтобы выйти"; docker logs -f "$wc" 2>&1; } || warn "Worker не найден."; pause ;;
      4) [[ -n "$rc" ]] && { echo "Ctrl+C чтобы выйти"; docker logs -f "$rc" 2>&1; } || warn "Runner не найден."; pause ;;
      5) [[ -n "$wc" ]] && docker logs --tail=200 "$wc" 2>&1 | grep -Ei 'error|failed|traceback|exception|ошибка|critical' || warn "Ошибок не найдено или Worker не найден."; pause ;;
      0) return ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

security_menu() {
  while true; do
    banner
    echo -e "${C_WHITE}🔐 Безопасность и .env${C_RESET}"
    line
    echo "1. Проверить права на .env"
    echo "2. Сделать права .env безопасными chmod 600"
    echo "3. Показать маскированные секреты"
    echo "4. Создать копию .env в /root/pulse-backups"
    echo "0. Назад"
    echo ""
    local choice
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) [[ -f "$ENV_FILE" ]] && ls -l "$ENV_FILE" || warn "$ENV_FILE не найден"; pause ;;
      2) [[ -f "$ENV_FILE" ]] && chmod 600 "$ENV_FILE" && ok "Права выставлены: 600" || warn "$ENV_FILE не найден"; pause ;;
      3) banner; if [[ -f "$ENV_FILE" ]]; then for k in CONNECTION_TOKEN SIGNING_SECRET SECRET_KEY CUSTOM_PLUGIN_SIDECAR_CONTROL_TOKEN; do v=$(read_env_value "$k" || true); [[ -n "$v" ]] && echo "$k=$(mask_secret "$v")"; done; else warn "$ENV_FILE не найден"; fi; pause ;;
      4) mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"; if [[ -f "$ENV_FILE" ]]; then cp "$ENV_FILE" "${BACKUP_DIR}/env.$(date +%Y%m%d-%H%M%S).backup" && chmod 600 "${BACKUP_DIR}"/env.*.backup 2>/dev/null || true && ok "Копия .env сохранена в $BACKUP_DIR"; else warn "$ENV_FILE не найден"; fi; pause ;;
      0) return ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

self_install() {
  banner
  echo -e "${C_WHITE}🧰 Установить мастер как команду pulse-master${C_RESET}"
  line
  need_cmd curl || { pause; return; }
  local target="/usr/local/bin/pulse-master"
  echo "Источник: $PULSE_MASTER_URL"
  echo "Куда:     $target"
  echo ""
  confirm "Скачать свежую версию и установить команду pulse-master?" "y" || { pause; return; }
  curl -fsSL "${PULSE_MASTER_URL}?$(date +%s)" -o "$target" || { err "Не удалось скачать мастер."; pause; return; }
  chmod 755 "$target"
  ok "Готово. Теперь можно запускать: pulse-master"
  pause
}

self_update() {
  banner
  echo -e "${C_WHITE}♻️ Обновить мастер с GitHub${C_RESET}"
  line
  need_cmd curl || { pause; return; }
  if [[ "${0}" == "bash" || "${0}" == "-bash" ]]; then
    warn "Мастер запущен через pipe. Чтобы обновить установленную команду, используй пункт установки."
  fi
  local target="/usr/local/bin/pulse-master"
  confirm "Обновить $target из GitHub?" "y" || { pause; return; }
  curl -fsSL "${PULSE_MASTER_URL}?$(date +%s)" -o "$target" || { err "Не удалось скачать."; pause; return; }
  chmod 755 "$target"
  ok "Обновлено. Запуск: pulse-master"
  pause
}

about() {
  banner
  echo -e "${C_WHITE}ℹ️ О мастере${C_RESET}"
  line
  cat <<TEXT
Этот мастер помогает управлять VPS Worker для FunPay Pulse:
• показывает токен подключения;
• ставит официальный Worker через install.sh;
• обновляет и перезапускает Worker;
• делает диагностику и показывает логи;
• переносит данные между VPS через Docker volumes;
• ставит удобную команду fp-token.

Официальный установщик Worker:
$OFFICIAL_INSTALL_URL

Команда запуска мастера из GitHub:
curl -fsSL "${PULSE_MASTER_URL}?\$(date +%s)" -o /tmp/pulse-master.sh && sudo bash /tmp/pulse-master.sh
TEXT
  pause
}

system_tools_menu() {
  while true; do
    banner
    echo -e "${C_WHITE}🩺 Система: статус / безопасность / ремонт${C_RESET}"
    line
    echo "1. Статус VPS, Docker, Worker и .env"
    echo "2. Проверить права на .env"
    echo "3. Сделать права .env безопасными chmod 600"
    echo "4. Показать маскированные секреты"
    echo "5. Создать копию .env в /root/pulse-backups"
    echo "6. Перезапустить Worker"
    echo "7. Перезапустить Docker"
    echo "8. Очистить неиспользуемые Docker-образы"
    echo "9. Показать последние ошибки Worker"
    echo "0. Назад"
    echo ""
    local choice wc
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) show_status ;;
      2) [[ -f "$ENV_FILE" ]] && ls -l "$ENV_FILE" || warn "$ENV_FILE не найден"; pause ;;
      3) [[ -f "$ENV_FILE" ]] && chmod 600 "$ENV_FILE" && ok "Права выставлены: 600" || warn "$ENV_FILE не найден"; pause ;;
      4) banner; if [[ -f "$ENV_FILE" ]]; then for k in CONNECTION_TOKEN SIGNING_SECRET SECRET_KEY CUSTOM_PLUGIN_SIDECAR_CONTROL_TOKEN; do v=$(read_env_value "$k" || true); [[ -n "$v" ]] && echo "$k=$(mask_secret "$v")"; done; else warn "$ENV_FILE не найден"; fi; pause ;;
      5) mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"; if [[ -f "$ENV_FILE" ]]; then cp "$ENV_FILE" "${BACKUP_DIR}/env.$(date +%Y%m%d-%H%M%S).backup" && chmod 600 "${BACKUP_DIR}"/env.*.backup 2>/dev/null || true && ok "Копия .env сохранена в $BACKUP_DIR"; else warn "$ENV_FILE не найден"; fi; pause ;;
      6) restart_worker ;;
      7) confirm "Перезапустить Docker daemon?" "n" && systemctl restart docker && ok "Docker перезапущен."; pause ;;
      8) confirm "Очистить неиспользуемые Docker-образы? Контейнеры и volumes не трогаются." "y" && docker image prune -af; pause ;;
      9) wc=$(worker_container); [[ -n "$wc" ]] && docker logs --tail=200 "$wc" 2>&1 | grep -Ei 'error|failed|traceback|exception|ошибка|critical' || warn "Ошибок не найдено или Worker не найден."; pause ;;
      0) return ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

master_tools_menu() {
  while true; do
    banner
    echo -e "${C_WHITE}🧰 Мастер: установка / обновление / справка${C_RESET}"
    line
    echo "1. Установить как команду pulse-master"
    echo "2. Обновить установленный pulse-master с GitHub"
    echo "3. Показать команду запуска из GitHub"
    echo "4. О мастере"
    echo "0. Назад"
    echo ""
    local choice
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) self_install ;;
      2) self_update ;;
      3) banner; echo "Команда запуска:"; echo ""; echo "curl -fsSL \"${PULSE_MASTER_URL}?\$(date +%s)\" -o /tmp/pulse-master.sh && sudo bash /tmp/pulse-master.sh"; pause ;;
      4) about ;;
      0) return ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

main_menu() {
  require_root
  while true; do
    banner
    echo -e "${C_WHITE}${C_BOLD}Главное меню${C_RESET}"
    echo ""
    echo -e "${C_GREEN}1${C_RESET}. 🔑 Токен соединения"
    echo -e "${C_GREEN}2${C_RESET}. ⚙️  Worker: установка / обновление / управление"
    echo -e "${C_GREEN}3${C_RESET}. 🩺 Система: статус / безопасность / ремонт"
    echo -e "${C_GREEN}4${C_RESET}. 📜 Логи контейнеров"
    echo -e "${C_GREEN}5${C_RESET}. 🚚 Миграция / бэкапы"
    echo -e "${C_GREEN}6${C_RESET}. 🧰 Мастер: установка / обновление / команда запуска"
    echo -e "${C_RED}0${C_RESET}. Выход"
    echo ""
    local choice
    read_input choice "Выберите пункт: "
    case "$choice" in
      1) show_token ;;
      2) worker_menu ;;
      3) system_tools_menu ;;
      4) logs_menu ;;
      5) migration_menu ;;
      6) master_tools_menu ;;
      0) echo "Пока 👋"; exit 0 ;;
      "") ;;
      *) warn "Неизвестный пункт"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
