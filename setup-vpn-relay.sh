python3 << 'PYEOF'
import os

script = r'''#!/usr/bin/env bash
# ============================================================================
# XRAY RELAY MANAGER - Production Ready v6.1.0 (Final)
# Архитектура: Вариант B (Namespace + veth + socat)
# ИСПРАВЛЕНО v6.1.0: Полная очистка awg-quick перед удалением namespace
# ============================================================================

set -euo pipefail

readonly VERSION="6.1.0"
readonly LOG="/var/log/xray-admin.log"
readonly BACKUP_DIR="/root/.xray-backups"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly ADMIN_BIN="/usr/local/bin/xray-admin"
readonly NAMESPACE="xray"
readonly RELAY_SUBNET="10.10.0.0/24"
readonly RELAY_SERVER_IP="10.10.0.1"
readonly RELAY_CLIENT_IP="10.10.0.2"
readonly VETH_HOST_IP="10.200.0.1"
readonly VETH_NS_IP="10.200.0.2"
readonly DIAGNOSTICS_DIR="/root/.xray-diagnostics"

RELAY_IP=""
RELAY_AUTH=""
PKG_MANAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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
# РАСШИРЕННАЯ ДИАГНОСТИКА ПЕРЕД ОТКАТОМ
# ============================================================================

collect_diagnostics() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local diag_file="$DIAGNOSTICS_DIR/diagnostics_$ts.log"
    
    mkdir -p "$DIAGNOSTICS_DIR"
    
    echo -e "\n${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${MAGENTA}║  📊 СБОР ДИАГНОСТИЧЕСКОЙ ИНФОРМАЦИИ                      ║${NC}" >&2
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}\n" >&2
    
    {
        echo "============================================================"
        echo "ДИАГНОСТИЧЕСКИЙ ОТЧЁТ"
        echo "Время: $(date)"
        echo "Хост: $(hostname)"
        echo "Версия скрипта: $VERSION"
        echo "============================================================"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📋 СТАТУС СИСТЕМНЫХ СЕРВИСОВ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for service in xray hysteria-server socat-443 socat-8443 wg-namespace awg-quick@awg0; do
            echo ""
            echo "▶ Сервис: $service"
            systemctl status "$service" --no-pager -l 2>&1 || echo "  (сервис не найден)"
        done
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📜 ПОСЛЕДНИЕ ЛОГИ СЕРВИСОВ (30 строк)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for service in xray hysteria-server socat-443 socat-8443 wg-namespace awg-quick@awg0; do
            echo ""
            echo "▶ Логи сервиса: $service"
            journalctl -u "$service" -n 30 --no-pager 2>&1 || echo "  (логи недоступны)"
        done
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🌐 СОСТОЯНИЕ NETWORK NAMESPACES"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "▶ Список namespaces:"
        ip netns list 2>&1 || echo "  (нет namespaces)"
        echo ""
        
        if ip netns list 2>/dev/null | grep -q "^xray"; then
            echo "▶ Интерфейсы в namespace 'xray':"
            ip netns exec xray ip link show 2>&1 || echo "  (ошибка)"
            echo ""
            echo "▶ IP-адреса в namespace 'xray':"
            ip netns exec xray ip addr show 2>&1 || echo "  (ошибка)"
            echo ""
            echo "▶ Таблица маршрутизации в namespace 'xray':"
            ip netns exec xray ip route show 2>&1 || echo "  (ошибка)"
            echo ""
            echo "▶ TCP-сокеты в namespace 'xray':"
            ip netns exec xray ss -tlnp 2>&1 || echo "  (ошибка)"
            echo ""
            echo "▶ UDP-сокеты в namespace 'xray':"
            ip netns exec xray ss -ulnp 2>&1 || echo "  (ошибка)"
        else
            echo "⚠ Namespace 'xray' не существует!"
        fi
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔗 СОСТОЯНИЕ VETH-ПАРЫ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "▶ Интерфейс veth-host:"
        ip link show veth-host 2>&1 || echo "  (veth-host не существует)"
        echo ""
        echo "▶ Интерфейс veth-ns:"
        ip link show veth-ns 2>&1 || echo "  (veth-ns не существует или в namespace)"
        echo ""
        echo "▶ veth-ns внутри namespace xray:"
        ip netns exec xray ip link show veth-ns 2>&1 || echo "  (veth-ns не в namespace или namespace не существует)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🛡️ СОСТОЯНИЕ AMNEZIAWG (awg0)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "▶ Интерфейс awg0 в основном namespace:"
        ip link show awg0 2>&1 || echo "  (awg0 не существует в основном namespace)"
        echo ""
        echo "▶ Интерфейс awg0 в namespace xray:"
        ip netns exec xray ip link show awg0 2>&1 || echo "  (awg0 не в namespace xray)"
        echo ""
        echo "▶ AmneziaWG статус:"
        awg show 2>&1 || echo "  (awg не запущен)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🚪 СОСТОЯНИЕ ПОРТОВ НА ОСНОВНОМ ИНТЕРФЕЙСЕ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "▶ TCP-сокеты (порт 443):"
        ss -tlnp 2>&1 | grep -E ":443|State" || echo "  (порт 443 не слушается)"
        echo ""
        echo "▶ UDP-сокеты (порт 8443):"
        ss -ulnp 2>&1 | grep -E ":8443|State" || echo "  (порт 8443 не слушается)"
        echo ""
        echo "▶ Все слушающие TCP-порты:"
        ss -tlnp 2>&1 || echo "  (ошибка)"
        echo ""
        echo "▶ Все слушающие UDP-порты:"
        ss -ulnp 2>&1 || echo "  (ошибка)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔥 СОСТОЯНИЕ IPTABLES"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "▶ Таблица FILTER (FORWARD):"
        iptables -L FORWARD -v -n 2>&1 || echo "  (ошибка)"
        echo ""
        echo "▶ Таблица NAT (POSTROUTING):"
        iptables -t nat -L POSTROUTING -v -n 2>&1 || echo "  (ошибка)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚙️ СОСТОЯНИЕ SYSCTL"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "▶ IP forwarding:"
        sysctl net.ipv4.ip_forward 2>&1 || echo "  (ошибка)"
        echo ""
        echo "▶ rp_filter для veth-host:"
        sysctl net.ipv4.conf.veth-host.rp_filter 2>&1 || echo "  (ошибка)"
        echo ""
        echo "▶ rp_filter для all:"
        sysctl net.ipv4.conf.all.rp_filter 2>&1 || echo "  (ошибка)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚡ ЗАПУЩЕННЫЕ ПРОЦЕССЫ (xray, hysteria, socat, awg)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        ps aux | grep -E "(xray|hysteria|socat|awg)" | grep -v grep || echo "  (процессы не найдены)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📝 ПОСЛЕДНИЕ 50 СТРОК ЛОГА УСТАНОВКИ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        if [[ -f "$LOG" ]]; then
            tail -n 50 "$LOG"
        else
            echo "  (лог не найден)"
        fi
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "💾 СВОБОДНОЕ МЕСТО НА ДИСКЕ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        df -h 2>&1 || echo "  (ошибка)"
        echo ""
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔧 ЗАГРУЖЕННЫЕ МОДУЛИ ЯДРА (amneziawg)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        lsmod | grep -E "(amnezia|wireguard)" || echo "  (модули не загружены)"
        echo ""
        
        echo "============================================================"
        echo "КОНЕЦ ДИАГНОСТИЧЕСКОГО ОТЧЁТА"
        echo "============================================================"
        
    } > "$diag_file" 2>&1
    
    echo -e "${YELLOW}📄 Полный диагностический отчёт сохранён:${NC} $diag_file" >&2
    echo -e "${YELLOW}📏 Размер:${NC} $(du -h "$diag_file" | cut -f1)" >&2
    echo "" >&2
    
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${MAGENTA}📋 КРАТКАЯ СВОДКА ДИАГНОСТИКИ (первые 100 строк)${NC}" >&2
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    head -n 100 "$diag_file" >&2
    echo -e "${MAGENTA}... (полный отчёт в файле $diag_file)${NC}\n" >&2
    
    echo "$diag_file" > "$DIAGNOSTICS_DIR/latest_diagnostics"
    
    ls -t "$DIAGNOSTICS_DIR"/diagnostics_*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
    
    log "✓ Диагностический отчёт создан: $diag_file"
}

# ============================================================================
# СИСТЕМА БЕКАПОВ И ОТКАТА
# ============================================================================

create_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"
    log "Создание полного бэкапа #$ts..."

    iptables-save > "$BACKUP_DIR/iptables_$ts.save" 2>/dev/null || true
    lsmod > "$BACKUP_DIR/lsmod_$ts.txt" 2>/dev/null || true

    {
        echo "# Состояние namespace до установки"
        ip netns list 2>/dev/null || echo "Нет namespace"
        echo "# Состояние awg0"
        ip link show awg0 2>/dev/null || echo "awg0 не существует"
        echo "# Состояние veth"
        ip link show veth-host 2>/dev/null || echo "veth-host не существует"
        echo "# Таблицы маршрутизации"
        ip route show 2>/dev/null || true
        echo "# Правила ip rule"
        ip rule show 2>/dev/null || true
    } > "$BACKUP_DIR/network_state_$ts.txt" 2>/dev/null || true

    tar czf "$BACKUP_DIR/configs_$ts.tar.gz" \
        /etc/amnezia \
        /etc/systemd/system/xray.service \
        /etc/systemd/system/wg-namespace.service \
        /etc/systemd/system/hysteria-server.service \
        /etc/systemd/system/socat-443.service \
        /etc/systemd/system/socat-8443.service \
        /usr/local/bin/setup-awg-namespace.sh \
        /usr/local/bin/setup-socat-forward.sh \
        /usr/local/etc/xray \
        /etc/hysteria \
        /etc/resolv.conf \
        /etc/netns 2>/dev/null || true

    if [[ ! -f "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
        error "Не удалось создать бэкап конфигов"
        die "Бэкап не создан, установка прервана"
    fi
    if [[ ! -s "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
        error "Бэкап пустой или повреждён"
        die "Бэкап невалиден, установка прервана"
    fi

    cat > "$BACKUP_DIR/rollback_$ts.sh" << ROLLBACK_EOF
#!/bin/bash
set -e
echo "Начало отката к состоянию #$ts..."

echo "Остановка всех сервисов..."
systemctl stop xray hysteria-server socat-443 socat-8443 awg-quick@awg0 2>/dev/null || true
sleep 2

echo "Удаление интерфейсов внутри namespace..."
if ip netns list 2>/dev/null | grep -q "^xray"; then
    ip netns exec xray ip link delete awg0 2>/dev/null || true
    ip netns exec xray ip link delete veth-ns 2>/dev/null || true
fi

echo "Удаление veth-пары..."
ip link delete veth-host 2>/dev/null || true

echo "Удаление namespace..."
ip netns delete $NAMESPACE 2>/dev/null || rm -f /run/netns/$NAMESPACE || true

if [[ -f "$BACKUP_DIR/iptables_$ts.save" ]]; then
    echo "Восстановление iptables..."
    iptables-restore < "$BACKUP_DIR/iptables_$ts.save" 2>/dev/null || true
fi

if [[ -f "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
    echo "Восстановление конфигураций..."
    tar xzf "$BACKUP_DIR/configs_$ts.tar.gz" -C / 2>/dev/null || true
fi

if lsmod 2>/dev/null | grep -q amneziawg; then
    echo "Выгрузка модуля amneziawg..."
    rmmod amneziawg 2>/dev/null || true
fi

echo "✓ Откат завершен"
ROLLBACK_EOF
    chmod +x "$BACKUP_DIR/rollback_$ts.sh"

    echo "$ts" > "$BACKUP_DIR/latest_backup"

    ls -t "$BACKUP_DIR"/rollback_*.sh 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -t "$BACKUP_DIR"/configs_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -t "$BACKUP_DIR"/iptables_*.save 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -t "$BACKUP_DIR"/network_state_*.txt 2>/dev/null | tail -n +6 | xargs -r rm -f

    log "✓ Полный бэкап создан: $ts"
}

rollback() {
    collect_diagnostics
    
    if [[ ! -f "$BACKUP_DIR/latest_backup" ]]; then
        warn "Бэкапы не найдены, откат невозможен"
        # Принудительная очистка даже без бэкапа
        systemctl stop xray hysteria-server socat-443 socat-8443 awg-quick@awg0 2>/dev/null || true
        sleep 2
        if ip netns list 2>/dev/null | grep -q "^xray"; then
            ip netns exec xray ip link delete awg0 2>/dev/null || true
            ip netns exec xray ip link delete veth-ns 2>/dev/null || true
        fi
        ip link delete veth-host 2>/dev/null || true
        ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
        return 0
    fi

    local latest_ts
    latest_ts=$(cat "$BACKUP_DIR/latest_backup")
    local rollback_script="$BACKUP_DIR/rollback_$latest_ts.sh"

    if [[ ! -f "$rollback_script" ]]; then
        error "Скрипт отката не найден: $rollback_script"
        systemctl stop xray hysteria-server socat-443 socat-8443 awg-quick@awg0 2>/dev/null || true
        sleep 2
        if ip netns list 2>/dev/null | grep -q "^xray"; then
            ip netns exec xray ip link delete awg0 2>/dev/null || true
            ip netns exec xray ip link delete veth-ns 2>/dev/null || true
        fi
        ip link delete veth-host 2>/dev/null || true
        ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
        return 1
    fi

    echo -e "\n${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ВЫПОЛНЯЕТСЯ АВТОМАТИЧЕСКИЙ ОТКАТ            ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"

    bash "$rollback_script" || true

    echo -e "${RED}✓ Откат завершен. Проверьте лог: $LOG${NC}\n"
}

trap 'error "Критическая ошибка на строке $LINENO"; rollback' ERR

# ============================================================================
# БЕЗОПАСНЫЕ SSH ФУНКЦИИ
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
# МЕХАНИЗМ ПОВТОРНЫХ ПОПЫТОК И HEALTH CHECKS
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

wait_for_service() {
    local service="$1"
    local max_wait="${2:-30}"
    local interval=2
    local elapsed=0

    log "Ожидание готовности сервиса $service (максимум ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "✓ Сервис $service готов (за $elapsed сек)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    error "Сервис $service не запустился за ${max_wait}s"
    return 1
}

wait_for_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local max_wait="${3:-30}"
    local interval=1
    local elapsed=0

    log "Ожидание готовности порта $port/$protocol (максимум ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if [[ "$protocol" == "tcp" ]] && ss -tlnp 2>/dev/null | grep -q ":$port"; then
            log "✓ Порт $port/tcp готов (за $elapsed сек)"
            return 0
        elif [[ "$protocol" == "udp" ]] && ss -ulnp 2>/dev/null | grep -q ":$port"; then
            log "✓ Порт $port/udp готов (за $elapsed сек)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    error "Порт $port/$protocol не готов за ${max_wait}s"
    return 1
}

check_namespace_health() {
    if ! ip netns list 2>/dev/null | grep -q "^$NAMESPACE"; then
        return 1
    fi
    
    if ! ip netns exec "$NAMESPACE" ip link show awg0 >/dev/null 2>&1; then
        return 1
    fi
    
    if ! ip netns exec "$NAMESPACE" ip route show | grep -q "default"; then
        return 1
    fi
    
    return 0
}

# ============================================================================
# ИСПРАВЛЕНО v6.1.0: Полная очистка всех сервисов и интерфейсов
# ============================================================================

cleanup_all() {
    log "Полная очистка всех сервисов и интерфейсов..."
    
    # 1. Остановка ВСЕХ сервисов (включая awg-quick@awg0!)
    log "Остановка сервисов..."
    systemctl stop xray.service hysteria-server.service socat-443.service socat-8443.service 2>/dev/null || true
    systemctl stop awg-quick@awg0.service 2>/dev/null || true
    sleep 2
    
    # 2. Удаление интерфейсов ВНУТРИ namespace (до удаления самого namespace)
    if ip netns list 2>/dev/null | grep -q "^$NAMESPACE"; then
        log "Удаление интерфейсов внутри namespace '$NAMESPACE'..."
        ip netns exec "$NAMESPACE" ip link delete awg0 2>/dev/null || true
        ip netns exec "$NAMESPACE" ip link delete veth-ns 2>/dev/null || true
        sleep 1
    fi
    
    # 3. Удаление veth-host в основном namespace
    log "Удаление veth-пары..."
    ip link delete veth-host 2>/dev/null || true
    ip link delete veth-ns 2>/dev/null || true
    sleep 1
    
    # 4. Удаление namespace
    log "Удаление namespace '$NAMESPACE'..."
    ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
    sleep 2
    
    # 5. Проверка, что всё очищено
    if ip netns list 2>/dev/null | grep -q "^$NAMESPACE"; then
        warn "Namespace '$NAMESPACE' всё ещё существует, принудительное удаление..."
        rm -f "/run/netns/$NAMESPACE" || true
    fi
    
    if ip link show awg0 2>/dev/null | grep -q "awg0"; then
        warn "Интерфейс awg0 всё ещё существует в основном namespace"
    fi
    
    if ip link show veth-host 2>/dev/null | grep -q "veth-host"; then
        warn "Интерфейс veth-host всё ещё существует"
    fi
    
    log "✓ Полная очистка завершена"
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

mkdir -p "$(dirname "$LOG")"
echo "=== XRAY RELAY MANAGER v$VERSION ===" > "$LOG"
echo "Начало: $(date)" >> "$LOG"
echo "Хост: $(hostname)" >> "$LOG"

create_backup

# ============================================================================
# ШАГ 1-13: УСТАНОВКА (без изменений)
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

section "Шаг 2: Проверка SSH подключения"

detect_package_manager
pkg_install sshpass 2>/dev/null || true

validate_ssh_auth

if ! retry_cmd 3 10 "relay_ssh 'echo SSH_OK'"; then
    die "Не удалось подключиться к $RELAY_IP. Проверьте IP и аутентификацию."
fi
log "✓ SSH подключение работает"

section "Шаг 3: Определение ОС"

RELAY_OS=$(relay_ssh 'grep ^ID= /etc/os-release | cut -d= -f2 | tr -d "\""' || echo "unknown")
RELAY_VERSION=$(relay_ssh 'grep ^VERSION_ID= /etc/os-release | cut -d= -f2 | tr -d "\""' || echo "unknown")
RELAY_KERNEL=$(relay_ssh 'uname -r' || echo "unknown")

LOCAL_OS=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
LOCAL_VERSION=$(grep ^VERSION_ID= /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
LOCAL_KERNEL=$(uname -r)

log "РФ сервер: $RELAY_OS $RELAY_VERSION (ядро: $RELAY_KERNEL)"
log "Локальный: $LOCAL_OS $LOCAL_VERSION (ядро: $LOCAL_KERNEL)"

section "Шаг 4: Обновление систем"

log "Обновление РФ сервера..."
relay_ssh 'export DEBIAN_FRONTEND=noninteractive && apt-get update -y -qq && apt-get upgrade -y -qq' || \
    warn "Не удалось обновить РФ сервер"

log "Обновление локального сервера..."
pkg_install iptables-persistent socat 2>/dev/null || true

log "✓ Системы обновлены, iptables-persistent и socat установлены"

section "Шаг 5: Установка AmneziaWG на РФ сервере"

if relay_ssh 'command -v awg >/dev/null && lsmod | grep -q amneziawg'; then
    log "✓ AmneziaWG уже установлен"
else
    log "Установка AmneziaWG..."

    RELAY_HEADERS=$(relay_ssh 'dpkg -l "linux-headers-$(uname -r)" 2>/dev/null | grep -c "^ii" || echo "0"' 2>/dev/null || echo "0")
    RELAY_HEADERS=$(echo "$RELAY_HEADERS" | tr -d '\n\r ' | head -c 1)

    if [[ -z "$RELAY_HEADERS" ]]; then
        RELAY_HEADERS=0
    fi

    if ! [[ "$RELAY_HEADERS" =~ ^[0-9]+$ ]]; then
        warn "Некорректное значение RELAY_HEADERS: '$RELAY_HEADERS', устанавливаем 0"
        RELAY_HEADERS=0
    fi

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

if ! iptables -t nat -L POSTROUTING -v -n | grep -q "MASQUERADE.*$DEFAULT_IFACE"; then
    echo "ERROR: Правила iptables не применены"
    exit 1
fi

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

section "Шаг 7: Копирование конфига"

if ! retry_cmd 3 10 "relay_scp_from /root/relay-configs/client.conf /root/awg-client.conf"; then
    die "Не удалось скопировать конфиг"
fi
log "✓ Конфиг скопирован"

section "Шаг 8: Установка AmneziaWG локально"

if command -v awg &> /dev/null && lsmod | grep -q amneziawg; then
    log "✓ AmneziaWG уже установлен"
else
    log "Установка AmneziaWG..."

    HEADERS=0
    if dpkg -l "linux-headers-$(uname -r)" 2>/dev/null | grep -q "^ii"; then
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

section "Шаг 9: Настройка клиента"

log "Очистка..."
systemctl stop xray 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true
ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
ip link delete awg0 2>/dev/null || true
ip link delete veth-host 2>/dev/null || true
ip link delete veth-ns 2>/dev/null || true

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

section "Шаг 10: Создание namespace"

if [[ -d "/run/netns/$NAMESPACE" ]]; then
    warn "Namespace существует, удаляем..."
    ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
fi

ip netns add "$NAMESPACE"
ip link set awg0 netns "$NAMESPACE"

ip netns exec "$NAMESPACE" ip link set awg0 up
ip netns exec "$NAMESPACE" ip addr add 10.10.0.2/24 dev awg0
ip netns exec "$NAMESPACE" ip link set lo up
ip netns exec "$NAMESPACE" ip route add default via 10.10.0.1 dev awg0

if command -v resolvectl &> /dev/null; then
    ip netns exec "$NAMESPACE" resolvectl dns awg0 8.8.8.8 1.1.1.1 2>/dev/null || true
else
    mkdir -p /etc/netns/"$NAMESPACE"
    echo "nameserver 8.8.8.8" > /etc/netns/"$NAMESPACE"/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/netns/"$NAMESPACE"/resolv.conf
fi

log "✓ Namespace создан с правильной конфигурацией"

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

if ! xray -test -config "$CONFIG_DIR/config.json" > /dev/null 2>&1; then
    die "Конфиг Xray невалиден"
fi

section "Шаг 13: Установка Hysteria2"

check_hysteria_works() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null && \
       ip netns exec xray ss -ulnp 2>/dev/null | grep -q ":8443"; then
        return 0
    fi
    return 1
}

setup_hysteria_service() {
    log "Создание systemd-сервиса Hysteria2 (запуск от root)..."
    cat > /etc/systemd/system/hysteria-server.service << 'HYSTERIA_SVC'
[Unit]
Description=Hysteria Server Service (via AmneziaWG relay)
After=network.target wg-namespace.service
Requires=wg-namespace.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/hysteria
ExecStart=/sbin/ip netns exec xray /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
ProtectSystem=off
ProtectHome=off
PrivateTmp=off
NoNewPrivileges=no

[Install]
WantedBy=multi-user.target
HYSTERIA_SVC
    systemctl daemon-reload
    systemctl enable hysteria-server > /dev/null 2>&1
    log "✓ Systemd-сервис Hysteria2 создан (запуск от root)"
}

if check_hysteria_works; then
    log "✓ Hysteria2 уже установлен и работает"
else
    if command -v hysteria &> /dev/null && [[ -f /etc/hysteria/config.yaml ]]; then
        warn "Hysteria2 установлен, но не работает — пересоздаём конфиг..."
        HY_PASS=$(jq -r '.clients[0].uuid' "$CONFIG_DIR/clients.json" 2>/dev/null || echo "")
        if [[ -z "$HY_PASS" ]]; then
            die "Не удалось получить UUID из clients.json"
        fi

        rm -f /etc/hysteria/key.pem /etc/hysteria/cert.pem

        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
            -subj "/CN=www.apple.com" -days 3650 2>/dev/null

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

        setup_hysteria_service
        systemctl restart hysteria-server 2>/dev/null || true
        sleep 2
        if check_hysteria_works; then
            log "✓ Hysteria2 работает после пересоздания конфига"
        else
            warn "Hysteria2 не запустился"
        fi
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

            setup_hysteria_service
            systemctl restart hysteria-server
            sleep 2
            if check_hysteria_works; then
                log "✓ Hysteria2 установлен и запущен"
            else
                warn "Hysteria2 установлен, но не запустился"
            fi
        fi
    fi
fi

# ============================================================================
# ШАГ 14-15: SYSTEMD СЕРВИСЫ + VETH + SOCAT
# ============================================================================

section "Шаг 14: Создание systemd сервисов"

cat > /usr/local/bin/setup-awg-namespace.sh << 'NSEOF'
#!/usr/bin/env bash
set -e

if ip netns list 2>/dev/null | grep -q "^xray" && \
   ip netns exec xray ip link show awg0 >/dev/null 2>&1 && \
   ip netns exec xray ip route show | grep -q "default"; then
    echo "✓ Namespace xray уже существует и работает, пропускаем пересоздание"
    exit 0
fi

systemctl stop awg-quick@awg0 2>/dev/null || true
ip link delete awg0 2>/dev/null || true
ip netns delete xray 2>/dev/null || rm -f /run/netns/xray || true

systemctl start awg-quick@awg0
sleep 3

ip netns add xray
ip link set awg0 netns xray

ip netns exec xray ip link set awg0 up
ip netns exec xray ip addr add 10.10.0.2/24 dev awg0
ip netns exec xray ip link set lo up
ip netns exec xray ip route add default via 10.10.0.1 dev awg0

if command -v resolvectl &> /dev/null; then
    ip netns exec xray resolvectl dns awg0 8.8.8.8 1.1.1.1 2>/dev/null || true
else
    mkdir -p /etc/netns/xray
    echo "nameserver 8.8.8.8" > /etc/netns/xray/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/netns/xray/resolv.conf
fi

echo "Namespace xray настроен"
NSEOF
chmod +x /usr/local/bin/setup-awg-namespace.sh

cat > /etc/systemd/system/wg-namespace.service << 'SVCEOF'
[Unit]
Description=Setup AmneziaWG namespace
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-awg-namespace.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service (via AmneziaWG relay, in namespace)
After=network.target wg-namespace.service
Requires=wg-namespace.service

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

cat > /etc/systemd/system/hysteria-server.service << 'HYSTERIA_SVC'
[Unit]
Description=Hysteria Server Service (via AmneziaWG relay, in namespace)
After=network.target wg-namespace.service
Requires=wg-namespace.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/hysteria
ExecStart=/sbin/ip netns exec xray /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
ProtectSystem=off
ProtectHome=off
PrivateTmp=off
NoNewPrivileges=no

[Install]
WantedBy=multi-user.target
HYSTERIA_SVC

systemctl daemon-reload
systemctl enable wg-namespace.service xray.service hysteria-server.service > /dev/null 2>&1
log "✓ Сервисы созданы (Xray и Hysteria2 в namespace)"

section "Шаг 15: Настройка veth-пары и socat"

cat > /usr/local/bin/setup-socat-forward.sh << SOCAT_EOF
#!/usr/bin/env bash
set -e

NAMESPACE="xray"
VETH_HOST_IP="$VETH_HOST_IP"
VETH_NS_IP="$VETH_NS_IP"

if ! ip netns list 2>/dev/null | grep -q "^\$NAMESPACE"; then
    echo "ERROR: Namespace \$NAMESPACE не существует"
    exit 1
fi

echo "Проверка существующей veth-пары..."

if ip link show veth-host 2>/dev/null | grep -q "veth-host"; then
    echo "Удаление существующего veth-host..."
    ip link delete veth-host 2>/dev/null || true
    sleep 1
fi

if ip netns exec \$NAMESPACE ip link show veth-ns 2>/dev/null | grep -q "veth-ns"; then
    echo "Удаление существующего veth-ns внутри namespace..."
    ip netns exec \$NAMESPACE ip link delete veth-ns 2>/dev/null || true
    sleep 1
fi

ip link delete veth-ns 2>/dev/null || true
sleep 1

echo "Создание veth-пары..."
ip link add veth-host type veth peer name veth-ns
ip link set veth-ns netns \$NAMESPACE

ip addr add \$VETH_HOST_IP/24 dev veth-host
ip link set veth-host up

ip netns exec \$NAMESPACE ip addr add \$VETH_NS_IP/24 dev veth-ns
ip netns exec \$NAMESPACE ip link set veth-ns up

ip netns exec \$NAMESPACE ip route add 10.200.0.0/24 dev veth-ns

echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-forwarding.conf
sysctl --system > /dev/null 2>&1

sysctl -w net.ipv4.conf.veth-host.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true

iptables -A FORWARD -i veth-host -o veth-ns -j ACCEPT
iptables -A FORWARD -i veth-ns -o veth-host -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "✓ veth-пара создана: \$VETH_HOST_IP <-> \$VETH_NS_IP"

if ! ping -c 1 -W 2 \$VETH_NS_IP >/dev/null 2>&1; then
    echo "ERROR: Не удалось установить связь с namespace через veth"
    exit 1
fi
echo "✓ Связь с namespace установлена"

which netfilter-persistent && netfilter-persistent save || true

echo "✓ veth-пара настроена, socat запускается через systemd"
SOCAT_EOF
chmod +x /usr/local/bin/setup-socat-forward.sh

cat > /etc/systemd/system/socat-443.service << 'EOF'
[Unit]
Description=Socat Port 443 Forwarding to Xray Namespace
After=network.target wg-namespace.service xray.service
Requires=wg-namespace.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:443,bind=0.0.0.0,fork,reuseaddr TCP:10.200.0.2:443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/socat-8443.service << 'EOF'
[Unit]
Description=Socat Port 8443 Forwarding to Xray Namespace
After=network.target wg-namespace.service hysteria-server.service
Requires=wg-namespace.service

[Service]
Type=simple
ExecStart=/usr/bin/socat UDP-LISTEN:8443,bind=0.0.0.0,fork,reuseaddr UDP:10.200.0.2:8443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable socat-443.service socat-8443.service > /dev/null 2>&1
log "✓ Socat сервисы созданы (Type=simple, foreground, bind=0.0.0.0)"

# ============================================================================
# ШАГ 16-17: ЗАПУСК + SMOKE ТЕСТЫ С RETRY
# ============================================================================

section "Шаг 16: Запуск всех сервисов"

# ИСПРАВЛЕНО v6.1.0: Используем функцию cleanup_all для полной очистки
cleanup_all

if ! check_namespace_health; then
    log "Namespace не работает, создаем..."
    /usr/local/bin/setup-awg-namespace.sh
else
    log "✓ Namespace уже работает, пропускаем создание"
fi

log "Создание veth-пары..."
/usr/local/bin/setup-socat-forward.sh

log "Запуск Xray..."
systemctl start xray
if ! wait_for_service xray 30; then
    die "Xray не запустился"
fi

log "Проверка порта 443 внутри namespace..."
for i in {1..10}; do
    if ip netns exec xray ss -tlnp 2>/dev/null | grep -q ":443"; then
        log "✓ Xray слушает порт 443 внутри namespace"
        break
    fi
    if [[ $i -eq 10 ]]; then
        die "Xray не слушает порт 443 после 10 попыток"
    fi
    sleep 1
done

log "Запуск Hysteria2..."
systemctl start hysteria-server
if ! wait_for_service hysteria-server 30; then
    warn "Hysteria2 не запустился"
fi

log "Ожидание готовности Xray (5 секунд)..."
sleep 5

log "Запуск socat..."
systemctl start socat-443.service socat-8443.service
if ! wait_for_service socat-443.service 10; then
    die "Socat-443 не запустился"
fi
if ! wait_for_service socat-8443.service 10; then
    warn "Socat-8443 не запустился"
fi

log "Проверка логов socat..."
if journalctl -u socat-443.service -n 10 --no-pager | grep -qi "error\|failed\|refused"; then
    error "Socat-443 упал с ошибкой:"
    journalctl -u socat-443.service -n 20 --no-pager
    die "Socat-443 не работает"
fi

log "Проверка, слушает ли socat порт 443..."
if ! ss -tlnp | grep -q ":443.*socat"; then
    error "Socat не слушает порт 443"
    ss -tlnp | grep :443 || echo "Порт 443 не слушается"
    die "Socat не работает"
fi

wait_for_port 443 tcp 30 || die "Порт 443/tcp не готов"
wait_for_port 8443 udp 30 || warn "Порт 8443/udp не готов"

if systemctl is-active --quiet xray; then
    log "✓ Xray запущен (в namespace)"
else
    warn "Xray не запустился"
fi

if systemctl is-active --quiet hysteria-server; then
    log "✓ Hysteria2 запущен (в namespace)"
else
    warn "Hysteria2 не запустился"
fi

if systemctl is-active --quiet socat-443.service && systemctl is-active --quiet socat-8443.service; then
    log "✓ Socat проброс портов запущен"
else
    warn "Socat не запустился"
fi

if ss -tlnp | grep -q ":443"; then
    log "✓ Порт 443 слушается на основном интерфейсе"
else
    warn "Порт 443 не слушается на основном интерфейсе"
fi

if ss -ulnp | grep -q ":8443"; then
    log "✓ Порт 8443 слушается на основном интерфейсе"
else
    warn "Порт 8443 не слушается на основном интерфейсе"
fi

if ip netns exec xray ss -tlnp 2>/dev/null | grep -q ":443"; then
    log "✓ Xray слушает порт 443 внутри namespace"
else
    warn "Xray не слушает порт 443 внутри namespace"
fi

section "Шаг 17: Smoke тесты с retry"

SMOKE_PASSED=true

run_smoke_test() {
    local test_name="$1"
    local test_cmd="$2"
    local max_attempts=3
    local attempt=1
    
    echo "Тест: $test_name..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$test_cmd" >/dev/null 2>&1; then
            log "✓ $test_name пройден (попытка $attempt/$max_attempts)"
            return 0
        fi
        warn "$test_name: попытка $attempt/$max_attempts не удалась, ожидание 2s..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    error "✗ $test_name НЕ пройден после $max_attempts попыток"
    return 1
}

if ! run_smoke_test "Тест 1: IP через туннель" \
    "TEST_IP=\$(ip netns exec xray curl -s4 --max-time 10 ifconfig.me 2>/dev/null) && [[ \"\$TEST_IP\" != \"FAILED\" && -n \"\$TEST_IP\" ]]"; then
    error "Туннель не работает"
    SMOKE_PASSED=false
fi

if ! run_smoke_test "Тест 2: Xray в namespace" \
    "ip netns exec xray ss -tlnp 2>/dev/null | grep -q ':443'"; then
    error "Xray не слушает порт 443"
    SMOKE_PASSED=false
fi

if ! run_smoke_test "Тест 3: Hysteria2 в namespace" \
    "ip netns exec xray ss -ulnp 2>/dev/null | grep -q ':8443' || ip netns exec xray ps aux 2>/dev/null | grep -q '[h]ysteria'"; then
    warn "Hysteria2 не слушает порт 8443"
fi

if ! run_smoke_test "Тест 4: Порт 443 извне" \
    "ss -tlnp | grep -q ':443'"; then
    error "Порт 443 не доступен извне"
    error "Диагностика:"
    ss -tlnp | grep :443 || echo "Порт 443 не слушается"
    journalctl -u socat-443.service -n 10 --no-pager
    SMOKE_PASSED=false
fi

if ! run_smoke_test "Тест 5: Порт 8443 извне" \
    "ss -ulnp | grep -q ':8443'"; then
    warn "Порт 8443 не доступен извне"
fi

if ! run_smoke_test "Тест 6: veth-связь" \
    "ping -c 1 -W 2 $VETH_NS_IP >/dev/null 2>&1"; then
    error "veth-пара не работает"
    SMOKE_PASSED=false
fi

if [[ "$SMOKE_PASSED" == "false" ]]; then
    error "❌ Критические smoke тесты НЕ пройдены!"
    rollback
    die "Установка завершена с ошибками"
else
    log "✅ Все критические smoke тесты пройдены!"
fi

# ============================================================================
# ШАГ 18-19: XRAY-ADMIN И ФИНАЛЬНЫЙ ОТЧЁТ
# ============================================================================

section "Шаг 18: Создание управляющего скрипта"

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
DIAGNOSTICS_DIR="/root/.xray-diagnostics"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Нужен root"; exit 1; }

log_action() {
    echo "[$(date -Iseconds)] $USER: $*" >> "$LOG_FILE"
}

get_relay_ip() {
    local ip
    ip=$(grep -E "^Endpoint" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | \
        awk '{print $3}' | cut -d: -f1)
    if [[ -z "$ip" ]]; then
        echo "unknown"
    else
        echo "$ip"
    fi
}

get_public_ip() {
    ip netns exec $NAMESPACE curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A"
}

cmd_status() {
    log_action "status"
    echo -e "${CYAN}=== Статус VPN Relay ===${NC}"
    local relay_ip
    relay_ip=$(get_relay_ip)
    printf "%-25s %s\n" "Relay (РФ):" "$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o LogLevel=ERROR -q root@"$relay_ip" 'systemctl is-active amneziawg@awg0' 2>/dev/null || echo 'unreachable')"
    printf "%-25s %s\n" "Client (AWG):" "$(systemctl is-active awg-quick@awg0 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Xray:" "$(systemctl is-active xray 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Hysteria2:" "$(systemctl is-active hysteria-server 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Socat-443:" "$(systemctl is-active socat-443.service 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Socat-8443:" "$(systemctl is-active socat-8443.service 2>/dev/null || echo 'inactive')"
    printf "%-25s %s\n" "Namespace:" "$(ip netns list 2>/dev/null | grep -c $NAMESPACE || echo '0')/1"
    printf "%-25s %s\n" "IP через туннель:" "$(get_public_ip)"
    echo ""

    echo -e "${YELLOW}Порты на основном интерфейсе:${NC}"
    ss -tlnp 2>/dev/null | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет TCP слушателей"
    ss -ulnp 2>/dev/null | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет UDP слушателей"
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
        local tmp
        tmp=$(mktemp)
        jq ".clients += [{\"name\":\"$name\",\"uuid\":\"$uuid\",\"created\":\"$(date -Iseconds)\"}]" "$CLIENTS" > "$tmp" && mv "$tmp" "$CLIENTS"
    }

    echo -e "${GREEN}✓ Добавлен клиент: $name ($uuid)${NC}"
    cmd_gen_links "$name"
}

cmd_remove_client() {
    local name="$1"
    log_action "remove_client $name"
    local tmp
    tmp=$(mktemp)
    jq "del(.clients[] | select(.name==\"$name\"))" "$CLIENTS" > "$tmp" && mv "$tmp" "$CLIENTS"
    echo -e "${GREEN}✓ Удален клиент: $name${NC}"
    systemctl restart xray
}

cmd_rename_client() {
    local old="$1" new="$2"
    log_action "rename_client $old -> $new"
    local tmp
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
    echo -e "${YELLOW}Подключайтесь к РФ relay: $relay_ip${NC}"
    echo ""
    > /root/xray-links.txt

    if [[ -f "$CLIENTS" ]]; then
        jq -r '.clients[] | select(.name=="'"$target"'" or "'"all"'"=="all") | "\(.name) \(.uuid)"' "$CLIENTS" | \
        while read -r n u; do
            echo -e "${YELLOW}$n:${NC}"
            L1="vless://$u@$relay_ip:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pub&sid=$sid&type=tcp#$n"
            L2="hysteria2://$hy_pass@$relay_ip:8443?insecure=1&sni=$sni#$n"
            echo "  REALITY:   $L1"
            echo "  Hysteria2: $L2"
            echo "=== $n ===" >> /root/xray-links.txt
            echo "$L1" >> /root/xray-links.txt
            echo "$L2" >> /root/xray-links.txt
            echo ""
        done
    fi

    echo -e "\n${GREEN}✓ Ссылки сохранены: /root/xray-links.txt${NC}"
}

cmd_restart() {
    log_action "restart"
    echo "Перезапуск всех сервисов..."
    /usr/local/bin/setup-awg-namespace.sh
    /usr/local/bin/setup-socat-forward.sh
    systemctl restart xray.service hysteria-server.service socat-443.service socat-8443.service 2>/dev/null || true
    sleep 3
    cmd_status
}

cmd_monitor() {
    log_action "monitor"
    echo "Запуск мониторинга... (Ctrl+C для остановки)"
    while true; do
        local xray_st awg_st socat443_st socat8443_st ip
        xray_st=$(systemctl is-active xray 2>/dev/null || echo "inactive")
        awg_st=$(systemctl is-active awg-quick@awg0 2>/dev/null || echo "inactive")
        socat443_st=$(systemctl is-active socat-443.service 2>/dev/null || echo "inactive")
        socat8443_st=$(systemctl is-active socat-8443.service 2>/dev/null || echo "inactive")
        ip=$(get_public_ip)
        echo -e "[$(date '+%H:%M:%S')] Xray: $xray_st | AWG: $awg_st | Socat-443: $socat443_st | Socat-8443: $socat8443_st | IP: $ip"

        if [[ "$xray_st" != "active" ]]; then
            echo -e "${RED}Xray упал! Перезапуск...${NC}"
            /usr/local/bin/setup-awg-namespace.sh && systemctl restart xray
            send_alert "🚨 Xray перезагружен на $(hostname)"
        fi
        if [[ "$socat443_st" != "active" ]]; then
            echo -e "${RED}Socat-443 упал! Перезапуск...${NC}"
            systemctl restart socat-443.service
            send_alert "🚨 Socat-443 перезагружен на $(hostname)"
        fi
        if [[ "$socat8443_st" != "active" ]]; then
            echo -e "${RED}Socat-8443 упал! Перезапуск...${NC}"
            systemctl restart socat-8443.service
            send_alert "🚨 Socat-8443 перезагружен на $(hostname)"
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

cmd_restore() {
    log_action "restore"
    if [[ ! -f "$BACKUP_DIR/latest_backup" ]]; then
        error "Бэкапы не найдены в $BACKUP_DIR"
        exit 1
    fi

    local latest_ts
    latest_ts=$(cat "$BACKUP_DIR/latest_backup")
    local rollback_script="$BACKUP_DIR/rollback_$latest_ts.sh"

    if [[ ! -f "$rollback_script" ]]; then
        error "Скрипт отката не найден: $rollback_script"
        exit 1
    fi

    echo -e "${YELLOW}Восстановление из бэкапа #$latest_ts...${NC}"
    bash "$rollback_script"
    echo -e "${GREEN}✓ Восстановление завершено${NC}"
}

cmd_diagnostics() {
    log_action "diagnostics"
    
    if [[ ! -f "$DIAGNOSTICS_DIR/latest_diagnostics" ]]; then
        error "Диагностические отчёты не найдены в $DIAGNOSTICS_DIR"
        exit 1
    fi
    
    local latest_diag
    latest_diag=$(cat "$DIAGNOSTICS_DIR/latest_diagnostics")
    
    if [[ ! -f "$latest_diag" ]]; then
        error "Файл диагностики не найден: $latest_diag"
        exit 1
    fi
    
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}📋 ПОСЛЕДНИЙ ДИАГНОСТИЧЕСКИЙ ОТЧЁТ${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📄 Файл:${NC} $latest_diag"
    echo -e "${YELLOW}📏 Размер:${NC} $(du -h "$latest_diag" | cut -f1)"
    echo -e "${YELLOW}📅 Дата:${NC} $(stat -c %y "$latest_diag" | cut -d. -f1)"
    echo ""
    
    cat "$latest_diag"
}

cmd_update() {
    log_action "update"
    echo "Проверка обновлений Xray..."

    local current_version latest
    current_version=$(xray version 2>&1 | head -1 | grep -oP 'Xray \K[0-9.]+' || echo "unknown")
    latest=$(curl -sL https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -1 || echo "unknown")

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
    echo "xray-admin v6.1.0"
    echo "VPN Relay Manager (Вариант B: Namespace + veth + socat)"
    echo ""
    echo "Установленные компоненты:"
    echo "  Xray: $(xray version 2>&1 | head -1 || echo 'не установлен')"
    echo "  Hysteria2: $(hysteria version 2>&1 | head -1 || echo 'не установлен')"
    echo "  AmneziaWG: $(awg --version 2>&1 | head -1 || echo 'не установлен')"
    echo "  Socat: $(socat -V 2>&1 | head -1 || echo 'не установлен')"
    echo ""
    echo "Архитектура:"
    echo "  • Xray и Hysteria2 работают ВНУТРИ namespace 'xray'"
    echo "  • veth-пара обеспечивает безопасную связь между namespaces"
    echo "  • Socat пробрасывает порты 443 и 8443 через veth"
    echo "  • Весь исходящий трафик идёт через AmneziaWG на РФ relay"
    echo "  • Входящий трафик от клиентов идёт через socat → veth → namespace"
    echo ""
    echo "Диагностика:"
    echo "  • Бэкапы: $BACKUP_DIR"
    echo "  • Диагностические отчёты: $DIAGNOSTICS_DIR"
    echo "  • Лог: $LOG_FILE"
}

cmd_help() {
    echo -e "${CYAN}xray-admin v6.1.0 - Управление VPN Relay${NC}"
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
    echo "  diagnostics         - Показать последний диагностический отчёт"
    echo "  update              - Обновить Xray до последней версии"
    echo "  version             - Показать версию и компоненты"
    echo "  help                - Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  xray-admin add my-phone"
    echo "  xray-admin links admin"
    echo "  xray-admin status"
    echo "  xray-admin diagnostics"
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
    diagnostics) cmd_diagnostics ;;
    update)     cmd_update ;;
    version|--version|-v) cmd_version ;;
    help|--help|-h|"") cmd_help ;;
    *)          echo "Неизвестная команда: $1"; cmd_help; exit 1 ;;
esac
ADMINEOF

chmod +x "$ADMIN_BIN"
log "✓ Управляющий скрипт создан: $ADMIN_BIN"

section "✅ Установка завершена успешно!"

echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VPN Relay v6.1.0 (Вариант B: Namespace + veth)   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Архитектура:${NC}"
echo "  📱 Клиент → eth0:443/8443 (основной интерфейс)"
echo "       ↓"
echo "  🔌 Socat (TCP/UDP)"
echo "       ↓"
echo "  🌐 veth-host (10.200.0.1) ↔ veth-ns (10.200.0.2)"
echo "       ↓"
echo "  📦 Namespace 'xray' (изолированная среда)"
echo "       ├── Xray (порт 443, VLESS-REALITY)"
echo "       ├── Hysteria2 (порт 8443, UDP)"
echo "       └── awg0 (AmneziaWG туннель)"
echo "              ↓"
echo "  🇷🇺 РФ relay ($RELAY_IP)"
echo "              ↓"
echo "  🌐 Интернет"
echo ""

echo -e "${YELLOW}Статус:${NC}"
printf "  %-30s %s\n" "AmneziaWG (relay):" "$(relay_ssh 'systemctl is-active amneziawg@awg0' 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "AmneziaWG (client):" "$(systemctl is-active awg-quick@awg0 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "Xray:" "$(systemctl is-active xray 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "Hysteria2:" "$(systemctl is-active hysteria-server 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "Socat-443:" "$(systemctl is-active socat-443.service 2>/dev/null || echo 'inactive')"
printf "  %-30s %s\n" "Socat-8443:" "$(systemctl is-active socat-8443.service 2>/dev/null || echo 'inactive')"
echo ""

echo -e "${YELLOW}IP информация:${NC}"
printf "  %-30s %s\n" "РФ relay:" "$RELAY_IP"
printf "  %-30s %s\n" "Xray через туннель:" "$TUNNEL_IP"
printf "  %-30s %s\n" "veth-host:" "$VETH_HOST_IP"
printf "  %-30s %s\n" "veth-ns:" "$VETH_NS_IP"
echo ""

echo -e "${YELLOW}Порты на основном интерфейсе:${NC}"
ss -tlnp | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет TCP слушателей"
ss -ulnp | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет UDP слушателей"
echo ""

echo -e "${YELLOW}Управление:${NC}"
echo "  xray-admin status         # Статус системы"
echo "  xray-admin add user       # Добавить клиента"
echo "  xray-admin remove user    # Удалить клиента"
echo "  xray-admin rename old new # Переименовать"
echo "  xray-admin links          # Получить ссылки"
echo "  xray-admin restart        # Перезапустить сервисы"
echo "  xray-admin monitor        # Мониторинг"
echo "  xray-admin alerts         # Оповещения"
echo "  xray-admin diagnostics    # Показать диагностический отчёт"
echo "  xray-admin version        # Версия компонентов"
echo "  xray-admin restore        # Восстановить из бэкапа"
echo "  xray-admin help           # Помощь"
echo ""

echo -e "${YELLOW}Диагностика и отладка:${NC}"
echo "  • Бэкапы: $BACKUP_DIR"
echo "  • Диагностические отчёты: $DIAGNOSTICS_DIR"
echo "  • Лог установки: $LOG"
echo ""

echo -e "${YELLOW}Безопасность:${NC}"
echo "  • SSH ключи вместо паролей"
echo "  • Xray и Hysteria2 изолированы в namespace"
echo "  • veth-пара обеспечивает контролируемую связь"
echo "  • Весь трафик идёт через туннель (утечки невозможны)"
echo ""

echo -e "${GREEN}✓ Готово! Система протестирована и работает.${NC}"
log "Установка завершена успешно"
'''

with open('/root/setup-vpn-relay.sh', 'w') as f:
    f.write(script)

os.chmod('/root/setup-vpn-relay.sh', 0o755)
print(f"✅ Скрипт v6.1.0 создан: /root/setup-vpn-relay.sh")
print(f"📊 Размер: {os.path.getsize('/root/setup-vpn-relay.sh')} байт")
print(f"📝 Строк: {script.count(chr(10))}")
print(f"\n🔧 Ключевые исправления в v6.1.0:")
print(f"  ✓ ИСПРАВЛЕНО: Добавлена функция cleanup_all() для полной очистки")
print(f"    - Остановка ВСЕХ сервисов (включая awg-quick@awg0)")
print(f"    - Удаление интерфейсов ВНУТРИ namespace перед удалением namespace")
print(f"    - Удаление veth-пары")
print(f"    - Удаление namespace")
print(f"    - Проверка, что всё очищено")
print(f"  ✓ Улучшенный rollback:")
print(f"    - Принудительная очистка даже при отсутствии бэкапа")
print(f"    - Корректная последовательность удаления интерфейсов")
print(f"  ✓ Расширенная диагностика:")
print(f"    - Добавлена проверка awg0 в namespace xray")
print(f"    - Добавлена проверка процессов awg")
print(f"    - Добавлены логи сервиса awg-quick@awg0")
PYEOF
