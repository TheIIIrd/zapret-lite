#!/bin/sh
# Проверка настоящих правил firewall в изолированном сетевом namespace.
#
# Единственный класс дефектов, который нельзя поймать без прав на сеть:
# правила применяются, но не снимаются. Именно на нём проект спотыкался
# трижды - осиротевшая таблица nft, смена типа firewall, выключение IPv6
# в режиме iptables.
#
# Всё происходит внутри "ip netns", поэтому сеть машины не затрагивается:
# у namespace свой netfilter, свои очереди и свои интерфейсы.
#
#   sudo ./tests/firewall-netns.sh <префикс-установки>
#
# Префикс - каталог, куда уже установлен zapret-lite (ZL_PREFIX).

set -eu

PREFIX="${1:-}"
NS=zapret-lite-test
FAIL=0

ok()  { printf '  [ + ] %s\n' "$*"; }
bad() { printf '  [ - ] %s\n' "$*"; FAIL=$((FAIL + 1)); }

[ -n "$PREFIX" ] || { echo "укажите префикс установки" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "нужен root: создаётся сетевой namespace" >&2; exit 1; }
[ -x "$PREFIX/opt/zapret/init.d/sysv/zapret" ] \
	|| { echo "в $PREFIX нет установленного zapret" >&2; exit 1; }

ZAPRET_BASE="$PREFIX/opt/zapret"
ZAPRET_CONFIG="$ZAPRET_BASE/config"
export ZAPRET_BASE ZAPRET_CONFIG

ETC="$PREFIX/etc/zapret-lite"

cleanup() {
	ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null || true
	ip netns del "$NS" 2>/dev/null || true
}
trap cleanup EXIT

ns_reset() {
	cleanup
	ip netns add "$NS"
	ip netns exec "$NS" ip link set lo up
}

zapret_do() {
	# $1 - start | stop
	timeout 180 ip netns exec "$NS" \
		sh "$ZAPRET_BASE/init.d/sysv/zapret" "$1" >/dev/null 2>&1 || true
}

nft_chains()  { timeout 60 ip netns exec "$NS" nft -t list table inet zapret 2>/dev/null | grep -c 'chain ' || true; }
ipt_rules()   { timeout 60 ip netns exec "$NS" iptables-save 2>/dev/null | grep -c NFQUEUE || true; }
ipt6_rules()  { timeout 60 ip netns exec "$NS" ip6tables-save 2>/dev/null | grep -c NFQUEUE || true; }

set_state() { printf '%s\n' "$2" >"$ETC/$1"; }

# Список из 32 тысяч подсетей грузится в набор десятки секунд и к делу
# не относится: проверяются правила, а не содержимое списков.
set_state ipset.mode none
printf '203.0.113.113/32\n' >"$ETC/lists/ipset-all.txt"

# =====================================================================
printf '\n=== nftables\n'
# =====================================================================
set_state fwtype nftables
set_state ipv6.mode off
ns_reset

[ "$(nft_chains)" = 0 ] && ok "до старта цепочек нет" || bad "namespace не чист"

zapret_do start
n=$(nft_chains)
[ "$n" -gt 0 ] && ok "правила применились ($n цепочек)" || bad "правила не появились"

zapret_do stop
n=$(nft_chains)
[ "$n" = 0 ] && ok "правила сняты полностью" || bad "осталось цепочек: $n"

# =====================================================================
printf '\n=== iptables\n'
# =====================================================================
# Путь, которым пользуются там, где правила уже живут в iptables -
# например, рядом с WireGuard. Требует пакета ipset.
if command -v ipset >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
	set_state fwtype iptables
	set_state ipv6.mode off
	ns_reset

	zapret_do start
	n=$(ipt_rules)
	[ "$n" -gt 0 ] && ok "правила применились ($n правил NFQUEUE)" \
	                || bad "правила не появились"

	zapret_do stop
	n=$(ipt_rules)
	[ "$n" = 0 ] && ok "правила сняты полностью" || bad "осталось правил: $n"
else
	printf '  [ ~ ] пропущено: нет iptables или ipset\n'
fi

# =====================================================================
printf '\n=== IPv6 в режиме iptables\n'
# =====================================================================
# Здесь проект уже ошибался. В режиме iptables снятие правил IPv6 идёт
# через тот же DISABLE_IPV6, что и установка (common/ipt.sh:413).
# Поэтому переключать значение можно только при остановленной службе:
# иначе снимаются не те правила, что ставились.
if command -v ipset >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
	set_state fwtype iptables
	set_state ipv6.mode on
	ns_reset

	zapret_do start
	n=$(ipt6_rules)
	[ "$n" -gt 0 ] && ok "правила IPv6 применились ($n)" \
	                || bad "правила IPv6 не появились"

	# Правильный порядок: остановка тем же конфигом, каким ставили.
	zapret_do stop
	n=$(ipt6_rules)
	[ "$n" = 0 ] && ok "правила IPv6 сняты полностью" \
	             || bad "осталось правил IPv6: $n"

	# И показываем, почему порядок важен: если поменять значение до
	# остановки, правила осиротеют. Тест закрепляет, что обходной путь
	# в zl_switch_state всё ещё нужен.
	ns_reset
	set_state ipv6.mode on
	zapret_do start
	set_state ipv6.mode off
	zapret_do stop
	n=$(ipt6_rules)
	if [ "$n" -gt 0 ]; then
		ok "подтверждено: смена значения до остановки оставляет $n правил"
		ok "поэтому zl_switch_state останавливает службу первой"
	else
		printf '  [ ~ ] апстрим больше не зависит от DISABLE_IPV6 при снятии;\n'
		printf '        обходной путь в zl_switch_state можно пересмотреть\n'
	fi
else
	printf '  [ ~ ] пропущено: нет ip6tables или ipset\n'
fi

printf '\n=== Итог\n'
if [ "$FAIL" = 0 ]; then
	printf '  правила применяются и снимаются симметрично\n'
	exit 0
fi
printf '  провалов: %s\n' "$FAIL"
exit 1
