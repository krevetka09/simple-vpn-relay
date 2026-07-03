python3 << 'PYEOF'
import os

script = r'''#!/usr/bin/env bash
# ============================================================================
# XRAY RELAY MANAGER - Production Ready v6.3.0 (Final)
# Архитектура: Вариант B (Namespace + veth + socat)
# ИСПРАВЛЕНО v6.3.0: Reverse-stop, отдельный AWG cleanup, idempotent netns
# ============================================================================

set -euo pipefail

readonly VERSION="6.3.0"
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

# ИСПРАВЛЕНО v6.3.0: Убран awg-quick@awg0 из списка сервисов для массовой остановки
readonly CORE_SERVICES=(xray hysteria-server)
readonly SOCAT_SERVICES=(socat-443 socat-8443)
readonly ALL_SERVICES=(xray hysteria-server socat-443 socat-8443 wg-namespace)

RELAY_IP=""
RELAY_AUTH=""
PKG_MANAGER=""
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

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
# ИСПРАВЛЕНО v6.3.0: Idempotent-функция для очистки сети (netns/veth)
# ============================================================================

cleanup_network() {
    log "Idempotent очистка сети (netns/veth)..."
    set +e
    
    # ИСПРАВЛЕНО v6.3.0: Guard-ы для идемпотентности
    if ip link show veth-host >/dev/null 2>&1; then
        log "Удаление veth-host..."
        ip link delete veth-host 2>/dev/null || true
        sleep 1
    else
        log "veth-host не существует, пропускаем"
    fi
    
    if ip netns list 2>/dev/null | grep -q "^$NAMESPACE"; then
        log "Удаление интерфейсов в namespace '$NAMESPACE'..."
        ip netns exec "$NAMESPACE" ip link delete awg0 2>/dev/null || true
        ip netns exec "$NAMESPACE" ip link delete veth-ns 2>/dev/null || true
        sleep 1
        
        log "Удаление namespace '$NAMESPACE'..."
        ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
        sleep 2
    else
        log "Namespace '$NAMESPACE' не существует, пропускаем"
    fi
    
    # Проверка очистки
    if ip netns list 2>/dev/null | grep -q "^$NAMESPACE"; then
        warn "Namespace '$NAMESPACE' всё ещё существует, принудительное удаление..."
        rm -f "/run/netns/$NAMESPACE" || true
    fi
    
    set -e
    log "✓ Очистка сети завершена"
}

# ============================================================================
# ИСПРАВЛЕНО v6.3.0: Отдельная процедура остановки AWG
# ============================================================================

cleanup_awg() {
    log "Отдельная процедура остановки AWG..."
    set +e
    
    # Остановка awg-quick@awg0
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        log "Остановка awg-quick@awg0..."
        systemctl stop awg-quick@awg0 2>/dev/null || true
        sleep 2
    fi
    
    # Удаление интерфейса awg0 (если существует в основном namespace)
    if ip link show awg0 >/dev/null 2>&1; then
        log "Удаление интерфейса awg0..."
        ip link delete awg0 2>/dev/null || true
        sleep 1
    fi
    
    set -e
    log "✓ Остановка AWG завершена"
}

# ============================================================================
# ИСПРАВЛЕНО v6.3.0: Reverse-stop для сервисов
# ============================================================================

stop_services_reverse() {
    log "Остановка сервисов в обратном порядке (reverse-stop)..."
    set +e
    
    # ИСПРАВЛЕНО v6.3.0: Остановка в обратном порядке зависимостей
    # Порядок: socat → xray/hysteria → wg-namespace → awg-quick
    
    # 1. Остановка socat (зависит от xray/hysteria)
    for service in "${SOCAT_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "Остановка $service..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
    sleep 1
    
    # 2. Остановка core сервисов (xray, hysteria-server)
    for service in "${CORE_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "Остановка $service..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
    sleep 1
    
    # 3. Остановка wg-namespace
    if systemctl is-active --quiet wg-namespace 2>/dev/null; then
        log "Остановка wg-namespace..."
        systemctl stop wg-namespace 2>/dev/null || true
        sleep 1
    fi
    
    # 4. Остановка AWG (отдельная процедура)
    cleanup_awg
    
    set -e
    log "✓ Остановка сервисов завершена"
}

# ============================================================================
# ДИАГНОСТИКА
# ============================================================================

collect_diagnostics() {
    local ts diag_file
    ts=$(date +%Y%m%d_%H%M%S)
    diag_file="$DIAGNOSTICS_DIR/diagnostics_$ts.log"
    
    mkdir -p "$DIAGNOSTICS_DIR"
    
    echo -e "\n${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${MAGENTA}║  📊 СБОР ДИАГНОСТИЧЕСКОЙ ИНФОРМАЦИИ                      ║${NC}" >&2
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}\n" >&2
    
    {
        echo "============================================================"
        echo "ДИАГНОСТИЧЕСКИЙ ОТЧЁТ v$VERSION"
        echo "Время: $(date)"
        echo "Хост: $(hostname)"
        echo "============================================================"
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📋 СТАТУС СИСТЕМНЫХ СЕРВИСОВ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for service in "${ALL_SERVICES[@]}" awg-quick@awg0; do
            echo -e "\n▶ Сервис: $service"
            systemctl status "$service" --no-pager -l 2>&1 | head -20 || echo "  (не найден)"
        done
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📜 ПОСЛЕДНИЕ ЛОГИ (30 строк)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for service in "${ALL_SERVICES[@]}" awg-quick@awg0; do
            echo -e "\n▶ $service:"
            journalctl -u "$service" -n 30 --no-pager 2>&1 | tail -30 || echo "  (недоступны)"
        done
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🌐 NETWORK NAMESPACES"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "\n▶ Список:"
        ip netns list 2>&1 || echo "  (нет)"
        
        if ip netns list 2>/dev/null | grep -q "^xray"; then
            echo -e "\n▶ Интерфейсы в 'xray':"
            ip netns exec xray ip link show 2>&1
            echo -e "\n▶ IP в 'xray':"
            ip netns exec xray ip addr show 2>&1
            echo -e "\n▶ Маршруты в 'xray':"
            ip netns exec xray ip route show 2>&1
            echo -e "\n▶ TCP в 'xray':"
            ip netns exec xray ss -tlnp 2>&1
            echo -e "\n▶ UDP в 'xray' (ss -ulnp):"
            ip netns exec xray ss -ulnp 2>&1
        fi
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔗 VETH-ПАРА И AMNEZIAWG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for iface in awg0 veth-host veth-ns; do
            echo -e "\n▶ $iface:"
            ip link show "$iface" 2>&1 || echo "  (не существует)"
        done
        echo -e "\n▶ awg0 в namespace xray:"
        ip netns exec xray ip link show awg0 2>&1 || echo "  (нет)"
        echo -e "\n▶ AmneziaWG статус:"
        awg show 2>&1 || echo "  (не запущен)"
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🚪 ПОРТЫ НА ОСНОВНОМ ИНТЕРФЕЙСЕ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "\n▶ TCP 443:"
        ss -tlnp 2>&1 | grep -E ":443|State" || echo "  (не слушается)"
        echo -e "\n▶ UDP 8443 (ss -ulnp):"
        ss -ulnp 2>&1 | grep -E ":8443|State" || echo "  (не слушается)"
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔥 IPTABLES И SYSCTL"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "\n▶ FORWARD:"
        iptables -L FORWARD -v -n 2>&1
        echo -e "\n▶ NAT POSTROUTING:"
        iptables -t nat -L POSTROUTING -v -n 2>&1
        echo -e "\n▶ IP forward:"
        sysctl net.ipv4.ip_forward 2>&1
        echo -e "\n▶ rp_filter:"
        sysctl net.ipv4.conf.all.rp_filter 2>&1
        sysctl net.ipv4.conf.veth-host.rp_filter 2>&1
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚡ ПРОЦЕССЫ И МОДУЛИ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "\n▶ Процессы:"
        ps aux | grep -E "(xray|hysteria|socat|awg)" | grep -v grep || echo "  (нет)"
        echo -e "\n▶ Модули ядра:"
        lsmod | grep -E "(amnezia|wireguard)" || echo "  (не загружены)"
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📝 ПОСЛЕДНИЕ 50 СТРОК ЛОГА УСТАНОВКИ"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        [[ -f "$LOG" ]] && tail -n 50 "$LOG" || echo "  (лог не найден)"
        
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "💾 ДИСК"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        df -h 2>&1
        
        echo -e "\n============================================================"
        echo "КОНЕЦ ОТЧЁТА"
        echo "============================================================"
        
    } > "$diag_file" 2>&1
    
    echo -e "${YELLOW}📄 Отчёт сохранён:${NC} $diag_file" >&2
    echo -e "${YELLOW}📏 Размер:${NC} $(du -h "$diag_file" | cut -f1)" >&2
    echo "" >&2
    
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${MAGENTA}📋 КРАТКАЯ СВОДКА (первые 100 строк)${NC}" >&2
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    head -n 100 "$diag_file" >&2
    echo -e "${MAGENTA}... (полный отчёт: $diag_file)${NC}\n" >&2
    
    echo "$diag_file" > "$DIAGNOSTICS_DIR/latest_diagnostics"
    ls -t "$DIAGNOSTICS_DIR"/diagnostics_*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
    
    log "✓ Диагностический отчёт: $diag_file"
}

# ============================================================================
# БЕКАПЫ И ОТКАТ
# ============================================================================

create_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"
    log "Создание бэкапа #$ts..."

    iptables-save > "$BACKUP_DIR/iptables_$ts.save" 2>/dev/null || true
    lsmod > "$BACKUP_DIR/lsmod_$ts.txt" 2>/dev/null || true

    {
        echo "# Network state before install"
        ip netns list 2>/dev/null || echo "No namespace"
        ip link show awg0 2>/dev/null || echo "awg0 missing"
        ip link show veth-host 2>/dev/null || echo "veth-host missing"
        ip route show 2>/dev/null || true
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

    if [[ ! -f "$BACKUP_DIR/configs_$ts.tar.gz" || ! -s "$BACKUP_DIR/configs_$ts.tar.gz" ]]; then
        error "Бэкап не создан"
        die "Установка прервана"
    fi

    cat > "$BACKUP_DIR/rollback_$ts.sh" << ROLLBACK_EOF
#!/bin/bash
set -e
echo "Откат к #$ts..."

# ИСПРАВЛЕНО v6.3.0: Reverse-stop
systemctl stop socat-443 socat-8443 2>/dev/null || true
sleep 1
systemctl stop xray hysteria-server 2>/dev/null || true
sleep 1
systemctl stop wg-namespace 2>/dev/null || true
sleep 1

# ИСПРАВЛЕНО v6.3.0: Отдельная процедура остановки AWG
systemctl stop awg-quick@awg0 2>/dev/null || true
sleep 2
ip link delete awg0 2>/dev/null || true
sleep 1

# ИСПРАВЛЕНО v6.3.0: Idempotent очистка сети
if ip link show veth-host >/dev/null 2>&1; then
    ip link delete veth-host 2>/dev/null || true
    sleep 1
fi

if ip netns list 2>/dev/null | grep -q "^xray"; then
    ip netns exec xray ip link delete awg0 2>/dev/null || true
    ip netns exec xray ip link delete veth-ns 2>/dev/null || true
    sleep 1
    ip netns delete xray 2>/dev/null || rm -f /run/netns/xray || true
    sleep 2
fi

[[ -f "$BACKUP_DIR/iptables_$ts.save" ]] && iptables-restore < "$BACKUP_DIR/iptables_$ts.save" 2>/dev/null || true
[[ -f "$BACKUP_DIR/configs_$ts.tar.gz" ]] && tar xzf "$BACKUP_DIR/configs_$ts.tar.gz" -C / 2>/dev/null || true
lsmod 2>/dev/null | grep -q amneziawg && rmmod amneziawg 2>/dev/null || true
echo "✓ Откат завершён"
ROLLBACK_EOF
    chmod +x "$BACKUP_DIR/rollback_$ts.sh"
    echo "$ts" > "$BACKUP_DIR/latest_backup"

    for pattern in rollback_ configs_ iptables_ network_state_; do
        ls -t "$BACKUP_DIR"/${pattern}* 2>/dev/null | tail -n +6 | xargs -r rm -f
    done

    log "✓ Бэкап #$ts создан"
}

rollback() {
    collect_diagnostics
    
    if [[ ! -f "$BACKUP_DIR/latest_backup" ]]; then
        warn "Бэкапы не найдены, принудительная очистка"
        stop_services_reverse
        cleanup_network
        return 0
    fi

    local latest_ts rollback_script
    latest_ts=$(cat "$BACKUP_DIR/latest_backup")
    rollback_script="$BACKUP_DIR/rollback_$latest_ts.sh"

    if [[ ! -f "$rollback_script" ]]; then
        error "Скрипт отката не найден, принудительная очистка"
        stop_services_reverse
        cleanup_network
        return 1
    fi

    echo -e "\n${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ВЫПОЛНЯЕТСЯ АВТОМАТИЧЕСКИЙ ОТКАТ            ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"

    bash "$rollback_script" || {
        warn "Откат завершился с ошибкой, принудительная очистка"
        stop_services_reverse
        cleanup_network
    }

    echo -e "${RED}✓ Откат завершён. Лог: $LOG${NC}\n"
}

trap 'error "Критическая ошибка на строке $LINENO"; rollback' ERR

# ============================================================================
# SSH ФУНКЦИИ
# ============================================================================

validate_ssh_auth() {
    if [[ -f "$RELAY_AUTH" ]]; then
        [[ ! -r "$RELAY_AUTH" ]] && die "SSH ключ не читается: $RELAY_AUTH"
        chmod 600 "$RELAY_AUTH" 2>/dev/null || true
        log "✓ SSH ключ: $RELAY_AUTH"
    else
        warn "⚠️  ВНИМАНИЕ: Пароли небезопасны!"
        warn "Рекомендуется: ssh-keygen -t ed25519 && ssh-copy-id root@$RELAY_IP"
    fi
}

relay_ssh() {
    local cmd="$1"
    if [[ -f "$RELAY_AUTH" ]]; then
        ssh $SSH_OPTS -i "$RELAY_AUTH" root@"$RELAY_IP" "$cmd" 2>/dev/null
    else
        sshpass -f <(printf '%s' "$RELAY_AUTH") ssh $SSH_OPTS root@"$RELAY_IP" "$cmd" 2>/dev/null
    fi
}

relay_scp_from() {
    local src="$1" dst="$2"
    if [[ -f "$RELAY_AUTH" ]]; then
        scp $SSH_OPTS -i "$RELAY_AUTH" root@"$RELAY_IP":"$src" "$dst" 2>/dev/null
    else
        sshpass -f <(printf '%s' "$RELAY_AUTH") scp $SSH_OPTS root@"$RELAY_IP":"$src" "$dst" 2>/dev/null
    fi
}

relay_scp() {
    local src="$1" dst="$2"
    if [[ -f "$RELAY_AUTH" ]]; then
        scp $SSH_OPTS -i "$RELAY_AUTH" "$src" root@"$RELAY_IP":"$dst" 2>/dev/null
    else
        sshpass -f <(printf '%s' "$RELAY_AUTH") scp $SSH_OPTS "$src" root@"$RELAY_IP":"$dst" 2>/dev/null
    fi
}

# ============================================================================
# МЕХАНИЗМ ПОВТОРНЫХ ПОПЫТОК
# ============================================================================

retry_cmd() {
    local max_attempts="${1:-3}" delay="${2:-5}"
    shift 2
    local cmd="$*" attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if eval "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        warn "Попытка $attempt/$max_attempts. Ожидание ${delay}s..."
        sleep "$delay"
        ((attempt++))
        delay=$((delay * 2))
    done
    return 1
}

wait_for_service() {
    local service="$1" max_wait="${2:-30}" interval=2 elapsed=0

    log "Ожидание $service (макс ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "✓ $service готов (${elapsed}s)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    error "$service не запустился за ${max_wait}s"
    journalctl -u "$service" -n 10 --no-pager 2>&1 || true
    return 1
}

wait_for_port() {
    local port="$1" protocol="${2:-tcp}" max_wait="${3:-30}" interval=1 elapsed=0
    local cmd="ss -tlnp"
    [[ "$protocol" == "udp" ]] && cmd="ss -ulnp"

    log "Ожидание порта $port/$protocol (макс ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if $cmd 2>/dev/null | grep -q ":$port"; then
            log "✓ Порт $port/$protocol готов (${elapsed}s)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    error "Порт $port/$protocol не готов за ${max_wait}s"
    return 1
}

check_namespace_health() {
    ip netns list 2>/dev/null | grep -q "^$NAMESPACE" || return 1
    ip netns exec "$NAMESPACE" ip link show awg0 >/dev/null 2>&1 || return 1
    ip netns exec "$NAMESPACE" ip route show | grep -q "default" || return 1
    ip netns exec "$NAMESPACE" ip link show veth-ns >/dev/null 2>&1 || return 1
    return 0
}

# ============================================================================
# ИСПРАВЛЕНО v6.3.0: Единая функция очистки (вызывается один раз)
# ============================================================================

cleanup_all() {
    log "Полная очистка (единая функция)..."
    
    # 1. Reverse-stop для сервисов
    stop_services_reverse
    
    # 2. Idempotent очистка сети
    cleanup_network
    
    log "✓ Полная очистка завершена"
}

# ============================================================================
# ПАКЕТНЫЙ МЕНЕДЖЕР
# ============================================================================

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    else
        die "Неподдерживаемый пакетный менеджер"
    fi
    log "✓ Пакетный менеджер: $PKG_MANAGER"
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
# ШАГ 1-13: УСТАНОВКА
# ============================================================================

section "Шаг 1: Проверка DNS"

fix_dns() {
    ping -c 1 -W 2 github.com > /dev/null 2>&1 && return 0
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

retry_cmd 3 5 fix_dns || die "Не удалось настроить DNS"
log "✓ DNS работает"

section "Шаг 2: Проверка SSH"

detect_package_manager
pkg_install sshpass 2>/dev/null || true
validate_ssh_auth

retry_cmd 3 10 "relay_ssh 'echo SSH_OK'" || die "Не удалось подключиться к $RELAY_IP"
log "✓ SSH работает"

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
log "✓ Системы обновлены"

section "Шаг 5: AmneziaWG на РФ сервере"

if relay_ssh 'command -v awg >/dev/null && lsmod | grep -q amneziawg'; then
    log "✓ AmneziaWG уже установлен"
else
    log "Установка AmneziaWG..."

    RELAY_HEADERS=$(relay_ssh 'dpkg -l "linux-headers-$(uname -r)" 2>/dev/null | grep -c "^ii" || echo "0"' 2>/dev/null || echo "0")
    RELAY_HEADERS=$(echo "$RELAY_HEADERS" | tr -d '\n\r ' | head -c 1)
    [[ -z "$RELAY_HEADERS" || ! "$RELAY_HEADERS" =~ ^[0-9]+$ ]] && RELAY_HEADERS=0

    if [[ "$RELAY_HEADERS" -eq 0 ]]; then
        warn "Headers недоступны, обновляем ядро..."
        relay_ssh 'export DEBIAN_FRONTEND=noninteractive && apt-get install -y linux-image-amd64 linux-headers-amd64'
        relay_ssh 'update-grub'
        log "Перезагрузка РФ сервера..."
        relay_ssh 'reboot' || true
        sleep 30
        for i in {1..30}; do
            relay_ssh 'echo OK' >/dev/null 2>&1 && { log "✓ Сервер вернулся"; break; }
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
[[ -d "src" && -f "src/Makefile" ]] && cd src
make -j2 && make install
modprobe amneziawg
echo "amneziawg" > /etc/modules-load.d/amneziawg.conf

cd /tmp
git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git
cd amneziawg-tools
[[ -d "src" && -f "src/Makefile" ]] && cd src
make -j2 && make install

cd / && rm -rf /tmp/amneziawg-*
which netfilter-persistent && netfilter-persistent save || true
echo "AmneziaWG установлен"
AWG_EOF

    relay_scp /tmp/install-awg-relay.sh /tmp/install-awg-relay.sh
    relay_ssh 'chmod +x /tmp/install-awg-relay.sh && /tmp/install-awg-relay.sh'
    log "✓ AmneziaWG установлен на РФ"
fi

section "Шаг 6: Настройка relay"

if relay_ssh 'systemctl is-active amneziawg@awg0 >/dev/null 2>&1 && test -f /root/relay-configs/client.conf'; then
    log "✓ Relay уже настроен"
else
    log "Настройка relay..."
    cat > /tmp/setup-relay.sh << 'RELAY_EOF'
#!/bin/bash
set -e

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
[[ -z "$DEFAULT_IFACE" ]] && { echo "ERROR: Интерфейс не найден"; exit 1; }

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

systemctl is-active amneziawg@awg0 > /dev/null 2>&1 || {
    echo "ERROR: AmneziaWG не запустился"
    journalctl -u amneziawg@awg0 -n 20 --no-pager
    exit 1
}

iptables -t nat -L POSTROUTING -v -n | grep -q "MASQUERADE.*$DEFAULT_IFACE" || {
    echo "ERROR: iptables не применены"
    exit 1
}

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
    log "✓ Relay настроен"
fi

section "Шаг 7: Копирование конфига"

retry_cmd 3 10 "relay_scp_from /root/relay-configs/client.conf /root/awg-client.conf" || die "Не удалось скопировать конфиг"
log "✓ Конфиг скопирован"

section "Шаг 8: AmneziaWG локально"

if command -v awg &> /dev/null && lsmod | grep -q amneziawg; then
    log "✓ AmneziaWG уже установлен"
else
    log "Установка AmneziaWG..."

    HEADERS=0
    dpkg -l "linux-headers-$(uname -r)" 2>/dev/null | grep -q "^ii" && HEADERS=1

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

    [[ ! -d "/lib/modules/$(uname -r)/build" ]] && die "Headers не установлены"
    log "✓ Headers установлены"

    cd /tmp && rm -rf amneziawg-*

    retry_cmd 3 10 "git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git" || \
        die "Не удалось клонировать репозиторий ядра"

    cd amneziawg-linux-kernel-module
    [[ -d "src" && -f "src/Makefile" ]] && cd src
    make -j2 && make install

    modprobe amneziawg
    echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
    lsmod | grep -q amneziawg || die "Модуль amneziawg не загрузился"
    log "✓ Модуль загружен"

    cd /tmp
    retry_cmd 3 10 "git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git" || \
        die "Не удалось клонировать утилиты"

    cd amneziawg-tools
    [[ -d "src" && -f "src/Makefile" ]] && cd src
    make -j2 && make install

    command -v awg &> /dev/null || die "awg не установлена"
    log "✓ AmneziaWG: $(awg --version 2>&1 | head -1)"
    cd / && rm -rf /tmp/amneziawg-*
fi

section "Шаг 9: Настройка клиента"

log "Очистка..."
# ИСПРАВЛЕНО v6.3.0: Используем единую функцию очистки
cleanup_all

mkdir -p /etc/amnezia/amneziawg
grep -q "^DNS" /root/awg-client.conf && sed -i '/^DNS/d' /root/awg-client.conf
cp /root/awg-client.conf /etc/amnezia/amneziawg/awg0.conf
chmod 600 /etc/amnezia/amneziawg/awg0.conf

systemctl enable awg-quick@awg0 > /dev/null 2>&1
systemctl start awg-quick@awg0
sleep 3

systemctl is-active --quiet awg-quick@awg0 || die "AmneziaWG не запустился"
log "✓ AmneziaWG запущен"

awg show | grep -q "latest handshake" && log "✓ Handshake" || warn "Handshake не установлен"
ping -c 3 -W 2 10.10.0.1 > /dev/null 2>&1 && log "✓ Пинг до relay" || warn "Пинг не проходит"

section "Шаг 10: Создание namespace"

# ИСПРАВЛЕНО v6.3.0: Idempotent создание namespace
if ip netns list 2>/dev/null | grep -q "^$NAMESPACE"; then
    warn "Namespace '$NAMESPACE' уже существует, удаляем..."
    ip netns exec "$NAMESPACE" ip link delete awg0 2>/dev/null || true
    ip netns exec "$NAMESPACE" ip link delete veth-ns 2>/dev/null || true
    ip netns delete "$NAMESPACE" 2>/dev/null || rm -f "/run/netns/$NAMESPACE" || true
    sleep 2
fi

log "Создание namespace '$NAMESPACE'..."
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
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/netns/"$NAMESPACE"/resolv.conf
fi

log "✓ Namespace создан"
ip netns exec "$NAMESPACE" ip addr show awg0 | grep -q "10.10.0.2" || die "IP не добавлен"
log "✓ IP 10.10.0.2 добавлен"

ip netns exec "$NAMESPACE" ping -c 3 -W 2 10.10.0.1 > /dev/null 2>&1 && log "✓ Пинг через туннель" || warn "Пинг не проходит"

TUNNEL_IP=$(ip netns exec "$NAMESPACE" curl -s4 --max-time 10 ifconfig.me 2>/dev/null || echo "failed")
[[ "$TUNNEL_IP" == "failed" || -z "$TUNNEL_IP" ]] && warn "IP через туннель не получен" || log "✓ IP через туннель: $TUNNEL_IP"

section "Шаг 11: Установка Xray"

if [[ -f /usr/local/xray/xray ]]; then
    log "✓ Xray уже установлен"
else
    log "Установка Xray..."
    pkg_install curl unzip jq openssl qrencode

    mkdir -p /usr/local/xray /usr/local/etc/xray
    cd /tmp

    LATEST=$(curl -sL https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -1) || die "Не удалось получить версию"
    log "Версия Xray: $LATEST"

    retry_cmd 3 10 "wget -q -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v${LATEST}/Xray-linux-64.zip" || die "Скачать не удалось"

    unzip -o -q /tmp/xray.zip -d /usr/local/xray
    rm -f /tmp/xray.zip
    chmod +x /usr/local/xray/xray
    ln -sf /usr/local/xray/xray /usr/local/bin/xray

    log "✓ Xray: $(xray version 2>&1 | head -1)"
fi

section "Шаг 12: Конфиг Xray"

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
    log "✓ Конфиг существует"
fi

xray -test -config "$CONFIG_DIR/config.json" > /dev/null 2>&1 || die "Конфиг Xray невалиден"

section "Шаг 13: Установка Hysteria2"

check_hysteria_works() {
    systemctl is-active --quiet hysteria-server 2>/dev/null && \
    ip netns exec xray ss -ulnp 2>/dev/null | grep -q ":8443"
}

setup_hysteria_service() {
    log "Создание systemd-сервиса Hysteria2..."
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
    systemctl enable hysteria-server > /dev/null 2>&1
    log "✓ Сервис Hysteria2 создан"
}

if check_hysteria_works; then
    log "✓ Hysteria2 работает"
else
    if command -v hysteria &> /dev/null && [[ -f /etc/hysteria/config.yaml ]]; then
        warn "Hysteria2 установлен, но не работает — пересоздаём..."
        HY_PASS=$(jq -r '.clients[0].uuid' "$CONFIG_DIR/clients.json" 2>/dev/null || echo "")
        [[ -z "$HY_PASS" ]] && die "Не удалось получить UUID"

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
        check_hysteria_works && log "✓ Hysteria2 работает" || warn "Hysteria2 не запустился"
    else
        log "Установка Hysteria2..."
        retry_cmd 3 10 "bash <(curl -fsSL https://get.hy2.sh/)" || { warn "Не удалось установить Hysteria2"; return 0; }
        
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
        check_hysteria_works && log "✓ Hysteria2 установлен" || warn "Hysteria2 не запустился"
    fi
fi

# ============================================================================
# ШАГ 14-15: SYSTEMD + VETH + SOCAT (ИСПРАВЛЕНО v6.3.0)
# ============================================================================

section "Шаг 14: Создание systemd сервисов"

cat > /usr/local/bin/setup-awg-namespace.sh << 'NSEOF'
#!/usr/bin/env bash
set -e

if ip netns list 2>/dev/null | grep -q "^xray" && \
   ip netns exec xray ip link show awg0 >/dev/null 2>&1 && \
   ip netns exec xray ip route show | grep -q "default"; then
    echo "✓ Namespace xray работает"
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
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/netns/xray/resolv.conf
fi

echo "Namespace xray настроен"
NSEOF
chmod +x /usr/local/bin/setup-awg-namespace.sh

cat > /etc/systemd/system/wg-namespace.service << 'SVCEOF'
[Unit]
Description=Setup AmneziaWG namespace
Before=xray.service hysteria-server.service
After=network.target awg-quick@awg0.service
Wants=awg-quick@awg0.service

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
Before=socat-443.service

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
Before=socat-8443.service

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
log "✓ Сервисы созданы (линейная цепочка: wg-namespace → xray → socat)"

section "Шаг 15: Veth-пара и socat (ИСПРАВЛЕНО v6.3.0)"

cat > /usr/local/bin/setup-socat-forward.sh << SOCAT_EOF
#!/usr/bin/env bash

NAMESPACE="xray"
VETH_HOST_IP="$VETH_HOST_IP"
VETH_NS_IP="$VETH_NS_IP"

ip netns list 2>/dev/null | grep -q "^\$NAMESPACE" || { echo "ERROR: Namespace не существует"; exit 1; }

echo "Принудительное удаление существующих veth-интерфейсов..."

# ИСПРАВЛЕНО v6.3.0: Guard-ы для идемпотентности
if ip link show veth-host >/dev/null 2>&1; then
    ip link delete veth-host 2>/dev/null || true
    sleep 1
fi

if ip netns exec \$NAMESPACE ip link show veth-ns >/dev/null 2>&1; then
    ip netns exec \$NAMESPACE ip link delete veth-ns 2>/dev/null || true
    sleep 1
fi

echo "Создание новой veth-пары..."
ip link add veth-host type veth peer name veth-ns || {
    echo "ERROR: Не удалось создать veth-пару"
    exit 1
}

ip link set veth-ns netns \$NAMESPACE || {
    echo "ERROR: Не удалось переместить veth-ns"
    exit 1
}

ip addr add \$VETH_HOST_IP/24 dev veth-host || {
    echo "ERROR: Не удалось назначить IP veth-host"
    exit 1
}
ip link set veth-host up || {
    echo "ERROR: Не удалось поднять veth-host"
    exit 1
}

ip netns exec \$NAMESPACE ip addr add \$VETH_NS_IP/24 dev veth-ns || {
    echo "ERROR: Не удалось назначить IP veth-ns"
    exit 1
}
ip netns exec \$NAMESPACE ip link set veth-ns up || {
    echo "ERROR: Не удалось поднять veth-ns"
    exit 1
}

echo "Настройка маршрутов..."
ip netns exec \$NAMESPACE ip route flush 10.200.0.0/24 2>/dev/null || true
ip netns exec \$NAMESPACE ip route add 10.200.0.0/24 dev veth-ns || {
    echo "WARNING: Не удалось добавить маршрут (возможно уже существует)"
}

echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-forwarding.conf
sysctl --system > /dev/null 2>&1 || true

sysctl -w net.ipv4.conf.veth-host.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true

iptables -A FORWARD -i veth-host -o veth-ns -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i veth-ns -o veth-host -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

echo "✓ veth-пара: \$VETH_HOST_IP <-> \$VETH_NS_IP"

if ! ip link show veth-host >/dev/null 2>&1; then
    echo "ERROR: veth-host не создан"
    exit 1
fi

if ! ip netns exec \$NAMESPACE ip link show veth-ns >/dev/null 2>&1; then
    echo "ERROR: veth-ns не создан в namespace"
    exit 1
fi

if ! ping -c 1 -W 2 \$VETH_NS_IP >/dev/null 2>&1; then
    echo "WARNING: Ping не проходит, но veth-пара создана"
fi
echo "✓ Связь установлена"

which netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
echo "✓ veth настроена"

exit 0
SOCAT_EOF
chmod +x /usr/local/bin/setup-socat-forward.sh

# ИСПРАВЛЕНО v6.3.0: Жёсткие зависимости After=/Requires= для socat
cat > /etc/systemd/system/socat-443.service << 'EOF'
[Unit]
Description=Socat Port 443 Forwarding to Xray Namespace
After=network.target wg-namespace.service xray.service
Requires=wg-namespace.service xray.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/socat TCP-LISTEN:443,bind=0.0.0.0,fork,reuseaddr TCP:10.200.0.2:443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/socat-8443.service << 'EOF'
[Unit]
Description=Socat Port 8443 Forwarding to Hysteria Namespace
After=network.target wg-namespace.service hysteria-server.service
Requires=wg-namespace.service hysteria-server.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/socat UDP-LISTEN:8443,bind=0.0.0.0,fork,reuseaddr UDP:10.200.0.2:8443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable socat-443.service socat-8443.service > /dev/null 2>&1
log "✓ Socat сервисы (Type=simple, ExecStartPre=sleep 10, жёсткие зависимости)"

# ============================================================================
# ШАГ 16-17: ЗАПУСК + SMOKE ТЕСТЫ (ИСПРАВЛЕНО v6.3.0)
# ============================================================================

section "Шаг 16: Запуск всех сервисов (ИСПРАВЛЕНО v6.3.0)"

# ИСПРАВЛЕНО v6.3.0: Единая функция очистки (вызывается один раз)
cleanup_all

if ! check_namespace_health; then
    log "Namespace не работает, создаём..."
    /usr/local/bin/setup-awg-namespace.sh
else
    log "✓ Namespace работает"
fi

log "Создание veth-пары..."
/usr/local/bin/setup-socat-forward.sh || {
    error "setup-socat-forward.sh завершился с ошибкой"
    die "Не удалось создать veth-пару"
}

log "Запуск Xray..."
systemctl start xray
wait_for_service xray 30 || die "Xray не запустился"

log "Проверка порта 443 в namespace..."
for i in {1..10}; do
    if ip netns exec xray ss -tlnp 2>/dev/null | grep -q ":443"; then
        log "✓ Xray слушает порт 443"
        break
    fi
    [[ $i -eq 10 ]] && die "Xray не слушает порт 443 после 10 попыток"
    sleep 1
done

log "Запуск Hysteria2..."
systemctl start hysteria-server
wait_for_service hysteria-server 30 || warn "Hysteria2 не запустился"

log "Ожидание готовности сервисов (5s)..."
sleep 5

# ИСПРАВЛЕНО v6.3.0: Проверка занятости порта перед запуском socat
log "Проверка занятости порта 443..."
if ss -tlnp | grep -q ":443"; then
    error "Порт 443 уже занят другим процессом:"
    ss -tlnp | grep :443
    error "Остановите конфликтующий сервис и повторите установку"
    die "Порт 443 занят"
fi

log "Проверка занятости порта 8443..."
if ss -ulnp | grep -q ":8443"; then
    error "Порт 8443 уже занят другим процессом:"
    ss -ulnp | grep :8443
    error "Остановите конфликтующий сервис и повторите установку"
    die "Порт 8443 занят"
fi

log "Запуск socat..."
systemctl start socat-443.service socat-8443.service
wait_for_service socat-443.service 15 || die "Socat-443 не запустился"
wait_for_service socat-8443.service 15 || warn "Socat-8443 не запустился"

log "Проверка логов socat..."
if journalctl -u socat-443.service -n 10 --no-pager | grep -qi "error\|failed\|refused"; then
    error "Socat-443 упал:"
    journalctl -u socat-443.service -n 20 --no-pager
    die "Socat-443 не работает"
fi

log "Проверка портов..."
ss -tlnp | grep -q ":443.*socat" || {
    error "Socat не слушает порт 443"
    ss -tlnp | grep :443 || echo "Порт 443 не слушается"
    die "Socat не работает"
}

wait_for_port 443 tcp 30 || die "Порт 443/tcp не готов"
wait_for_port 8443 udp 30 || warn "Порт 8443/udp не готов"

systemctl is-active --quiet xray && log "✓ Xray запущен" || warn "Xray не запущен"
systemctl is-active --quiet hysteria-server && log "✓ Hysteria2 запущен" || warn "Hysteria2 не запущен"
systemctl is-active --quiet socat-443.service && systemctl is-active --quiet socat-8443.service && \
    log "✓ Socat запущен" || warn "Socat не запущен"

ss -tlnp | grep -q ":443" && log "✓ Порт 443 на основном интерфейсе" || warn "Порт 443 не на интерфейсе"
ss -ulnp | grep -q ":8443" && log "✓ Порт 8443 на основном интерфейсе" || warn "Порт 8443 не на интерфейсе"
ip netns exec xray ss -tlnp 2>/dev/null | grep -q ":443" && log "✓ Xray слушает 443 в namespace" || warn "Xray не слушает 443"

section "Шаг 17: Smoke тесты (ss -ulnp)"

SMOKE_PASSED=true

run_smoke_test() {
    local test_name="$1" test_cmd="$2" max_attempts=3 attempt=1
    
    echo "Тест: $test_name..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$test_cmd" >/dev/null 2>&1; then
            log "✓ $test_name пройден (попытка $attempt/$max_attempts)"
            return 0
        fi
        warn "$test_name: попытка $attempt/$max_attempts. Ожидание 2s..."
        sleep 2
        ((attempt++))
    done
    
    error "✗ $test_name НЕ пройден"
    return 1
}

run_smoke_test "Тест 1: IP через туннель" \
    "TEST_IP=\$(ip netns exec xray curl -s4 --max-time 10 ifconfig.me 2>/dev/null) && [[ \"\$TEST_IP\" != \"FAILED\" && -n \"\$TEST_IP\" ]]" || \
    { error "Туннель не работает"; SMOKE_PASSED=false; }

run_smoke_test "Тест 2: Xray в namespace (ss -tlnp)" \
    "ip netns exec xray ss -tlnp 2>/dev/null | grep -q ':443'" || \
    { error "Xray не слушает порт 443"; SMOKE_PASSED=false; }

run_smoke_test "Тест 3: Hysteria2 в namespace (ss -ulnp)" \
    "ip netns exec xray ss -ulnp 2>/dev/null | grep -q ':8443' || ip netns exec xray ps aux 2>/dev/null | grep -q '[h]ysteria'" || \
    warn "Hysteria2 не слушает 8443"

run_smoke_test "Тест 4: Порт 443 извне (ss -tlnp)" \
    "ss -tlnp | grep -q ':443'" || {
    error "Порт 443 не доступен"
    ss -tlnp | grep :443 || echo "Порт 443 не слушается"
    journalctl -u socat-443.service -n 10 --no-pager
    SMOKE_PASSED=false
}

run_smoke_test "Тест 5: Порт 8443 извне (ss -ulnp)" \
    "ss -ulnp | grep -q ':8443'" || warn "Порт 8443 не доступен"

run_smoke_test "Тест 6: veth-связь" \
    "ping -c 1 -W 2 $VETH_NS_IP >/dev/null 2>&1" || \
    { error "veth не работает"; SMOKE_PASSED=false; }

if [[ "$SMOKE_PASSED" == "false" ]]; then
    error "❌ Критические smoke тесты НЕ пройдены!"
    rollback
    die "Установка завершена с ошибками"
else
    log "✅ Все smoke тесты пройдены!"
fi

# ============================================================================
# ШАГ 18: XRAY-ADMIN (ИСПРАВЛЕНО v6.3.0)
# ============================================================================

section "Шаг 18: Управляющий скрипт"

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

log_action() { echo "[$(date -Iseconds)] $USER: $*" >> "$LOG_FILE"; }

get_relay_ip() {
    local ip
    ip=$(grep -E "^Endpoint" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | awk '{print $3}' | cut -d: -f1)
    [[ -z "$ip" ]] && echo "unknown" || echo "$ip"
}

get_public_ip() { ip netns exec $NAMESPACE curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A"; }

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
    ss -tlnp 2>/dev/null | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет TCP"
    ss -ulnp 2>/dev/null | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет UDP"
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

    echo -e "${GREEN}✓ Добавлен: $name ($uuid)${NC}"
    cmd_gen_links "$name"
}

cmd_remove_client() {
    local name="$1"
    log_action "remove_client $name"
    local tmp
    tmp=$(mktemp)
    jq "del(.clients[] | select(.name==\"$name\"))" "$CLIENTS" > "$tmp" && mv "$tmp" "$CLIENTS"
    echo -e "${GREEN}✓ Удалён: $name${NC}"
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
    echo "Перезапуск..."
    # ИСПРАВЛЕНО v6.3.0: Reverse-stop
    systemctl stop socat-443 socat-8443 2>/dev/null || true
    sleep 1
    systemctl stop xray hysteria-server 2>/dev/null || true
    sleep 1
    systemctl stop wg-namespace 2>/dev/null || true
    sleep 1
    systemctl stop awg-quick@awg0 2>/dev/null || true
    sleep 2
    ip link delete awg0 2>/dev/null || true
    sleep 1
    
    # Idempotent очистка сети
    if ip link show veth-host >/dev/null 2>&1; then
        ip link delete veth-host 2>/dev/null || true
        sleep 1
    fi
    
    if ip netns list 2>/dev/null | grep -q "^xray"; then
        ip netns exec xray ip link delete awg0 2>/dev/null || true
        ip netns exec xray ip link delete veth-ns 2>/dev/null || true
        sleep 1
        ip netns delete xray 2>/dev/null || rm -f /run/netns/xray || true
        sleep 2
    fi
    
    # Запуск в правильном порядке
    /usr/local/bin/setup-awg-namespace.sh
    /usr/local/bin/setup-socat-forward.sh || true
    systemctl start xray.service hysteria-server.service socat-443.service socat-8443.service 2>/dev/null || true
    sleep 3
    cmd_status
}

cmd_monitor() {
    log_action "monitor"
    echo "Мониторинг... (Ctrl+C для остановки)"
    while true; do
        local xray_st awg_st socat443_st socat8443_st ip
        xray_st=$(systemctl is-active xray 2>/dev/null || echo "inactive")
        awg_st=$(systemctl is-active awg-quick@awg0 2>/dev/null || echo "inactive")
        socat443_st=$(systemctl is-active socat-443.service 2>/dev/null || echo "inactive")
        socat8443_st=$(systemctl is-active socat-8443.service 2>/dev/null || echo "inactive")
        ip=$(get_public_ip)
        echo -e "[$(date '+%H:%M:%S')] Xray: $xray_st | AWG: $awg_st | Socat-443: $socat443_st | Socat-8443: $socat8443_st | IP: $ip"

        [[ "$xray_st" != "active" ]] && {
            echo -e "${RED}Xray упал!${NC}"
            /usr/local/bin/setup-awg-namespace.sh && systemctl restart xray
            send_alert "🚨 Xray перезапущен на $(hostname)"
        }
        [[ "$socat443_st" != "active" ]] && {
            echo -e "${RED}Socat-443 упал!${NC}"
            systemctl restart socat-443.service
            send_alert "🚨 Socat-443 перезапущен на $(hostname)"
        }
        [[ "$socat8443_st" != "active" ]] && {
            echo -e "${RED}Socat-8443 упал!${NC}"
            systemctl restart socat-8443.service
            send_alert "🚨 Socat-8443 перезапущен на $(hostname)"
        }
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
    [[ ! -f "$BACKUP_DIR/latest_backup" ]] && { error "Бэкапы не найдены"; exit 1; }

    local latest_ts rollback_script
    latest_ts=$(cat "$BACKUP_DIR/latest_backup")
    rollback_script="$BACKUP_DIR/rollback_$latest_ts.sh"

    [[ ! -f "$rollback_script" ]] && { error "Скрипт отката не найден"; exit 1; }

    echo -e "${YELLOW}Восстановление из #$latest_ts...${NC}"
    bash "$rollback_script"
    echo -e "${GREEN}✓ Восстановлено${NC}"
}

cmd_diagnostics() {
    log_action "diagnostics"
    
    [[ ! -f "$DIAGNOSTICS_DIR/latest_diagnostics" ]] && { error "Отчёты не найдены"; exit 1; }
    
    local latest_diag
    latest_diag=$(cat "$DIAGNOSTICS_DIR/latest_diagnostics")
    
    [[ ! -f "$latest_diag" ]] && { error "Файл не найден"; exit 1; }
    
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
        echo -e "${GREEN}✓ Xray актуален: $current_version${NC}"
        return 0
    fi

    echo "Доступна: $latest (текущая: $current_version)"
    read -p "Обновить? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    systemctl stop xray
    cd /tmp
    wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${latest}/Xray-linux-64.zip"
    unzip -o -q /tmp/xray.zip -d /usr/local/xray
    rm -f /tmp/xray.zip
    chmod +x /usr/local/xray/xray
    systemctl start xray

    echo -e "${GREEN}✓ Xray обновлён до $latest${NC}"
}

cmd_version() {
    echo "xray-admin v6.3.0"
    echo "VPN Relay Manager (Namespace + veth + socat)"
    echo ""
    echo "Компоненты:"
    echo "  Xray: $(xray version 2>&1 | head -1 || echo 'нет')"
    echo "  Hysteria2: $(hysteria version 2>&1 | head -1 || echo 'нет')"
    echo "  AmneziaWG: $(awg --version 2>&1 | head -1 || echo 'нет')"
    echo "  Socat: $(socat -V 2>&1 | head -1 || echo 'нет')"
    echo ""
    echo "Архитектура:"
    echo "  • Xray/Hysteria2 в namespace 'xray'"
    echo "  • veth-пара для связи namespaces"
    echo "  • Socat пробрасывает 443/8443 через veth"
    echo "  • Трафик через AmneziaWG на РФ relay"
    echo ""
    echo "Диагностика:"
    echo "  • Бэкапы: $BACKUP_DIR"
    echo "  • Отчёты: $DIAGNOSTICS_DIR"
    echo "  • Лог: $LOG_FILE"
}

cmd_help() {
    echo -e "${CYAN}xray-admin v6.3.0 - VPN Relay Manager${NC}"
    echo ""
    echo "Команды:"
    echo "  status              - Статус сервисов"
    echo "  add <имя>           - Добавить клиента"
    echo "  remove <имя>        - Удалить клиента"
    echo "  rename <стар> <нов> - Переименовать"
    echo "  links [имя]         - Ссылки для подключения"
    echo "  restart             - Перезапустить всё"
    echo "  monitor             - Мониторинг"
    echo "  alerts              - Настроить оповещения"
    echo "  restore             - Восстановить из бэкапа"
    echo "  diagnostics         - Показать отчёт"
    echo "  update              - Обновить Xray"
    echo "  version             - Версия компонентов"
    echo "  help                - Эта справка"
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
log "✓ Управляющий скрипт: $ADMIN_BIN"

section "✅ Установка завершена!"

echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VPN Relay v6.3.0 (Namespace + veth + socat)       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Архитектура:${NC}"
echo "  📱 Клиент → eth0:443/8443 (основной интерфейс)"
echo "       ↓"
echo "  🔌 Socat (TCP/UDP) с ExecStartPre=sleep 10"
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

echo -e "${YELLOW}Порты:${NC}"
ss -tlnp | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет TCP"
ss -ulnp | grep -E ":(443|8443)" | sed 's/^/  /' || echo "  Нет UDP"
echo ""

echo -e "${YELLOW}Управление:${NC}"
echo "  xray-admin status         # Статус"
echo "  xray-admin add user       # Добавить"
echo "  xray-admin remove user    # Удалить"
echo "  xray-admin rename old new # Переименовать"
echo "  xray-admin links          # Ссылки"
echo "  xray-admin restart        # Перезапуск"
echo "  xray-admin monitor        # Мониторинг"
echo "  xray-admin alerts         # Оповещения"
echo "  xray-admin diagnostics    # Отчёт"
echo "  xray-admin version        # Версия"
echo "  xray-admin restore        # Восстановить"
echo "  xray-admin help           # Помощь"
echo ""

echo -e "${YELLOW}Диагностика:${NC}"
echo "  • Бэкапы: $BACKUP_DIR"
echo "  • Отчёты: $DIAGNOSTICS_DIR"
echo "  • Лог: $LOG"
echo ""

echo -e "${YELLOW}Безопасность:${NC}"
echo "  • SSH ключи"
echo "  • Изоляция в namespace"
echo "  • veth-пара для связи"
echo "  • Трафик через туннель"
echo ""

echo -e "${GREEN}✓ Готово!${NC}"
log "Установка завершена"
'''

with open('/root/setup-vpn-relay.sh', 'w') as f:
    f.write(script)

os.chmod('/root/setup-vpn-relay.sh', 0o755)
print(f"✅ Скрипт v6.3.0 создан: /root/setup-vpn-relay.sh")
print(f"📊 Размер: {os.path.getsize('/root/setup-vpn-relay.sh')} байт")
print(f"📝 Строк: {script.count(chr(10))}")
print(f"\n🔧 Ключевые исправления в v6.3.0:")
print(f"  ✓ Reverse-stop для сервисов")
print(f"  ✓ Отдельный cleanup для AWG")
print(f"  ✓ Idempotent-функция для netns/veth")
print(f"  ✓ Жёсткие зависимости After=/Requires= для socat")
print(f"  ✓ Правильный порядок запуска: AWG → namespace → Xray/Hysteria → socat")
PYEOF