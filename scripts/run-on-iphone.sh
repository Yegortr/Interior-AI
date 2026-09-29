#!/usr/bin/env bash
# Собирает Reroom и устанавливает его на подключённый iPhone одной командой.
#
#   ./scripts/run-on-iphone.sh
#
# Необязательные переменные окружения:
#   DEVELOPMENT_TEAM=ABCDE12345   Team ID (по умолчанию берётся из сертификата Apple Development)
#   BUNDLE_ID=com.me.reroom       Bundle identifier (по умолчанию com.yegortr.reroom)
#   DEVICE=<UDID или имя>         Какой iPhone использовать, если подключено несколько
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf "\n\033[1;32m▶ %s\033[0m\n" "$1"; }
note() { printf "  %s\n" "$1"; }
fail() { printf "\n\033[1;31m✖ %s\033[0m\n" "$1" >&2; exit 1; }
trap 'printf "\n\033[1;31m✖ Скрипт остановился на строке %s (код %s). Пришлите этот вывод.\033[0m\n" "$LINENO" "$?" >&2' ERR

mkdir -p build
LOG=build/xcodebuild.log

# 1. Инструменты ---------------------------------------------------------------
step "Проверяю инструменты"
command -v xcodebuild >/dev/null || fail "Xcode не найден. Установите Xcode из App Store и откройте его один раз."
xcodebuild -version 2>/dev/null | sed -n 1p
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || fail "Нужен Homebrew (https://brew.sh) или XcodeGen: brew install xcodegen"
  note "Устанавливаю XcodeGen…"
  brew install xcodegen
fi

# 2. Ключи Supabase ------------------------------------------------------------
SECRETS=Config/Secrets.xcconfig
secrets_valid() {
  [ -f "$SECRETS" ] || return 1
  grep -Eq '^SUPABASE_URL = https:/\$\(\)/[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?$' "$SECRETS" || return 1
  grep -Eq '^SUPABASE_ANON_KEY = [A-Za-z0-9._-]{20,}$' "$SECRETS" || return 1
  # Секретный ключ в приложении недопустим.
  ! grep -Eq 'InNlcnZpY2Vfcm9sZSI|sb_secret_' "$SECRETS"
}
if [ "${RESET_SUPABASE:-}" = 1 ] || ! secrets_valid; then
  step "Настройка Supabase (Dashboard → Project Settings → API)"
  # Отбрасываем всё, что было вставлено заранее, чтобы оно не стало ответом.
  if [ -t 0 ]; then while read -r -t 1 _; do :; done; fi
  note "Нужен ключ «anon public» (или «publishable»). НЕ service_role — он секретный."
  while :; do
    read -r -p "  SUPABASE_ANON_KEY: " SB_KEY
    SB_KEY=$(printf '%s' "$SB_KEY" | tr -d '[:space:]')
    if ! printf '%s' "$SB_KEY" | grep -Eq '^[A-Za-z0-9._-]{20,}$'; then
      note "Это не похоже на ключ. Он начинается с eyJ… или sb_publishable_…"
      continue
    fi
    # Из JWT-ключа достаём роль и id проекта (ref), чтобы не спрашивать URL.
    KEY_INFO=$(python3 - "$SB_KEY" <<'PY' 2>/dev/null || true
import base64, json, sys
parts = sys.argv[1].split(".")
if len(parts) == 3:
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload))
    print(f"{data.get('role', '')}|{data.get('ref', '')}")
PY
)
    KEY_ROLE="${KEY_INFO%%|*}"
    KEY_REF="${KEY_INFO#*|}"
    if [ "$KEY_ROLE" = "service_role" ] || printf '%s' "$SB_KEY" | grep -q '^sb_secret_'; then
      printf "\n\033[1;31m  Это СЕКРЕТНЫЙ ключ (service_role). Его нельзя класть в приложение.\033[0m\n"
      note "Возьмите ключ «anon public» там же: Project Settings → API Keys."
      note "И лучше перевыпустите service_role ключ, раз он был показан."
      continue
    fi
    break
  done
  SB_HOST=""
  if [ -n "$KEY_REF" ] && [ "$KEY_REF" != "$KEY_INFO" ]; then
    SB_HOST="$KEY_REF.supabase.co"
    note "Адрес проекта из ключа: https://$SB_HOST"
  fi
  while [ -z "$SB_HOST" ]; do
    read -r -p "  SUPABASE_URL (https://xxxx.supabase.co): " SB_URL
    SB_URL=$(printf '%s' "$SB_URL" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    CANDIDATE=$(printf '%s' "$SB_URL" | sed -E 's#^https?://##; s#/.*$##')
    if printf '%s' "$CANDIDATE" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?$'; then
      SB_HOST="$CANDIDATE"
    else
      note "Это не адрес проекта. Пример: https://abcdefghijkl.supabase.co (Project Settings → Data API)"
    fi
  done
  cat > "$SECRETS" <<EOF
SUPABASE_URL = https:/\$()/$SB_HOST
SUPABASE_ANON_KEY = $SB_KEY
EOF
  note "Сохранено в $SECRETS (файл не попадает в git)."
else
  note "Ключи Supabase уже настроены ($SECRETS). Изменить: RESET_SUPABASE=1 $0"
fi

# 3. Команда разработчика ------------------------------------------------------
step "Ищу вашу команду разработчика"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM_ID" ]; then
  TEAM_ID=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
if [ -z "$TEAM_ID" ]; then
  fail "Не найден сертификат Apple Development. Один раз сделайте в Xcode:
   Xcode → Settings → Accounts → «+» → войдите с Apple ID →
   выберите команду → Manage Certificates → «+» → Apple Development.
   Затем запустите скрипт снова (или: DEVELOPMENT_TEAM=XXXXXXXXXX $0)."
fi
note "Team ID: $TEAM_ID"
BUNDLE_ID="${BUNDLE_ID:-com.yegortr.reroom}"
note "Bundle ID: $BUNDLE_ID"

# 4. Проект и устройство ------------------------------------------------------
step "Генерирую Xcode-проект"
xcodegen generate --quiet

step "Ищу подключённый iPhone"
DESTS=$(xcodebuild -project Reroom.xcodeproj -scheme Reroom -showdestinations 2>/dev/null || true)
AVAILABLE=$(printf '%s\n' "$DESTS" | awk '/Ineligible destinations/{exit} {print}')
INELIGIBLE=$(printf '%s\n' "$DESTS" | awk 'f{print} /Ineligible destinations/{f=1}')

dest_field() { printf '%s' "$1" | sed -E "s/.*$2:([^,}]+).*/\1/" | sed -E 's/[[:space:]]+$//'; }

# Только реальные устройства: «platform:iOS,» (у симуляторов «platform:iOS Simulator»).
DEVICE_LINE=$(printf '%s\n' "$AVAILABLE" | grep -E 'platform:iOS,' | grep -vi placeholder | grep -i -- "${DEVICE:-}" | head -1 || true)
USE_SIMULATOR=0

if [ -n "$DEVICE_LINE" ]; then
  DEST_ID=$(dest_field "$DEVICE_LINE" id)
  DEST_NAME=$(dest_field "$DEVICE_LINE" name)
  note "Устройство: $DEST_NAME ($DEST_ID)"
else
  BLOCKED=$(printf '%s\n' "$INELIGIBLE" | grep -E 'platform:iOS,' | grep -vi placeholder | head -1 || true)
  if [ -n "$BLOCKED" ]; then
    note "iPhone виден, но Xcode пока не может на него ставить:"
    note "$(printf '%s' "$BLOCKED" | sed -E 's/.*error:([^}]*).*/\1/')"
    note "Обычно помогает: разблокировать телефон, включить Настройки → Конфиденциальность и безопасность →"
    note "Режим разработчика, и один раз открыть Xcode → Window → Devices and Simulators, дождавшись подготовки телефона."
  else
    note "iPhone не найден. Подключите его кабелем, разблокируйте и нажмите «Доверять этому компьютеру»."
  fi
  SIM_LINE=$(printf '%s\n' "$AVAILABLE" | grep -E 'platform:iOS Simulator' | grep -E 'name:iPhone' | tail -1 || true)
  [ -n "$SIM_LINE" ] || fail "Нет ни iPhone, ни симулятора. Исправьте подключение телефона и запустите скрипт снова."
  read -r -p "  Запустить пока в симуляторе на Mac? [Y/n] " ANSWER
  case "$ANSWER" in [nNнН]*) fail "Подключите iPhone и запустите скрипт снова." ;; esac
  USE_SIMULATOR=1
  DEST_ID=$(dest_field "$SIM_LINE" id)
  DEST_NAME="симулятор $(dest_field "$SIM_LINE" name)"
  note "Устройство: $DEST_NAME"
fi

# 5. Сборка --------------------------------------------------------------------
# Release: оптимизированная сборка, как в App Store. Debug заметно медленнее (задержки при
# открытии экранов). Для отладки: CONFIG=Debug ./scripts/run-on-iphone.sh
CONFIG="${CONFIG:-Release}"
build() {
  xcodebuild \
    -project Reroom.xcodeproj \
    -scheme Reroom \
    -configuration "$CONFIG" \
    -destination "id=$DEST_ID" \
    -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Automatic \
    "$@" \
    build >"$LOG" 2>&1
}

step "Собираю приложение (первый раз — несколько минут: скачиваются пакеты)…"
if ! build; then
  if grep -q "No Accounts" "$LOG"; then
    fail "В Xcode не добавлен Apple ID (без него Xcode не может выпустить профиль подписи). Сделайте один раз:
   откройте Xcode → Settings (⌘,) → Accounts → «+» → Apple ID → войдите аккаунтом разработчика.
   Затем снова запустите: ./scripts/run-on-iphone.sh"
  fi
  if grep -qiE "icloud|cloudkit|aps-environment|push notification" "$LOG"; then
    note "Не удалось выпустить профиль с iCloud/Push — собираю без синхронизации iCloud (дизайны хранятся только на телефоне)."
    note "Чтобы включить iCloud: откройте Reroom.xcodeproj в Xcode → Signing & Capabilities и дайте Xcode исправить профиль."
    build CODE_SIGN_ENTITLEMENTS= || true
  fi
fi
if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
  printf "\n"
  grep -E "error:" "$LOG" | sort -u | head -30 || true
  fail "Сборка не удалась. Полный лог: $LOG"
fi

if [ "$USE_SIMULATOR" = 1 ]; then PRODUCTS_DIR=$CONFIG-iphonesimulator; else PRODUCTS_DIR=$CONFIG-iphoneos; fi
APP="build/DerivedData/Build/Products/$PRODUCTS_DIR/Reroom.app"
[ -d "$APP" ] || fail "Не найден собранный $APP"

# 6. Установка и запуск --------------------------------------------------------
if [ "$USE_SIMULATOR" = 1 ]; then
  step "Запускаю в $DEST_NAME"
  xcrun simctl boot "$DEST_ID" 2>/dev/null || true
  open -a Simulator
  xcrun simctl bootstatus "$DEST_ID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$DEST_ID" "$APP"
  xcrun simctl launch "$DEST_ID" "$BUNDLE_ID" >/dev/null
  printf "\n\033[1;32m✔ Reroom запущен в %s\033[0m\n" "$DEST_NAME"
  exit 0
fi

step "Устанавливаю на $DEST_NAME"
xcrun devicectl device install app --device "$DEST_ID" "$APP" >/dev/null

step "Запускаю"
if ! xcrun devicectl device process launch --device "$DEST_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
  note "Приложение установлено, но iOS пока не доверяет разработчику. На iPhone:"
  note "Настройки → Основные → VPN и управление устройством → ваш Apple ID → Доверять."
  note "Потом откройте Reroom с главного экрана."
  exit 0
fi

printf "\n\033[1;32m✔ Reroom запущен на %s\033[0m\n" "$DEST_NAME"
