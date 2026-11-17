#!/bin/sh
# Установка на VPS с Docker и systemd. Весь блок можно вставить в SSH под root.
# Если файл уже на VPS, запустите «sh amnezia-ru-autoupdate.sh --check» для проверки.
(
set -eu
mode=${1:-install}
case "$mode" in
    install|--check) ;;
    *) echo "Допустимые аргументы: install или --check" >&2; exit 1 ;;
esac
if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите на VPS от root." >&2
    exit 1
fi
for cmd in docker nsenter nft curl flock systemctl; do
    command -v "$cmd" >/dev/null || { echo "Команда $cmd отсутствует." >&2; exit 1; }
done
systemctl show --property=Version >/dev/null
stage=$(mktemp -d /usr/local/sbin/.amnezia-ru.XXXXXX)
trap 'rm -rf "$stage"' EXIT

cat > "$stage/amnezia-ru-restore" <<'WORKER'
#!/bin/sh
set -eu
action=${1:-restore}
config=/etc/amnezia-ru.nft

case "$action" in
    check|update)
        # Скачивание проходит на VPS, одновременно с проверками восстановления.
        tmp=$(mktemp -d /etc/.amnezia-ru.XXXXXX)
        trap 'rm -rf "$tmp"' EXIT
        curl -fsSL --max-time 30 \
            https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone \
            -o "$tmp/ru4"
        curl -fsSL --max-time 30 \
            https://www.ipdeny.com/ipv6/ipaddresses/aggregated/ru-aggregated.zone \
            -o "$tmp/ru6"

        if [ ! -s "$tmp/ru4" ] || [ ! -s "$tmp/ru6" ]; then
            echo "IPdeny вернул пустой список." >&2
            exit 1
        fi
        if grep -qEv '^[0-9.]+/[1-9][0-9]?$' "$tmp/ru4" ||
           grep -qEv '^[0-9A-Fa-f:]+/[1-9][0-9]?[0-9]?$' "$tmp/ru6"; then
            echo "Неожиданный формат подсетей IPdeny." >&2
            exit 1
        fi
        ru4=$(paste -sd, "$tmp/ru4")
        ru6=$(paste -sd, "$tmp/ru6")
        cat > "$tmp/filter.nft" <<NFT
add table inet amnezia_ru
delete table inet amnezia_ru
table inet amnezia_ru {
    set ru4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { $ru4 }
    }
    set ru6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { $ru6 }
    }
    chain forward {
        type filter hook forward priority -10; policy accept;
        iifname "awg0" ip daddr @ru4 counter reject
        iifname "awg0" ip6 daddr @ru6 counter reject
    }
}
NFT
        chmod 0600 "$tmp/filter.nft"
        ;;
    restore) ;;
    *) echo "Неизвестное действие: $action" >&2; exit 1 ;;
esac

# Фиксируем сеть текущего контейнера только после скачивания списков.
exec 9>/run/lock/amnezia-ru.lock
flock -x 9
netns=$(docker inspect -f '{{if .State.Running}}{{.NetworkSettings.SandboxKey}}{{end}}' amnezia-awg2) || netns=
if [ -z "$netns" ] || [ ! -e "$netns" ]; then
    [ "$action" = restore ] && exit 0
    echo "Сеть контейнера amnezia-awg2 сейчас недоступна." >&2
    exit 1
fi
exec 8<"$netns"
if [ /proc/self/fd/8 -ef /proc/self/ns/net ]; then
    echo "У контейнера общая сеть с VPS. Требуется отдельная сеть Docker." >&2
    exit 1
fi
vpn_nft() { nsenter --net=/proc/self/fd/8 -- nft "$@"; }

case "$action" in
    restore)
        if ! vpn_nft list chain inet amnezia_ru forward >/dev/null 2>&1; then
            vpn_nft -f "$config"
        fi
        ;;
    check|update)
        vpn_nft -c -f "$tmp/filter.nft"
        if [ "$action" = check ]; then
            echo "Проверка пройдена: новые списки и правила приняты nft -c."
            exit 0
        fi
        vpn_nft -f "$tmp/filter.nft"
        # Временный файл лежит на той же файловой системе, что и сохранённые правила.
        mv -f "$tmp/filter.nft" "$config"
        echo "Списки RU IPv4 и IPv6 обновлены."
        ;;
esac
WORKER
chmod 0755 "$stage/amnezia-ru-restore"
sh -n "$stage/amnezia-ru-restore"
if [ "$mode" = --check ]; then
    "$stage/amnezia-ru-restore" check
    exit 0
fi

cat > "$stage/amnezia-ru.service" <<'UNIT'
[Unit]
Description=Restore Amnezia RU destination filter
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/amnezia-ru-restore
UNIT

cat > "$stage/amnezia-ru.timer" <<'UNIT'
[Unit]
Description=Check Amnezia RU destination filter

[Timer]
OnActiveSec=1s
OnUnitInactiveSec=10s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

cat > "$stage/amnezia-ru-update.service" <<'UNIT'
[Unit]
Description=Refresh Amnezia RU IP lists
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/amnezia-ru-restore update
UNIT

cat > "$stage/amnezia-ru-update.timer" <<'UNIT'
[Unit]
Description=Refresh Amnezia RU IP lists daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT

mv -f "$stage/amnezia-ru-restore" /usr/local/sbin/amnezia-ru-restore
install -m 0644 "$stage/"*.service "$stage/"*.timer /etc/systemd/system/
systemctl daemon-reload
if ! systemctl start amnezia-ru-update.service; then
    journalctl -u amnezia-ru-update.service -n 12 --no-pager >&2
    exit 1
fi
systemctl start amnezia-ru.service
systemctl enable --now amnezia-ru.timer amnezia-ru-update.timer
systemctl list-timers --all 'amnezia-ru*' --no-pager
echo "Готово. Списки обновлены, оба таймера включены."
)
