#!/bin/sh
(
  set -e
  dir=/etc/systemd/system

  for name in amnezia-ru amnezia-ru-update; do
    if [ -f "$dir/$name.timer" ]; then systemctl stop "$name.timer"; fi
    if [ -f "$dir/$name.service" ]; then systemctl stop "$name.service"; fi
    rm -f "$dir/$name.timer" "$dir/$name.service" \
          "$dir/timers.target.wants/$name.timer" "/var/lib/systemd/timers/stamp-$name.timer"
  done

  rm -f /usr/local/sbin/amnezia-ru-restore /etc/amnezia-ru.nft \
        /run/lock/amnezia-ru.lock /root/amnezia-ru-autoupdate.sh
  systemctl daemon-reload
  echo 'Файлы и автозапуск удалены. Для снятия действующего фильтра перезагрузи VPS командой reboot.'
)
