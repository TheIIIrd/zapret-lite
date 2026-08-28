#!/bin/sh
# Проверка zapret-lite на настоящей машине.
# shellcheck disable=SC1091,SC2015  # os-release читается в рантайме;
#   ok/bad не падают, поэтому A && B || C здесь безопасно
#
# Автоматизирует механическую часть: снимки firewall до и после, установку,
# диагностику, откат, удаление и сверку. То, что требует глаз и живой сети
# - работает ли обход - остаётся за вами; скрипт про это честно скажет.
#
#   sudo ./tests/vm-check.sh /путь/к/распакованному/комплекту
#
# Скрипт СТАВИТ И УДАЛЯЕТ zapret по-настоящему. Делайте снимок ВМ заранее.

set -eu

PKG="${1:-}"
WORK=/tmp/zapret-lite-check
PASS=0
FAIL=0
SKIP=0

ok()   { printf '  [ + ] %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  [ - ] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  [ ~ ] %s\n' "$*"; SKIP=$((SKIP + 1)); }
step() { printf '\n=== %s\n' "$*"; }

[ -n "$PKG" ] || { echo "укажите каталог комплекта: $0 <путь>" >&2; exit 1; }
[ -f "$PKG/install.sh" ] || { echo "в $PKG нет install.sh" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }

printf 'Скрипт установит и удалит zapret на этой машине.\n'
printf 'Снимок ВМ сделан? Продолжить [y/N]: '
read -r answer
case "$answer" in y|Y|yes|да) ;; *) echo "отменено"; exit 0 ;; esac

mkdir -p "$WORK"

# =====================================================================
step "Окружение"
# =====================================================================

. /etc/os-release 2>/dev/null || true
printf '  дистрибутив : %s\n' "${PRETTY_NAME:-неизвестно}"
printf '  ядро        : %s\n' "$(uname -r)"
printf '  архитектура : %s\n' "$(uname -m)"
printf '  /bin/sh     : %s\n' "$(readlink -f /bin/sh)"

# На Debian и производных /bin/sh это dash. Весь shell-код писался под
# него, но проверить это стоит на месте.
if [ "$(basename "$(readlink -f /bin/sh)")" = dash ]; then
	ok "/bin/sh это dash - как и предполагалось"
else
	skip "/bin/sh не dash; код рассчитан на dash, но должен работать"
fi

for f in "$PKG/install.sh" "$PKG/uninstall.sh" "$PKG/bin/zapret-lite" \
         "$PKG/lib/common.sh"; do
	if sh -n "$f" 2>/dev/null; then :; else bad "синтаксис: $f"; fi
done
ok "синтаксис скриптов принят системным /bin/sh"

if [ -d /run/systemd/system ]; then ok "systemd работает"; else bad "нет systemd"; fi

# =====================================================================
step "Снимок состояния ДО установки"
# =====================================================================

iptables-save  >"$WORK/ipt.before"  2>/dev/null || : >"$WORK/ipt.before"
ip6tables-save >"$WORK/ipt6.before" 2>/dev/null || : >"$WORK/ipt6.before"
nft list ruleset >"$WORK/nft.before" 2>/dev/null || : >"$WORK/nft.before"
systemctl list-unit-files --no-legend >"$WORK/units.before" 2>/dev/null || true

printf '  iptables  : %s строк\n' "$(wc -l <"$WORK/ipt.before")"
printf '  ip6tables : %s строк\n' "$(wc -l <"$WORK/ipt6.before")"
printf '  nftables  : %s строк\n' "$(wc -l <"$WORK/nft.before")"

if [ -s "$WORK/ipt.before" ] || [ -s "$WORK/nft.before" ]; then
	printf '  У вас уже есть правила firewall. Именно этот случай и важно\n'
	printf '  проверить: после удаления они должны остаться нетронутыми.\n'
fi

# =====================================================================
step "Установка"
# =====================================================================

if ( cd "$PKG" && sh ./install.sh --dry-run >"$WORK/dryrun.log" 2>&1 ); then
	ok "--dry-run отработал"
else
	bad "--dry-run завершился с ошибкой (см. $WORK/dryrun.log)"
fi

if ( cd "$PKG" && sh ./install.sh >"$WORK/install.log" 2>&1 ); then
	ok "установка завершилась успешно"
else
	bad "установка провалилась (см. $WORK/install.log)"
	tail -15 "$WORK/install.log" | sed 's/^/      /'
	exit 1
fi

grep -q 'комплект цел' "$WORK/install.log" \
	&& ok "манифест комплекта проверен" \
	|| skip "манифест не проверялся (установка из дерева репозитория)"

[ -x /usr/local/bin/zapret-lite ] \
	&& ok "менеджер установлен" || bad "нет /usr/local/bin/zapret-lite"

[ -x /opt/zapret/nfq/nfqws ] \
	&& ok "nfqws на месте: $(/opt/zapret/nfq/nfqws --version 2>&1 | head -1)" \
	|| bad "нет исполняемого /opt/zapret/nfq/nfqws"

# =====================================================================
step "Служба"
# =====================================================================

if systemctl is-active --quiet zapret; then
	ok "служба активна"
else
	bad "служба не активна"
	journalctl -u zapret -n 20 --no-pager | sed 's/^/      /'
fi

systemctl is-enabled --quiet zapret \
	&& ok "автозапуск включён" || bad "автозапуск не включён"

# Drop-in должен применяться, иначе наши настройки просто не действуют.
if systemctl show zapret -p Restart --value | grep -q 'on-failure\|always'; then
	ok "drop-in применён (Restart=$(systemctl show zapret -p Restart --value))"
else
	bad "drop-in не применился: Restart=$(systemctl show zapret -p Restart --value)"
fi

if pgrep -x nfqws >/dev/null 2>&1; then
	ok "процесс nfqws запущен ($(pgrep -cx nfqws) шт.)"
else
	bad "процесс nfqws не найден"
fi

if systemctl is-active --quiet zapret-lite-check-update.timer; then
	ok "таймер проверки обновлений активен"
else
	skip "таймер проверки обновлений не активен"
fi

# =====================================================================
step "Правила firewall появились"
# =====================================================================

iptables-save >"$WORK/ipt.during" 2>/dev/null || : >"$WORK/ipt.during"
nft list ruleset >"$WORK/nft.during" 2>/dev/null || : >"$WORK/nft.during"

# nftables печатает правило как "queue flags bypass to 200", а
# iptables - как "NFQUEUE num 200 bypass". Искать надо оба варианта:
# первая версия проверки давала ложную тревогу на работающей системе.
if grep -qiE 'queue (flags [a-z,]+ )?to [0-9]+|NFQUEUE' \
     "$WORK/ipt.during" "$WORK/nft.during" 2>/dev/null; then
	ok "правила с NFQUEUE появились"
else
	bad "правил с NFQUEUE не видно - трафик до nfqws не доходит"
fi

# =====================================================================
step "Диагностика"
# =====================================================================

if zapret-lite doctor >"$WORK/doctor.log" 2>&1; then
	ok "doctor не нашёл проблем"
else
	bad "doctor нашёл проблемы:"
	grep '\[ - \]' "$WORK/doctor.log" | sed 's/^/      /'
fi
grep '\[ ! \]' "$WORK/doctor.log" | sed 's/^/      предупреждение: /' || true

zapret-lite status >"$WORK/status.log" 2>&1 \
	&& ok "status отработал" || bad "status завершился с ошибкой"

# =====================================================================
step "Смена стратегии"
# =====================================================================

first=$(zapret-lite list | sed -n '2s/^[* ]*//p')
if [ -n "$first" ]; then
	if zapret-lite use "$first" >"$WORK/use.log" 2>&1; then
		ok "переключение на '$first' прошло"
		systemctl is-active --quiet zapret \
			&& ok "служба пережила смену стратегии" \
			|| bad "служба не поднялась после смены стратегии"
	else
		bad "переключение стратегии не удалось"
	fi
else
	skip "не удалось определить вторую стратегию"
fi

# =====================================================================
step "Переключатели без перезапуска"
# =====================================================================

before_pid=$(pgrep -x nfqws | head -1 || true)
zapret-lite ipset none >/dev/null 2>&1 || bad "ipset none не сработал"
after_pid=$(pgrep -x nfqws | head -1 || true)
if [ -n "$before_pid" ] && [ "$before_pid" = "$after_pid" ]; then
	ok "смена режима ipset не перезапустила nfqws (как и задумано)"
else
	skip "PID nfqws изменился или не определён"
fi
zapret-lite ipset loaded >/dev/null 2>&1 || bad "возврат ipset loaded не сработал"

# =====================================================================
step "Удаление и симметрия"
# =====================================================================

if ( cd "$PKG" && sh ./uninstall.sh >"$WORK/uninstall.log" 2>&1 ); then
	ok "удаление завершилось успешно"
else
	bad "удаление провалилось (см. $WORK/uninstall.log)"
fi

iptables-save  >"$WORK/ipt.after"  2>/dev/null || : >"$WORK/ipt.after"
ip6tables-save >"$WORK/ipt6.after" 2>/dev/null || : >"$WORK/ipt6.after"
nft list ruleset >"$WORK/nft.after" 2>/dev/null || : >"$WORK/nft.after"

# Счётчики пакетов меняются сами по себе, поэтому сравниваем без них.
strip_counters() {
	sed -e 's/\[[0-9]*:[0-9]*\]//g' -e 's/counter packets [0-9]* bytes [0-9]*//g' "$1"
}

for pair in ipt:iptables ipt6:ip6tables nft:nftables; do
	f="${pair%%:*}"; label="${pair##*:}"
	if strip_counters "$WORK/$f.before" >"$WORK/$f.b" &&
	   strip_counters "$WORK/$f.after"  >"$WORK/$f.a" &&
	   diff -q "$WORK/$f.b" "$WORK/$f.a" >/dev/null; then
		ok "$label: состояние вернулось к исходному"
	else
		bad "$label: остались отличия"
		diff -u "$WORK/$f.b" "$WORK/$f.a" | head -25 | sed 's/^/      /'
	fi
done

if nft list table inet zapret >/dev/null 2>&1; then
	bad "таблица inet zapret осталась после удаления"
else
	ok "таблица inet zapret удалена"
fi

[ -d /opt/zapret ]      && bad "/opt/zapret не удалён"      || ok "/opt/zapret удалён"
[ -d /opt/zapret-lite ] && bad "/opt/zapret-lite не удалён" || ok "/opt/zapret-lite удалён"
[ -d /etc/zapret-lite ] && ok "/etc/zapret-lite сохранён (это правильно)" \
                        || bad "/etc/zapret-lite удалён без --purge"

if systemctl list-unit-files --no-legend >"$WORK/units.after" 2>/dev/null; then
	if diff -q "$WORK/units.before" "$WORK/units.after" >/dev/null; then
		ok "список юнитов вернулся к исходному"
	else
		bad "остались изменения в юнитах:"
		diff "$WORK/units.before" "$WORK/units.after" | head -10 | sed 's/^/      /'
	fi
fi

# =====================================================================
step "Итог"
# =====================================================================

printf '  успешно: %s, провалов: %s, пропущено: %s\n' "$PASS" "$FAIL" "$SKIP"
printf '  логи и снимки: %s\n' "$WORK"

cat <<'EOF'

  Скрипт НЕ проверял главное - работает ли обход блокировок. Это видно
  только на живой сети: откройте в браузере то, что было заблокировано.

  Если не работает, перебирайте стратегии - провайдеры блокируют
  по-разному, и подходящая находится только опытом:

    zapret-lite list
    sudo zapret-lite use general-alt2

EOF

[ "$FAIL" = 0 ] || exit 1
