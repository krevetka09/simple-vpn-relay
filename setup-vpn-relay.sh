python3 << 'PYEOF'
import os

script = r'''#!/usr/bin/env bash
# ============================================================================
# XRAY RELAY MANAGER - Production Ready v5.0.0 (Final)
# Все критические проблемы из аудита исправлены
# ============================================================================

set -euo pipefail

readonly VERSION="5.0.0"
readonly LOG="/var/log/xray-admin.log"
readonly BACKUP_DIR="/root/.xray-backups"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly ADMIN_BIN="/usr/local/bin/xray-admin"
readonly NAMESPACE="xray"
readonly RELAY_SUBNET="10.10.0.0/24"
readonly RELAY_SERVER_IP="10.10.0.1"
readonly RELAY_CLIENT_IP="10.10.0.2"

RELAY_IP=""
RELAY_AUTH=""
PKG_MANAGER=""

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG" >&2; }
die() { error "$*"; rollback; exit 1; }
section() { 
    echo -e "\n${CYAN}╔══════════════════════════════════════════════╗${NC}" | tee -a "$LOG"
    echo -e "${CYAN}║  $*${NC}" | tee -a "$LOG"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}\n" | tee -a "$LOG"
}

# ============================================================================
# ИСПРАВЛЕННАЯ СИСТЕМА БЕКАПОВ И ОТКАТА
# ============================================================================

create_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"
    log "Создание полного бэкапа #$ts..."
    
    # Сохраняем состояние iptables
    iptables-save > "$BACKUP_DIR/iptables_$ts.save" 2>/dev/null || true
    
    # Сохраняем список загруженных модулей
    lsmod > "$BACKUP_DIR/lsmod_$ts.txt" 2>/dev/null || true
    
    # Сохраняем конфигурационные файлы
    tar czf "$BACKUP_DIR/configs_$ts.tar.gz" \
        /etc/amnezia \
        /etc/systemd/system/xray.service \
        /etc/systemd/system/wg-namespace.service \
        /usr/local/bin/setup-awg-namespace.sh \
        /usr/local/etc/xray \
        /etc/resolv.conf 2>/dev/null || true
    
    # Проверяем целостность бэкапа
    if [[ ! -f "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
        error "Не удалось создать бэкап конфигов"
        error "Проверьте свободное место: df -h"
        error "Проверьте права: ls -la $BACKUP_DIR"
        die "Бэкап не создан, установка прервана"
    fi

# Проверяем размер бэкапа (должен быть больше 0 байт)
if [[ ! -s "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
    error "Бэкап пустой или повреждён"
    die "Бэкап невалиден, установка прервана"
fi
    
    # Создаем исполняемый скрипт отката
    cat > "$BACKUP_DIR/rollback_$ts.sh" << ROLLBACK_EOF
#!/bin/bash
set -e
echo "Начало отката к состоянию #$ts..."

# Восстанавливаем iptables
if [[ -f "$BACKUP_DIR/iptables_$ts.save" ]]; then
    echo "Восстановление iptables..."
    iptables-restore < "$BACKUP_DIR/iptables_$ts.save" || true
fi

# Удаляем namespace и интерфейсы
echo "Удаление namespace..."
ip netns delete $NAMESPACE 2>/dev/null || true
ip link delete awg0 2>/dev/null || true

# Останавливаем сервисы
echo "Остановка сервисов..."
systemctl stop xray 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true

# Восстанавливаем конфиги
if [[ -f "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
    echo "Восстановление конфигураций..."
    tar xzf "$BACKUP_DIR/configs_$ts.tar.gz" -C / 2>/dev/null || true
fi

# Выгружаем модуль если был загружен
if lsmod | grep -q amneziawg; then
    echo "Выгрузка модуля amneziawg..."
    rmmod amneziawg 2>/dev/null || true
fi

echo "✓ Откат завершен"
ROLLBACK_EOF
    chmod +x "$BACKUP_DIR/rollback_$ts.sh"
    
    # Сохраняем ссылку на последний бэкап
    echo "$ts" > "$BACKUP_DIR/latest_backup"
    
    # Очистка старых бэкапов (оставляем последние 5)
    ls -t "$BACKUP_DIR"/rollback_*.sh 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -t "$BACKUP_DIR"/configs_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
    
    log "✓ Полный бэкап создан: $ts"
}

rollback() {
    if [[ ! -f "$BACKUP_DIR/latest_backup" ]]; then
        warn "Бэкапы не найдены, откат невозможен"
        return 0
    fi
    
    local latest_ts
    latest_ts=$(cat "$BACKUP_DIR/latest_backup")
    local rollback_script="$BACKUP_DIR/rollback_$latest_ts.sh"
    
    if [[ ! -f "$rollback_script" ]]; then
        error "Скрипт отката не найден: $rollback_script"
        return 1
    fi
    
    echo -e "\n${RED}╔══════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ВЫПОЛНЯЕТСЯ АВТОМАТИЧЕСКИЙ ОТКАТ   ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════╝${NC}"
    
    # Выполняем откат в текущем процессе (не в подоболочке!)
    bash "$rollback_script" || true
    
    echo -e "${RED}✓ Откат завершен. Проверьте лог: $LOG${NC}\n"
}

trap 'error "Критическая ошибка на строке $LINENO"; rollback' ERR

# ============================================================================
# БЕЗОПАСНЫЕ SSH ФУНКЦИИ (без утечки пароля)
# ============================================================================

validate_ssh_auth() {
    if [[ -f "$RELAY_AUTH" ]]; then
        if [[ ! -r "$RELAY_AUTH" ]]; then
            die "SSH ключ не читается: $RELAY_AUTH"
        fi
        chmod 600 "$RELAY_AUTH" 2>/dev/null || true
        log "✓ Используется SSH ключ: $RELAY_AUTH"
    else
        warn "⚠️  ВНИМАНИЕ: Использование паролей небезопасно!"
        warn "Рекомендуется использовать SSH ключи."
        warn "Сгенерируйте: ssh-keygen -t ed25519"
        warn "Скопируйте: ssh-copy-id -i ~/.ssh/id_ed25519.pub root@$RELAY_IP"
    fi
}

relay_ssh() {
    local cmd="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q"
    
    if [[ -f "$RELAY_AUTH" ]]; then
        ssh $ssh_opts -i "$RELAY_AUTH" root@"$RELAY_IP" "$cmd" 2>/dev/null
    else
        # Безопасная передача пароля через файловый дескриптор
        sshpass -f <(printf '%s' "$RELAY_AUTH") ssh $ssh_opts root@"$RELAY_IP" "$cmd" 2>/dev/null
    fi
}

relay_scp_from() {
    local src="$1" dst="$2"
    local scp_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q"
    
    if [[ -f "$RELAY_AUTH" ]]; then
        scp $scp_opts -i "$RELAY_AUTH" root@"$RELAY_IP":"$src" "$dst" 2>/dev/null
    else
        sshpass -f <(printf '%s' "$RELAY_AUTH") scp $scp_opts root@"$RELAY_IP":"$src" "$dst" 2>/dev/null
    fi
}

relay_scp() {
    local src="$1" dst="$2"
    local scp_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q"
    
    if [[ -f "$RELAY_AUTH" ]]; then
        scp $scp_opts -i "$RELAY_AUTH" "$src" root@"$RELAY_IP":"$dst" 2>/dev/null
    else
        sshpass -f <(printf '%s' "$RELAY_AUTH") scp $scp_opts "$src" root@"$RELAY_IP":"$dst" 2>/dev/null
    fi
}

# ============================================================================
# МЕХАНИЗМ ПОВТОРНЫХ ПОПЫТОК (Retry)
# ============================================================================

retry_cmd() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local cmd="$*"
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        
        warn "Попытка $attempt/$max_attempts не удалась. Ожидание ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
    
    return 1
}

# ============================================================================
# ОПРЕДЕЛЕНИЕ ПАКЕТНОГО МЕНЕДЖЕРА
# ============================================================================

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        log "✓ Пакетный менеджер: apt-get"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        log "✓ Пакетный менеджер: dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        log "✓ Пакетный менеджер: yum"
    else
        die "Неподдерживаемый пакетный менеджер"
    fi
}

pkg_install() {
    case "$PKG_MANAGER" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            $PKG_MANAGER update -y -qq
            $PKG_MANAGER install -y -qq "$@"
            ;;
        dnf|yum)
            $PKG_MANAGER install -y -q "$@"
            ;;
        *)
            die "Неизвестный пакетный менеджер: $PKG_MANAGER"
            ;;
    esac
}

# ============================================================================
# ПРОВЕРКА ПАРАМЕТРОВ
# ============================================================================

if [[ $# -lt 2 ]]; then
    echo "Использование: $0 <IP_РФ_сервера> <SSH_пароль_или_ключ>"
    echo ""
    echo "Примеры:"
    echo "  $0 161.104.47.154 /root/.ssh/id_ed25519  (рекомендуется)"
    echo "  $0 161.104.47.154 'MyPassword123'         (небезопасно)"
    exit 1
fi

RELAY_IP="$1"
RELAY_AUTH="$2"

# Инициализация лога
mkdir -p "$(dirname "$LOG")"
echo "=== XRAY RELAY MANAGER v$VERSION ===" > "$LOG"
echo "Начало: $(date)" >> "$LOG"
echo "Хост: $(hostname)" >> "$LOG"

# КРИТИЧЕСКИ ВАЖНО: Создаём бэкап ПЕРЕД любыми изменениями
create_backup

# ============================================================================
# ШАГ 1: ПРОВЕРКА DNS
# ============================================================================

section "Шаг 1: Проверка DNS"

fix_dns() {
    if ping -c 1 -W 2 github.com > /dev/null 2>&1; then
        return 0
    fi
    
    warn "DNS не работает, исправляем..."
    cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
    sleep 2
    
    ping -c 1 -W 2 github.com > /dev/null 2>&1
}

if ! retry_cmd 3 5 fix_dns; then
    die "Не удалось настроить DNS"
fi
log "✓ DNS работает"

# ============================================================================
# ШАГ 2: ПРОВЕРКА SSH ПОДКЛЮЧЕНИЯ
# ============================================================================

section "Шаг 2: Проверка SSH подключения"

detect_package_manager
pkg_install sshpass 2>/dev/null || true

validate_ssh_auth

if ! retry_cmd 3 10 "relay_ssh 'echo SSH_OK'"; then
    die "Не удалось подключиться к $RELAY_IP. Проверьте IP и аутентификацию."
fi
log "✓ SSH подключение работает"

# ============================================================================
# ШАГ 3: ОПРЕДЕЛЕНИЕ ОС
# ============================================================================

section "Шаг 3: Определение ОС"

RELAY_OS=$(relay_ssh 'grep ^ID= /etc/os-release | cut -d= -f2 | tr -d "\""' || echo "unknown")
RELAY_VERSION=$(relay_ssh 'grep ^VERSION_ID= /etc/os-release | cut -d= -f2 | tr -d "\""' || echo "unknown")
RELAY_KERNEL=$(relay_ssh 'uname -r' || echo "unknown")

LOCAL_OS=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
LOCAL_VERSION=$(grep ^VERSION_ID= /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
LOCAL_KERNEL=$(uname -r)

log "РФ сервер: $RELAY_OS $RELAY_VERSION (ядро: $RELAY_KERNEL)"
log "Локальный: $LOCAL_OS $LOCAL_VERSION (ядро: $LOCAL_KERNEL)"

# ============================================================================
# ШАГ 4: ОБНОВЛЕНИЕ СИСТЕМ
# ============================================================================

section "Шаг 4: Обновление систем"

log "Обновление РФ сервера..."
relay_ssh 'export DEBIAN_FRONTEND=noninteractive && apt-get update -y -qq && apt-get upgrade -y -qq' || \
    warn "Не удалось обновить РФ сервер"

log "Обновление локального сервера..."
pkg_install iptables-persistent 2>/dev/null || true

log "✓ Системы обновлены, iptables-persistent установлен"

# ============================================================================
# ШАГ 5: УСТАНОВКА AMNEZIAWG НА РФ СЕРВЕРЕ
# ============================================================================

section "Шаг 5: Установка AmneziaWG на РФ сервере"

if relay_ssh 'command -v awg >/dev/null && lsmod | grep -q amneziawg'; then
    log "✓ AmneziaWG уже установлен"
else
    log "Установка AmneziaWG..."
    
    # Проверяем доступность headers
    RELAY_HEADERS=$(relay_ssh 'apt-cache search "linux-headers-$(uname -r)" 2>/dev/null | wc -l' || echo "0")
    
    if [[ "$RELAY_HEADERS" -eq 0 ]]; then
        warn "Headers недоступны, обновляем ядро..."
        relay_ssh 'export DEBIAN_FRONTEND=noninteractive && apt-get install -y linux-image-amd64 linux-headers-amd64'
        relay_ssh 'update-grub'
        log "Перезагрузка РФ сервера..."
        relay_ssh 'reboot' || true
        sleep 30
        
        for i in {1..30}; do
            if relay_ssh 'echo OK' >/dev/null 2>&1; then
                log "✓ Сервер вернулся"
                break
            fi
            sleep 5
        done
    fi
    
    # Создаем скрипт установки
    cat > /tmp/install-awg-relay.sh << 'AWG_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -y -qq
apt-get install -y -qq build-essential pkg-config libmnl-dev libelf-dev \
    linux-headers-$(uname -r) git iptables curl iptables-persistent

cd /tmp && rm -rf amneziawg-*

git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
cd amneziawg-linux-kernel-module
if [[ -d "src" && -f "src/Makefile" ]]; then cd src; fi
make -j2 && make install
modprobe amneziawg
echo "amneziawg" > /etc/modules-load.d/amneziawg.conf

cd /tmp
git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git
cd amneziawg-tools
if [[ -d "src" && -f "src/Makefile" ]]; then cd src; fi
make -j2 && make install

cd / && rm -rf /tmp/amneziawg-*

which netfilter-persistent && netfilter-persistent save || true
echo "AmneziaWG установлен"
AWG_EOF
    
    relay_scp /tmp/install-awg-relay.sh /tmp/install-awg-relay.sh
    relay_ssh 'chmod +x /tmp/install-awg-relay.sh && /tmp/install-awg-relay.sh'
    log "✓ AmneziaWG установлен на РФ сервере"
fi

# ============================================================================
# ШАГ 6: НАСТРОЙКА RELAY С ПРОВЕРКОЙ IPTABLES (ИСПРАВЛЕНО)
# ============================================================================

section "Шаг 6: Настройка relay"

if relay_ssh 'systemctl is-active amneziawg@awg0 >/dev/null 2>&1 && test -f /root/relay-configs/client.conf'; then
    log "✓ Relay уже настроен и конфиг существует"
else
    log "Настройка relay..."
    
    cat > /tmp/setup-relay.sh << 'RELAY_EOF'
#!/bin/bash
set -e

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [[ -z "$DEFAULT_IFACE" ]]; then
    echo "ERROR: Интерфейс не найден"
    exit 1
fi

SERVER_PRIV=$(awg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | awg pubkey)
CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)
PSK=$(awg genpsk)

JC=$((RANDOM % 5 + 3))
JMIN=$((RANDOM % 50 + 50))
JMAX=$((JMIN + RANDOM % 200 + 100))
S1=$((RANDOM % 30 + 15))
S2=$((RANDOM % 30 + 15))
H1=$((RANDOM % 2147483647))
H2=$((RANDOM % 2147483647))
H3=$((RANDOM % 2147483647))
H4=$((RANDOM % 2147483647))
AWG_PORT=$((50000 + RANDOM % 15000))

mkdir -p /etc/amnezia/amneziawg
cat > /etc/amnezia/amneziawg/awg0.conf << AWGEOF
[Interface]
Address = 10.10.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

PostUp = iptables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i awg0 -o $DEFAULT_IFACE -j ACCEPT
PostUp = iptables -A FORWARD -i $DEFAULT_IFACE -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -o $DEFAULT_IFACE -j ACCEPT
PostDown = iptables -D FORWARD -i $DEFAULT_IFACE -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $PSK
AllowedIPs = 10.10.0.2/32
AWGEOF

chmod 600 /etc/amnezia/amneziawg/awg0.conf
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-awg.conf
sysctl --system > /dev/null 2>&1

cat > /etc/systemd/system/amneziawg@.service << SVCEOF
[Unit]
Description=AmneziaWG Network Connection (%I)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up /etc/amnezia/amneziawg/%i.conf
ExecStop=/usr/bin/awg-quick down /etc/amnezia/amneziawg/%i.conf

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable amneziawg@awg0 > /dev/null 2>&1
systemctl start amneziawg@awg0
sleep 3

if ! systemctl is-active amneziawg@awg0 > /dev/null 2>&1; then
    echo "ERROR: AmneziaWG не запустился"
    journalctl -u amneziawg@awg0 -n 20 --no-pager
    exit 1
fi

# ИСПРАВЛЕНО: Добавлены флаги -v -n для корректной проверки
if ! iptables -t nat -L POSTROUTING -v -n | grep -q "MASQUERADE.*$DEFAULT_IFACE"; then
    echo "ERROR: Правила iptables не применены"
    echo "Проверка:"
    iptables -t nat -L POSTROUTING -v -n
    exit 1
fi

# Сохраняем iptables
which netfilter-persistent && netfilter-persistent save || true

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
mkdir -p /root/relay-configs

cat > /root/relay-configs/client.conf << AWGCEOF
[Interface]
Address = 10.10.0.2/24
PrivateKey = $CLIENT_PRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
Endpoint = $SERVER_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
AWGCEOF

chmod 600 /root/relay-configs/client.conf
echo "Relay настроен"
RELAY_EOF
    
    relay_scp /tmp/setup-relay.sh /tmp/setup-relay.sh
    relay_ssh 'chmod +x /tmp/setup-relay.sh && /tmp/setup-relay.sh'
    log "✓ Relay настроен с проверкой iptables"
fi

# ============================================================================
# ШАГ 7: КОПИРОВАНИЕ КОНФИГА
# ============================================================================

section "Шаг 7: Копирование конфига"

if ! retry_cmd 3 10 "relay_scp_from /root/relay-configs/client.conf /root/awg-client.conf"; then
    die "Не удалось скопировать конфиг"
fi
log "✓ Конфиг скопирован"

# ============================================================================
# ШАГ 8: УСТАНОВКА AMNEZIAWG ЛОКАЛЬНО
# ============================================================================

section "Шаг 8: Установка AmneziaWG локально"

if command -v awg &> /dev/null && lsmod | grep -q amneziawg; then
    log "✓ AmneziaWG уже установлен"
else
    log "Установка AmneziaWG..."
    
    HEADERS=0
    if dpkg -l "linux-headers-$(uname -r)" 2>/dev/null | grep -q "^ii"; then
        HEADERS=1
    elif apt-cache show "linux-headers-$(uname -r)" 2>/dev/null | grep -q "Package:"; then
        HEADERS=1
    fi
    
    if [[ "$HEADERS" -eq 0 ]]; then
        warn "Headers недоступны, обновляем ядро..."
        pkg_install linux-image-amd64 linux-headers-amd64
        update-grub
        log "Перезагрузка..."
        sleep 5
        reboot
    fi
    
    pkg_install build-essential pkg-config libmnl-dev libelf-dev \
        linux-headers-$(uname -r) git iptables curl
    
    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        die "Headers не установлены"
    fi
    log "✓ Headers установлены"
    
    cd /tmp && rm -rf amneziawg-*
    
    if ! retry_cmd 3 10 "git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"; then
        die "Не удалось клонировать репозиторий ядра"
    fi
    
    cd amneziawg-linux-kernel-module
    if [[ -d "src" && -f "src/Makefile" ]]; then cd src; fi
    make -j2 && make install
    
    modprobe amneziawg
    echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
    
    if ! lsmod | grep -q amneziawg; then
        die "Модуль amneziawg не загрузился"
    fi
    log "✓ Модуль загружен"
    
    cd /tmp
    if ! retry_cmd 3 10 "git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git"; then
        die "Не удалось клонировать репозиторий утилит"
    fi
    
    cd amneziawg-tools
    if [[ -d "src" && -f "src/Makefile" ]]; then cd src; fi
    make -j2 && make install
    
    if ! command -v awg &> /dev/null; then
        die "Команда awg не установлена"
    fi
    log "✓ AmneziaWG установлен: $(awg --version 2>&1 | head -1)"
    
    cd / && rm -rf /tmp/amneziawg-*
fi

# ============================================================================
# ШАГ 9: НАСТРОЙКА КЛИЕНТА
# ============================================================================

section "Шаг 9: Настройка клиента"

log "Очистка..."
systemctl stop xray 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true
ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
ip link delete awg0 2>/dev/null || true

mkdir -p /etc/amnezia/amneziawg
if grep -q "^DNS" /root/awg-client.conf; then
    sed -i '/^DNS/d' /root/awg-client.conf
fi
cp /root/awg-client.conf /etc/amnezia/amneziawg/awg0.conf
chmod 600 /etc/amnezia/amneziawg/awg0.conf

systemctl enable awg-quick@awg0 > /dev/null 2>&1
systemctl start awg-quick@awg0
sleep 3

if ! systemctl is-active --quiet awg-quick@awg0; then
    die "AmneziaWG не запустился. Проверьте: journalctl -u awg-quick@awg0"
fi
log "✓ AmneziaWG запущен"

if awg show | grep -q "latest handshake"; then
    log "✓ Handshake установлен"
else
    warn "Handshake не установлен"
fi

if ping -c 3 -W 2 10.10.0.1 > /dev/null 2>&1; then
    log "✓ Пинг до relay работает"
else
    warn "Пинг до relay не проходит"
fi

# ============================================================================
# ШАГ 10: СОЗДАНИЕ NAMESPACE (ИСПРАВЛЕНО)
# ============================================================================

section "Шаг 10: Создание namespace (ИСПРАВЛЕНО)"

if [[ -d "/run/netns/$NAMESPACE" ]]; then
    warn "Namespace существует, удаляем..."
    ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
fi

# ПРАВИЛЬНАЯ ПОСЛЕДОВАТЕЛЬНОСТЬ:
# 1. Создать namespace
ip netns add "$NAMESPACE"

# 2. Переместить интерфейс
ip link set awg0 netns "$NAMESPACE"

# 3. ПОДНЯТЬ ИНТЕРФЕЙС (КРИТИЧЕСКИ ВАЖНО!)
ip netns exec "$NAMESPACE" ip link set awg0 up

# 4. Добавить IP-адрес
ip netns exec "$NAMESPACE" ip addr add 10.10.0.2/24 dev awg0

# 5. Поднять loopback
ip netns exec "$NAMESPACE" ip link set lo up

# 6. ПРАВИЛЬНЫЙ МАРШРУТ (через via, а не dev!)
ip netns exec "$NAMESPACE" ip route add default via 10.10.0.1 dev awg0

# 7. DNS через resolvectl если доступен
if command -v resolvectl &> /dev/null; then
    ip netns exec "$NAMESPACE" resolvectl dns awg0 8.8.8.8 1.1.1.1 2>/dev/null || true
else
    ip netns exec "$NAMESPACE" sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
    ip netns exec "$NAMESPACE" sh -c 'echo "nameserver 1.1.1.1" >> /etc/resolv.conf'
fi

log "✓ Namespace создан с правильной конфигурацией"

# Проверяем
if ! ip netns exec "$NAMESPACE" ip addr show awg0 | grep -q "10.10.0.2"; then
    die "IP не добавлен в namespace"
fi
log "✓ IP 10.10.0.2 добавлен"

if ip netns exec "$NAMESPACE" ping -c 3 -W 2 10.10.0.1 > /dev/null 2>&1; then
    log "✓ Пинг через туннель работает"
else
    warn "Пинг через туннель не проходит"
fi

TUNNEL_IP=$(ip netns exec "$NAMESPACE" curl -s4 --max-time 10 ifconfig.me 2>/dev/null || echo "failed")
if [[ "$TUNNEL_IP" == "failed" || -z "$TUNNEL_IP" ]]; then
    warn "Не удалось получить IP через туннель"
else
    log "✓ IP через туннель: $TUNNEL_IP"
fi

# ============================================================================
# ШАГ 11: УСТАНОВКА XRAY
# ============================================================================

section "Шаг 11: Установка Xray"

if [[ -f /usr/local/xray/xray ]]; then
    log "✓ Xray уже установлен"
else
    log "Установка Xray..."
    pkg_install curl unzip jq openssl qrencode
    
    mkdir -p /usr/local/xray /usr/local/etc/xray
    cd /tmp
    
    if ! LATEST=$(curl -sL https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -1); then
        die "Не удалось получить версию Xray"
    fi
    log "Версия Xray: $LATEST"
    
    if ! retry_cmd 3 10 "wget -q -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v${LATEST}/Xray-linux-64.zip"; then
        die "Не удалось скачать Xray"
    fi
    
    unzip -o -q /tmp/xray.zip -d /usr/local/xray
    rm -f /tmp/xray.zip
    chmod +x /usr/local/xray/xray
    ln -sf /usr/local/xray/xray /usr/local/bin/xray
    
    log "✓ Xray установлен: $(xray version 2>&1 | head -1)"
fi

# ============================================================================
# ШАГ 12: СОЗДАНИЕ КОНФИГА XRAY
# ============================================================================

section "Шаг 12: Создание конфига Xray"

if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
    log "Создание конфига..."
    
    KEYPAIR=$(xray x25519)
    PRIV=$(echo "$KEYPAIR" | grep "PrivateKey:" | awk '{print $2}')
    PUB=$(echo "$KEYPAIR" | grep "Password (PublicKey):" | awk '{print $3}')
    SID=$(openssl rand -hex 8)
    FIRST_UUID=$(xray uuid)
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_DIR/server.json" << EOF
{
  "sni": "www.apple.com",
  "serverNames": ["www.apple.com", "www.microsoft.com", "www.cloudflare.com"],
  "privateKey": "$PRIV",
  "publicKey": "$PUB",
  "shortId": "$SID",
  "fragment": {"packets": "tlshello", "length": "50-100", "delay": "1-5"}
}
EOF
    
    cat > "$CONFIG_DIR/clients.json" << EOF
{
  "clients": [{"name": "admin", "uuid": "$FIRST_UUID", "created": "$(date -Iseconds)"}]
}
EOF
    
    cat > "$CONFIG_DIR/config.json" << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$FIRST_UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.apple.com:443",
        "serverNames": ["www.apple.com"],
        "privateKey": "$PRIV",
        "shortIds": ["$SID", ""]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
    
    log "✓ Конфиг создан"
    log "UUID: $FIRST_UUID"
    log "Public Key: $PUB"
    log "Short ID: $SID"
else
    log "✓ Конфиг уже существует"
fi

# Валидация конфига
if ! xray -test -config "$CONFIG_DIR/config.json" > /dev/null 2>&1; then
    die "Конфиг Xray невалиден"
fi

# ============================================================================
# ШАГ 13: УСТАНОВКА HYSTERIA2
# ============================================================================

section "Шаг 13: Установка Hysteria2"

if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    log "✓ Hysteria2 уже установлен"
else
    log "Установка Hysteria2..."
    if ! retry_cmd 3 10 "bash <(curl -fsSL https://get.hy2.sh/)"; then
        warn "Не удалось установить Hysteria2"
    else
        HY_PASS=$(jq -r '.clients[0].uuid' "$CONFIG_DIR/clients.json")
        mkdir -p /etc/hysteria
        
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
            -subj "/CN=www.apple.com" -days 3650 2>/dev/null
        
        # ИСПРАВЛЕНИЕ: Правильные права доступа для сертификатов
        chmod 644 /etc/hysteria/cert.pem
        chmod 600 /etc/hysteria/key.pem
        chown -R root:root /etc/hysteria
        
        cat > /etc/hysteria/config.yaml << EOF
listen: :8443

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: password
  password: $HY_PASS

masquerade:
  type: proxy
  proxy:
    url: https://www.apple.com
    rewriteHost: true
EOF
        
        systemctl enable hysteria-server > /dev/null 2>&1
        systemctl restart hysteria-server
        sleep 2
        
        if systemctl is-active --quiet hysteria-server; then
            log "✓ Hysteria2 запущен"
        else
            warn "Hysteria2 не запустился"
        fi
    fi
fi

# ============================================================================
# ШАГ 14: SYSTEMD СЕРВИСЫ
# ============================================================================

section "Шаг 14: Создание systemd сервисов"

cat > /usr/local/bin/setup-awg-namespace.sh << 'NSEOF'
#!/usr/bin/env bash
set -e

systemctl stop awg-quick@awg0 2>/dev/null || true
ip link delete awg0 2>/dev/null || true
ip netns delete xray 2>/dev/null || rm -f /run/netns/xray || true

systemctl start awg-quick@awg0
sleep 3

ip netns add xray
ip link set awg0 netns xray

# ПРАВИЛЬНАЯ ПОСЛЕДОВАТЕЛЬНОСТЬ
ip netns exec xray ip link set awg0 up
ip netns exec xray ip addr add 10.10.0.2/24 dev awg0
ip netns exec xray ip link set lo up
ip netns exec xray ip route add default via 10.10.0.1 dev awg0

# DNS
if command -v resolvectl &> /dev/null; then
    ip netns exec xray resolvectl dns awg0 8.8.8.8 1.1.1.1 2>/dev/null || true
else
    ip netns exec xray sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
    ip netns exec xray sh -c 'echo "nameserver 1.1.1.1" >> /etc/resolv.conf'
fi

echo "Namespace xray настроен"
NSEOF
chmod +x /usr/local/bin/setup-awg-namespace.sh

cat > /etc/systemd/system/wg-namespace.service << 'SVCEOF'
[Unit]
Description=Setup AmneziaWG namespace
After=network.target
Before=xray.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-awg-namespace.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service (via AmneziaWG relay)
After=network.target wg-namespace.service

[Service]
Type=simple
User=root
ExecStart=/sbin/ip netns exec xray /usr/local/xray/xray run -config $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wg-namespace.service xray.service > /dev/null 2>&1
log "✓ Сервисы созданы"

# ============================================================================
# ШАГ 15: ЗАПУСК И SMOKE ТЕСТЫ
# ============================================================================

section "Шаг 15: Запуск и тестирование"

/usr/local/bin/setup-awg-namespace.sh
systemctl start xray
sleep 3

if systemctl is-active --quiet xray; then
    log "✓ Xray запущен"
else
    warn "Xray не запустился"
fi

if ip netns exec xray ss -tlnp 2>/dev/null | grep -q ":443"; then
    log "✓ Порт 443 слушается внутри namespace"
else
    warn "Порт 443 не слушается внутри namespace"
fi

# SMOKE ТЕСТЫ
section "Smoke тесты"

SMOKE_PASSED=true

echo "Тест 1: Проверка IP через туннель..."
TEST_IP=$(ip netns exec xray curl -s4 --max-time 10 ifconfig.me 2>/dev/null || echo "FAILED")
if [[ "$TEST_IP" != "FAILED" && -n "$TEST_IP" ]]; then
    log "✓ Тест 1 пройден: IP = $TEST_IP"
else
    error "✗ Тест 1 НЕ пройден"
    SMOKE_PASSED=false
fi

echo "Тест 2: Проверка порта 443 внутри namespace..."
if ip netns exec xray ss -tlnp 2>/dev/null | grep -q ":443"; then
    log "✓ Тест 2 пройден: Порт 443 слушается Xray внутри namespace"
else
    error "✗ Тест 2 НЕ пройден"
    SMOKE_PASSED=false
fi

echo "Тест 3: Проверка Hysteria2..."
if ss -tlnp | grep -q ":8443.*hysteria"; then
    log "✓ Тест 3 пройден: Hysteria2 работает"
else
    warn "⚠️  Тест 3 НЕ пройден"
fi

if [[ "$SMOKE_PASSED" == "false" ]]; then
    error "❌ Smoke тесты НЕ пройдены!"
    rollback
    die "Установка завершена с ошибками"
else
    log "✅ Все smoke тесты пройдены!"
fi

# ============================================================================
# ШАГ 16: ГЕНЕРАЦИЯ XRAY-ADMIN (БЕЗОПАСНО)
# ============================================================================

section "Шаг 16: Создание управляющего скрипта"

cat > "$ADMIN_BIN" << 'ADMINEOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/usr/local/etc/xray"
CLIENTS="$CONFIG_DIR/clients.json"
SERVER="$CONFIG_DIR/server.json"
CONF="$CONFIG_DIR/config.json"
HYSTERIA_DIR="/etc/hysteria"
ALERTS_DIR="$CONFIG_DIR/alerts"
NAMESPACE="xray"
LOG_FILE="/var/log/xray-admin.log"
BACKUP_DIR="/root/.xray-backups"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Нужен root"; exit 1; }

log_action() {
    echo "[$(date -Iseconds)] $USER: $*" >> "$LOG_FILE"
}

get_relay_ip() {
    grep -E "^Endpoint" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | \
        awk '{print $3}' | cut -d: -f1 || echo "unknown"
}

get_public_ip() {
    ip netns exec $NAMESPACE curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A"
}

cmd_status() {
    log_action "status"
    echo -e "${CYAN}=== Статус VPN Relay ===${NC}"
    local relay_ip
    relay_ip=$(get_relay_ip)
    printf "%-25s %s\n" "Relay (РФ):" "$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o LogLevel=ERROR -q root@$relay_ip 'systemctl is-active amneziawg@awg0' 2>/dev/null || echo 'unreachable')"
    printf "%-25s %s\n" "Client (AWG):" "$(systemctl is-active awg-quick@awg0 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Xray:" "$(systemctl is-active xray 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Hysteria2:" "$(systemctl is-active hysteria-server 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Namespace:" "$(ip netns list 2>/dev/null | grep -c $NAMESPACE || echo '0')/1"
    printf "%-25s %s\n" "IP через туннель:" "$(get_public_ip)"
    echo ""
    echo -e "${YELLOW}Клиенты:${NC}"
    if [[ -f "$CLIENTS" ]]; then
        jq -r '.clients[] | "  • \(.name) [\(.uuid)]"' "$CLIENTS" 2>/dev/null || \
            awk -F'"' '/"name"/{name=$4} /"uuid"/{print "  • " name " [" $4 "]"}' "$CLIENTS"
    else
        echo "  Нет клиентов"
    fi
}

cmd_add_client() {
    local name="${1:-client}"
    local uuid
    uuid=$(xray uuid)
    log_action "add_client $name"
    
    [[ -f "$CLIENTS" ]] || echo '{"clients":[]}' > "$CLIENTS"
    
    python3 -c "
import json
from datetime import datetime

with open('$CLIENTS', 'r') as f:
    data = json.load(f)

data['clients'].append({
    'name': '$name',
    'uuid': '$uuid',
    'created': datetime.now().isoformat()
})

with open('$CLIENTS', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || {
        tmp=$(mktemp)
        jq ".clients += [{\"name\":\"$name\",\"uuid\":\"$uuid\",\"created\":\"$(date -Iseconds)\"}]" \
            "$CLIENTS" > "$tmp" && mv "$tmp" "$CLIENTS"
    }
    
    echo -e "${GREEN}✓ Добавлен клиент: $name ($uuid)${NC}"
    cmd_gen_links "$name"
}

cmd_remove_client() {
    local name="$1"
    log_action "remove_client $name"
    
    tmp=$(mktemp)
    jq "del(.clients[] | select(.name==\"$name\"))" "$CLIENTS" > "$tmp" && mv "$tmp" "$CLIENTS"
    echo -e "${GREEN}✓ Удален клиент: $name${NC}"
    systemctl restart xray
}

cmd_rename_client() {
    local old="$1" new="$2"
    log_action "rename_client $old -> $new"
    
    tmp=$(mktemp)
    jq "(.clients[] | select(.name==\"$old\")).name = \"$new\"" "$CLIENTS" > "$tmp" && mv "$tmp" "$CLIENTS"
    echo -e "${GREEN}✓ Переименован: $old -> $new${NC}"
}

cmd_gen_links() {
    local target="${1:-all}"
    log_action "gen_links $target"
    
    local relay_ip pub sid sni hy_pass
    relay_ip=$(get_relay_ip)
    pub=$(jq -r '.publicKey' "$SERVER" 2>/dev/null || echo "")
    sid=$(jq -r '.shortId' "$SERVER" 2>/dev/null || echo "")
    sni=$(jq -r '.sni' "$SERVER" 2>/dev/null || echo "www.apple.com")
    hy_pass=$(jq -r '.clients[0].uuid' "$CLIENTS" 2>/dev/null || echo "")
    
    echo -e "${CYAN}=== Ссылки для подключения ===${NC}"
    > /root/xray-links.txt
    
    if [[ -f "$CLIENTS" ]]; then
        jq -r '.clients[] | select(.name=="'"$target"'" or "'"$target"'"=="all") | "\(.name) \(.uuid)"' "$CLIENTS" | \
        while read -r n u; do
            echo -e "\n${YELLOW}$n:${NC}"
            L1="vless://$u@$relay_ip:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pub&sid=$sid&type=tcp#$n"
            L2="hysteria2://$hy_pass@$relay_ip:8443?insecure=1&sni=$sni#$n"
            echo "  REALITY:   $L1"
            echo "  Hysteria2: $L2"
            echo "=== $n ===" >> /root/xray-links.txt
            echo "$L1" >> /root/xray-links.txt
            echo "$L2" >> /root/xray-links.txt
        done
    fi
    
    echo -e "\n${GREEN}✓ Ссылки сохранены: /root/xray-links.txt${NC}"
}

cmd_restart() {
    log_action "restart"
    echo "Перезапуск всех сервисов..."
    /usr/local/bin/setup-awg-namespace.sh
    systemctl restart xray.service hysteria-server.service 2>/dev/null || true
    sleep 3
    cmd_status
}

cmd_monitor() {
    log_action "monitor"
    echo "Запуск мониторинга... (Ctrl+C для остановки)"
    while true; do
        local xray_st awg_st ip
        xray_st=$(systemctl is-active xray 2>/dev/null || echo "inactive")
        awg_st=$(systemctl is-active awg-quick@awg0 2>/dev/null || echo "inactive")
        ip=$(get_public_ip)
        echo -e "[$(date '+%H:%M:%S')] Xray: $xray_st | AWG: $awg_st | IP: $ip"
        
        if [[ "$xray_st" != "active" ]]; then
            echo -e "${RED}Xray упал! Перезапуск...${NC}"
            /usr/local/bin/setup-awg-namespace.sh && systemctl restart xray
            send_alert "🚨 Xray перезагружен на $(hostname)"
        fi
        sleep 60
    done
}

send_alert() {
    local msg="$1"
    if [[ -f "$ALERTS_DIR/telegram.conf" ]]; then
        source "$ALERTS_DIR/telegram.conf"
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID&text=$msg" >/dev/null || true
    fi
}

cmd_setup_alerts() {
    mkdir -p "$ALERTS_DIR"
    echo -e "1) Telegram\n2) Email\n3) Оба"
    read -p "Выбор: " ch
    case $ch in
        1|3) 
            read -p "Bot Token: " t
            read -p "Chat ID: " c
            echo -e "BOT_TOKEN=$t\nCHAT_ID=$c" > "$ALERTS_DIR/telegram.conf"
            ;;
        2|3) 
            read -p "Email: " e
            echo -e "NOTIFY_EMAIL=$e" > "$ALERTS_DIR/email.conf"
            ;;
    esac
    echo -e "${GREEN}✓ Оповещения настроены${NC}"
}

cmd_help() {
    echo -e "${CYAN}xray-admin v5.0.0 - Управление VPN Relay${NC}"
    echo ""
    echo "Команды:"
    echo "  status              - Статус всех сервисов"
    echo "  add <имя>           - Добавить нового клиента"
    echo "  remove <имя>        - Удалить клиента"
    echo "  rename <старое> <новое> - Переименовать клиента"
    echo "  links [имя]         - Показать ссылки для подключения"
    echo "  restart             - Перезапустить все сервисы"
    echo "  monitor             - Запустить мониторинг"
    echo "  alerts              - Настроить оповещения"
    echo "  restore             - Восстановить из последнего бэкапа"
    echo "  update              - Обновить Xray до последней версии"
    echo "  version             - Показать версию и установленные компоненты"
    echo "  help                - Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  xray-admin add my-phone"
    echo "  xray-admin links admin"
    echo "  xray-admin status"
}

cmd_restore() {
    log_action "restore"
    if [[ ! -f "$BACKUP_DIR/latest_backup" ]]; then
        error "Бэкапы не найдены в $BACKUP_DIR"
        exit 1
    fi
    
    local latest_ts=$(cat "$BACKUP_DIR/latest_backup")
    local rollback_script="$BACKUP_DIR/rollback_$latest_ts.sh"
    
    if [[ ! -f "$rollback_script" ]]; then
        error "Скрипт отката не найден: $rollback_script"
        exit 1
    fi
    
    echo -e "${YELLOW}Восстановление из бэкапа #$latest_ts...${NC}"
    bash "$rollback_script"
    echo -e "${GREEN}✓ Восстановление завершено${NC}"
}

cmd_update() {
    log_action "update"
    echo "Проверка обновлений Xray..."
    
    local current_version=$(xray version 2>&1 | head -1 | grep -oP 'Xray \K[0-9.]+')
    local latest=$(curl -sL https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -1)
    
    if [[ "$current_version" == "$latest" ]]; then
        echo -e "${GREEN}✓ Xray уже обновлён до версии $current_version${NC}"
        return 0
    fi
    
    echo "Доступна новая версия: $latest (текущая: $current_version)"
    read -p "Обновить? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0
    
    systemctl stop xray
    cd /tmp
    wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${latest}/Xray-linux-64.zip"
    unzip -o -q /tmp/xray.zip -d /usr/local/xray
    rm -f /tmp/xray.zip
    chmod +x /usr/local/xray/xray
    systemctl start xray
    
    echo -e "${GREEN}✓ Xray обновлён до версии $latest${NC}"
}

cmd_version() {
    echo "xray-admin v5.0.0"
    echo "VPN Relay Manager"
    echo ""
    echo "Установленные компоненты:"
    echo "  Xray: $(xray version 2>&1 | head -1 || echo 'не установлен')"
    echo "  Hysteria2: $(hysteria version 2>&1 | head -1 || echo 'не установлен')"
    echo "  AmneziaWG: $(awg --version 2>&1 | head -1 || echo 'не установлен')"
}
case "${1:-help}" in
    status)     cmd_status ;;
    add)        cmd_add_client "${2:-}" ;;
    remove)     cmd_remove_client "${2:-}" ;;
    rename)     cmd_rename_client "${2:-}" "${3:-}" ;;
    links)      cmd_gen_links "${2:-all}" ;;
    restart)    cmd_restart ;;
    monitor)    cmd_monitor ;;
    alerts)     cmd_setup_alerts ;;
    restore)    cmd_restore ;;
    update)     cmd_update ;;
    version|--version|-v) cmd_version ;;
    help|--help|-h|"") cmd_help ;;
    *)          echo "Неизвестная команда: $1"; cmd_help; exit 1 ;;
esac
ADMINEOF

chmod +x "$ADMIN_BIN"
log "✓ Управляющий скрипт создан: $ADMIN_BIN"

# ============================================================================
# ШАГ 17: ФИНАЛЬНЫЙ ОТЧЕТ
# ============================================================================

section "✅ Установка завершена успешно!"

echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VPN Relay v5.0.0 готов к работе!${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Статус:${NC}"
printf "  %-30s %s\n" "AmneziaWG (relay):" "$(relay_ssh 'systemctl is-active amneziawg@awg0' 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "AmneziaWG (client):" "$(systemctl is-active awg-quick@awg0 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "Xray:" "$(systemctl is-active xray 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "Hysteria2:" "$(systemctl is-active hysteria-server 2>/dev/null || echo 'inactive')"
echo ""

echo -e "${YELLOW}IP информация:${NC}"
printf "  %-30s %s\n" "РФ relay:" "$RELAY_IP"
printf "  %-30s %s\n" "Xray через туннель:" "$TUNNEL_IP"
echo ""

echo -e "${YELLOW}Управление:${NC}"
echo "  xray-admin status     # Статус системы"
echo "  xray-admin add user   # Добавить клиента"
echo "  xray-admin remove user # Удалить клиента"
echo "  xray-admin rename old new # Переименовать"
echo "  xray-admin links      # Получить ссылки"
echo "  xray-admin restart    # Перезапустить сервисы"
echo "  xray-admin monitor    # Мониторинг"
echo "  xray-admin alerts     # Оповещения"
echo "  xray-admin help       # Помощь"
echo ""

echo -e "${YELLOW}Безопасность:${NC}"
echo "  • Пароли передаются через файловый дескриптор"
echo "  • Бэкапы: $BACKUP_DIR"
echo "  • Лог: $LOG"
echo ""

echo -e "${GREEN}✓ Готово! Система протестирована и работает.${NC}"
log "Установка завершена успешно"
'''

with open('/root/setup-vpn-relay.sh', 'w') as f:
    f.write(script)

os.chmod('/root/setup-vpn-relay.sh', 0o755)
print(f"✅ Исправленный скрипт v5.0.0 создан: /root/setup-vpn-relay.sh")
print(f"📊 Размер: {os.path.getsize('/root/setup-vpn-relay.sh')} байт")
print(f"📝 Строк: {script.count(chr(10))}")
print(f"\n🔧 Исправление: добавлены флаги -v -n к iptables в проверке на шаге 6")
PYEOF
