#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/opt/funpay-worker/.env"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ask_confirm() {
  local answer=""
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "${YELLOW}Данная команда показывает токен соединения FunPay Pulse.${RESET}\n" > /dev/tty
    printf "Хотите продолжить? [y/N]: " > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
  else
    printf "${YELLOW}Данная команда показывает токен соединения FunPay Pulse.${RESET}\n"
    printf "Хотите продолжить? [y/N]: "
    IFS= read -r answer || answer=""
  fi

  case "${answer,,}" in
    y|yes|д|да) return 0 ;;
    *) echo "Отменено."; exit 0 ;;
  esac
}

get_value() {
  local key="$1"
  local file="$2"
  awk -F= -v k="$key" '
    $1 == k {
      sub(/^[^=]*=/, "")
      gsub(/^\047|\047$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file"
}

ask_confirm

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}Файл ${ENV_FILE} не найден.${RESET}"
  echo "FunPay Pulse Worker не установлен или установлен в другой папке."
  echo "Проверьте: ls -la /opt/funpay-worker"
  exit 1
fi

TOKEN="$(get_value "CONNECTION_TOKEN" "$ENV_FILE" || true)"

if [[ -z "${TOKEN}" ]]; then
  echo -e "${RED}CONNECTION_TOKEN не найден в ${ENV_FILE}.${RESET}"
  exit 1
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

printf "\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "${GREEN}${BOLD}Данные подключения FunPay Pulse${RESET}\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "\n"
printf "${BOLD}IP сервера:${RESET} %s\n" "${SERVER_IP:-не удалось определить}"
printf "${BOLD}Токен соединения:${RESET} %s\n" "$TOKEN"
printf "\n"
printf "${YELLOW}Скопируйте токен и вставьте его в приложении FunPay Pulse.${RESET}\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
