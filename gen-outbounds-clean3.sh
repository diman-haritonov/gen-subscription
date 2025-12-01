#!/bin/sh



TMP_RUNDIR="/tmp/s_descr"

# Очищаем временную директорию
rm -rf "$TMP_RUNDIR"
mkdir -p "$TMP_RUNDIR"

SUB_URL="https://xray.abvpn.ru/vless/62daf674-d53d-403c-86e3-afd37ee09806/133395595.json#abvpn"
SUB_FILE="$TMP_RUNDIR/subscription_url.txt"
TMP_SUB="$TMP_RUNDIR/sb_sub.raw"

CONFIG="/etc/sing-box/config.json"
BACKUP_DIR="/etc/sing-box/backups"

TMP_CLEAN="$TMP_RUNDIR/sb_clean.json"
TMP_PARSED="$TMP_RUNDIR/sb_parsed.jsonl"
TMP_ARRAY="$TMP_RUNDIR/sb_array.json"

EXIST_FILE="$TMP_RUNDIR/sb_existing.jsonl"
EXIST_ARRAY="$TMP_RUNDIR/sb_existing_array.json"
MERGED="$TMP_RUNDIR/sb_merged.json"

TMP_ALIVE="$TMP_RUNDIR/sb_alive.jsonl"
TMP_ALIVE_ARRAY="$TMP_RUNDIR/sb_alive_array.json"
FINAL="$TMP_RUNDIR/sb_alive_tagged.json"

TMP_CONFIG="$TMP_RUNDIR/sb_new_config.json"

mkdir -p "$BACKUP_DIR"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Требуется утилита: $1"
    exit 1
  }
}
need_bin jq sed

clean_line() {
  printf '%s' "$1" | \
    tr -d '\r' | \
    sed 's/\xEF\xBB\xBF//g' | \
    sed 's/\xE2\x80\x8B//g' | \
    sed 's/\xC2\xA0//g'
}

echo "[*] Загрузка подписки..."
curl -s -o $SUB_FILE "$SUB_URL"
cp $SUB_FILE "$TMP_SUB"
if [ $? -ne 0 ]; then
  echo "[ERR] Не удалось скачать подписку"
  exit 1
fi


TS=$(date +%Y%m%d-%H%M%S)
cp "$CONFIG" "$BACKUP_DIR/config-$TS.json"
echo "[OK] Бэкап: $BACKUP_DIR/config-$TS.json"

echo "[*] Очистка config.json от комментариев..."
grep -vE '^\s*#' "$CONFIG" | grep -vE '^\s*//' > "$TMP_CLEAN"
# Проверяем валидность
jq empty "$TMP_CLEAN" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "[ERR] config.json остаётся НЕКОРРЕКТНЫМ JSON после удаления комментариев. Проверь вручную."
  exit 1
fi
echo "[OK] Конфиг очищен и валиден."


echo "[*] Парсинг подписки..."

: > "$TMP_PARSED"

grep -i '^vless://' "$SUB_FILE" | while read -r RAW; do
  
  CLEAN="$(clean_line "$RAW")"
  URL="${CLEAN%%#*}"

  HOSTPORT=$(printf '%s' "$URL" | sed -n 's|^vless://[^@]*@\([^/?#]*\).*|\1|p')
  HOST=$(printf '%s' "$HOSTPORT" | cut -d':' -f1)
  PORT=$(printf '%s' "$HOSTPORT" | cut -d':' -f2)

  UUID=$(printf '%s' "$URL" | sed -n 's|^vless://\([^@]*\)@.*|\1|p')

  TYPE=$(printf '%s' "$URL" | sed -n 's|.*type=\([^&]*\).*|\1|p')
  SECURITY=$(printf '%s' "$URL" | sed -n 's|.*security=\([^&]*\).*|\1|p')
  SNI=$(printf '%s' "$URL" | sed -n 's|.*sni=\([^&]*\).*|\1|p')
  PBK=$(printf '%s' "$URL" | sed -n 's|.*pbk=\([^&]*\).*|\1|p')
  SID=$(printf '%s' "$URL" | sed -n 's|.*sid=\([^&]*\).*|\1|p')
  PATH_V=$(printf '%s' "$URL" | sed -n 's|.*path=\([^&]*\).*|\1|p')

  GRPC_SERVICE=$(printf '%s' "$URL" | sed -n 's|.*serviceName=\([^&]*\).*|\1|p')

  # ✦ Фильтр RU хостов
  printf '%s' "$HOST" | grep -qi '^ru' && {
    echo "[-] Пропускаем RU хост: $HOST"
    continue
  }

  # ✦ Определение транспорта
  TRANSPORT=null

  # tcp (reality или tls)
  if [ "$TYPE" = "tcp" ] && { [ "$SECURITY" = "reality" ] || [ "$SECURITY" = "tls" ]; }; then
    TRANSPORT=null

  # ws
  elif [ "$TYPE" = "ws" ]; then
    TRANSPORT=$(jq -nc --arg path "$PATH_V" '{type:"ws", path:$path}')

  # grpc
  elif [ "$TYPE" = "grpc" ]; then
    TRANSPORT=$(jq -nc --arg sn "$GRPC_SERVICE" '{type:"grpc", service_name:$sn}')

  else
    echo "[-] Пропускаем неподдерживаемый тип: type=$TYPE security=$SECURITY"
    continue
  fi

  # ✦ TLS блок
  TLS=$(jq -nc \
    --arg sec "$SECURITY" \
    --arg sni "$SNI" \
    --arg pbk "$PBK" \
    --arg sid "$SID" '
      if $sec=="reality" then
        {
          enabled:true,
          server_name:$sni,
          reality:{enabled:true, public_key:$pbk, short_id:$sid},
          utls:{enabled:true,fingerprint:"firefox"}
        }
      elif $sec=="tls" then
        {
          enabled:true,
          server_name:$sni,
          utls:{enabled:true,fingerprint:"firefox"}
        }
      else
        {enabled:false}
      end
  ')

  OBJ=$(jq -nc \
    --arg host "$HOST" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --argjson tls "$TLS" \
    --argjson transport "$TRANSPORT" '
    {
      server:$host,
      server_port:$port,
      uuid:$uuid,
      type:"vless",
      tls:$tls,
      transport:$transport
    }')

  printf '%s\n' "$OBJ" >> "$TMP_PARSED"

done

COUNT=$(wc -l < "$TMP_PARSED")
echo "[OK] Распарсено нод: $COUNT"

jq -s '.' "$TMP_PARSED" > "$TMP_ARRAY"
echo "[OK] JSON-массив создан → $TMP_ARRAY"

# ---------------------------------------------------------
# MERGE: EXISTING VLESS + SUBSCRIPTION
# ---------------------------------------------------------


echo "[*] Извлекаем существующие VLESS-ноды из config.json..."

# забираем все outbounds c type=vless
jq '.outbounds[] | select(.type=="vless")' "$CONFIG" | jq -c . > "$EXIST_FILE"

EXIST_COUNT=$(wc -l < "$EXIST_FILE")
echo "[*] Найдено существующих vless-нод: $EXIST_COUNT"

# превращаем в массив
jq -s '.' "$EXIST_FILE" > "$EXIST_ARRAY"

# объединяем существующие + подписка
###jq -s '.[0] + .[1]' "$EXIST_ARRAY" "$TMP_ARRAY" > "$MERGED"
jq -s '
  (.[0] + .[1])
  | unique_by(.server, .server_port, .uuid)
' "$EXIST_ARRAY" "$TMP_ARRAY" > "$MERGED"

MERGED_COUNT=$(jq 'length' "$MERGED")
echo "[OK] Итоговый объединённый список нод: $MERGED_COUNT"
echo "[OK] Файл: $MERGED"




check_alive() {
    HOST="$1"
    PORT="$2"
    TYPE="$3"

    # Если есть ncat — используем его (лучший вариант)
    if command -v ncat >/dev/null 2>&1; then
        timeout 2 ncat -z "$HOST" "$PORT" >/dev/null 2>&1 && return 0
        return 1
    fi

    # Если нет ncat — используем ping (reality / grpc / tls)
    ping -c1 -W1 "$HOST" >/dev/null 2>&1 && return 0

    return 1
}



: > "$TMP_ALIVE"

LEN=$(jq 'length' $MERGED)
i=0

echo "[*] Проверка доступности нод..."

while [ "$i" -lt "$LEN" ]; do
    NODE=$(jq -c ".[$i]" $MERGED)
    i=$((i+1))

    S=$(echo "$NODE" | jq -r '.server')
    P=$(echo "$NODE" | jq -r '.server_port')
    TYPE_NODE=$(echo "$NODE" | jq -r '.transport.type // "reality"')

    if check_alive "$S" "$P" "$TYPE_NODE"; then
	echo "[+] Живой: $S:$P"
	echo "$NODE" >> "$TMP_ALIVE"
    else
	echo "[-] Недоступен: $S:$P (type=$TYPE_NODE)"
    fi
done

jq -s '.' "$TMP_ALIVE" > "$TMP_ALIVE_ARRAY"
echo "[OK] Живые ноды собраны: $TMP_ALIVE_ARRAY"


echo "[*] Добавление тегов proxyN..."

jq 'to_entries
    | map(.value + {tag: ("proxy" + (.key|tostring))})
    | map(.)' \
    "$TMP_ALIVE_ARRAY" > "$FINAL"

TAGGED_COUNT=$(jq 'length' "$FINAL")
echo "[OK] Присвоено тегов: $TAGGED_COUNT"
echo "[OK] Итоговый файл с тегами: $FINAL"

# ---------------------------------------------------------
#  СБОР НОВОГО КОНФИГА
# ---------------------------------------------------------



jq --argfile p $FINAL '
  # p = массив прокси
  $p as $proxies
  |
  # извлекаем массив тегов
  ($proxies | map(.tag)) as $tags
  |
  # создаём новые блоки
  {
    "tag": "Internet",
    "type": "selector",
    "outbounds": (["Best Latency"] + $tags)
  } as $internet
  |
  {
    "tag": "Best Latency",
    "type": "urltest",
    "outbounds": $tags,
    "url": "https://detectportal.firefox.com/success.txt",
    "interval": "60s",
    "tolerance": 50,
    "interrupt_exist_connections": false
  } as $best
  |
  (
    .outbounds
    |
    map(
      select(
        # 1) пропускаем proxyN без regex: tag может быть "proxy12" → проверка начинается ли строка с "proxy"
        (
          ( .tag? | tostring ) as $t
          | ( $t | startswith("proxy") | not )
        )
        # 2) исключаем Internet
        and (.tag? != "Internet")
        # 3) исключаем Best Latency
        and (.tag? != "Best Latency")
      )
    )
  ) as $tail
  |
  .outbounds = ( [$internet, $best] + $proxies + $tail )
' "$TMP_CLEAN" > "$TMP_CONFIG"
echo "[OK] Промежуточный конфигурационный файл: $TMP_CONFIG"


# safety: проверим, что TMP_CONFIG существует
if [ -z "$TMP_CONFIG" ] || [ ! -f "$TMP_CONFIG" ]; then
  echo "[ERR] Временный конфиг не найден: $TMP_CONFIG"
  exit 1
fi

echo "[*] Копирование $TMP_CONFIG -> $CONFIG (предварительная проверка конфигурации sing-box)..."

# копируем временный конфиг в реальное место (перезаписываем)
cp "$TMP_CONFIG" "$CONFIG"
if [ $? -ne 0 ]; then
  echo "[ERR] Не удалось скопировать $TMP_CONFIG -> $CONFIG"
  exit 1
fi

# ------------------------------
#  Выполняем sing-box check
# ------------------------------

CHECK_TMP=$(mktemp "$TMP_RUNDIR/singbox_check_XXXXXX")


# если утилита sing-box доступна — используем её, иначе сообщаем и пропускаем проверку
if command -v sing-box >/dev/null 2>&1; then
  # запускаем проверку и сохраняем вывод
  sing-box check -c "$CONFIG" >"$CHECK_TMP" 2>&1
  SINGBOX_RC=$?
  CHECK_OUTPUT=$(cat "$CHECK_TMP")
else
  echo "[WARN] sing-box не найден в PATH. Пропускаем 'sing-box check'."
  SINGBOX_RC=0
  CHECK_OUTPUT=""
fi

# анализ результата на наличие "FATAL"
echo "[*] Анализ вывода sing-box check..."
if printf '%s' "$CHECK_OUTPUT" | grep -Fq "FATAL"; then
  echo "[ERR] sing-box check вернул FATAL. Печатаю полный вывод:"
  printf '%s\n' "$CHECK_OUTPUT"
  echo

  # ищем последний бэкап
  LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/config-*.json 2>/dev/null | head -n 1)
  if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
    cp "$LATEST_BACKUP" "$CONFIG"
    if [ $? -eq 0 ]; then
      echo "[OK] Конфигурация восстановлена из бэкапа: $LATEST_BACKUP"
    else
      echo "[ERR] Не удалось восстановить конфиг из бэкапа: $LATEST_BACKUP"
    fi
  else
    echo "[ERR] Бэкапов не найдено в $BACKUP_DIR. Ручное восстановление требуется."
  fi

  # убираем временный файл и выходим с ошибкой
  rm -f "$CHECK_TMP" 2>/dev/null
  # После восстановления — пытаемся перезапустить сервис (см. шаг 4)
else
  echo "[OK] Файл конфигурации успешно скопирован и проверен через sing-box check."
  # при отсутствии sing-box вывод может быть пустым — в этом случае проходим дальше
fi

# ------------------------------
#  Шаг 4: Перезапуск и проверка процесса
# ------------------------------
echo "[*] Перезапуск сервиса sing-box..."

RESTART_OK=1

# Сначала попробуем system-style service (service command)
if command -v service >/dev/null 2>&1; then
  service sing-box restart >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    RESTART_OK=0
  fi
fi

# Фоллбэк на /etc/init.d script
if [ $RESTART_OK -ne 0 ] && [ -x /etc/init.d/sing-box ]; then
  /etc/init.d/sing-box restart >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    RESTART_OK=0
  fi
fi

# Если оба метода не сработали — пытаемся запустить просто бинарником (осторожно)
if [ $RESTART_OK -ne 0 ] && command -v sing-box >/dev/null 2>&1; then
  sing-box run >/dev/null 2>&1 &
  sleep 1
fi

# Проверяем наличие процесса sing-box
sleep 2
if ps | grep -v grep | grep -q "sing-box"; then
  echo "[OK] Сервис sing-box успешно перезапущен (процесс найден)."
else
  echo "[ERR] Сервис sing-box не запущен (процесс не найден)."
fi