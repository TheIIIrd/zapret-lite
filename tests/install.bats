#!/usr/bin/env bats
# Установка, идемпотентность, поколения, откат.

load helper

setup() {
	setup_root
	PKG_A="$BATS_TEST_TMPDIR/pkg-a"
	PKG_B="$BATS_TEST_TMPDIR/pkg-b"
	build_pkg "$PKG_A" 1.10.0 72.12
}

# --- установка --------------------------------------------------------

@test "установка создаёт поколение и переключает current" {
	run install_pkg "$PKG_A" --strategy general-alt11
	[ "$status" -eq 0 ]
	[ -L "$ZL_PREFIX/opt/zapret-lite/current" ]
	[ -d "$ZL_PREFIX/opt/zapret-lite/current/strategies" ]
	[ "$(gen_count)" -eq 1 ]
}

@test "конфиг загружается и все пути из него существуют" {
	install_pkg "$PKG_A" --strategy general-alt11
	run load_config 'set -- $NFQWS_OPT
		miss=0
		for a in "$@"; do
			case "$a" in *=/*) p=${a#*=}; [ -e "$p" ] || miss=$((miss+1));; esac
		done
		echo "args=$# missing=$miss"'
	[ "$status" -eq 0 ]
	[[ "$output" == *"missing=0"* ]]
	[[ "$output" != *"args=0"* ]]
}

@test "выбранная стратегия попадает в конфиг" {
	install_pkg "$PKG_A" --strategy general-alt5
	# ALT5 отличается числом профилей от остальных - хороший маркер.
	run load_config 'echo "$NFQWS_ENABLE"'
	[ "$output" = "1" ]
	run zl status
	[[ "$output" == *"general-alt5"* ]]
}

@test "несуществующая стратегия отвергается с подсказкой" {
	run install_pkg "$PKG_A" --strategy нет-такой
	[ "$status" -ne 0 ]
	[[ "$output" == *"недопустимое имя"* ]] || [[ "$output" == *"нет стратегии"* ]]
}

@test "битый комплект не устанавливается" {
	printf 'X' >>"$PKG_A/vendor/flowseal/fake/stun.bin"
	run install_pkg "$PKG_A"
	[ "$status" -ne 0 ]
	[[ "$output" == *"манифест"* ]]
}

# --- идемпотентность --------------------------------------------------

@test "повторная установка не трогает пользовательские файлы" {
	install_pkg "$PKG_A" --strategy general-alt11
	echo "мой.домен" >>"$ZL_PREFIX/etc/zapret-lite/lists/list-general-user.txt"
	echo "FWTYPE=iptables" >>"$ZL_PREFIX/etc/zapret-lite/local.conf"

	install_pkg "$PKG_A"

	grep -q "мой.домен" "$ZL_PREFIX/etc/zapret-lite/lists/list-general-user.txt"
	grep -q "FWTYPE=iptables" "$ZL_PREFIX/etc/zapret-lite/local.conf"
}

@test "повторная установка того же релиза не плодит поколения" {
	install_pkg "$PKG_A"
	install_pkg "$PKG_A"
	[ "$(gen_count)" -eq 1 ]
}

@test "режимы ipset и game-filter переживают переустановку" {
	install_pkg "$PKG_A"
	zl ipset any
	zl game-filter all
	install_pkg "$PKG_A"

	run zl status
	[[ "$output" == *"Режим ipset   : any"* ]]
	[[ "$output" == *"Игровой фильтр: all"* ]]
}

# --- обновление и откат -----------------------------------------------

@test "обновление сохраняет выбранную стратегию" {
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A" --strategy general-alt11
	install_pkg "$PKG_B"

	run zl status
	[[ "$output" == *"Стратегия     : general-alt11"* ]]
}

@test "обновление делает старое поколение предыдущим" {
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A"
	install_pkg "$PKG_B"

	[ "$(gen_count)" -eq 2 ]
	run zl status
	[[ "$output" == *"flowseal-1.10.2"* ]]
	[[ "$output" == *"Предыдущее    : "*"flowseal-1.10.0"* ]]
}

@test "откат возвращает предыдущее поколение и пересобирает ipset-all" {
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A"
	before=$(wc -l <"$ZL_PREFIX/etc/zapret-lite/lists/ipset-all.txt")
	install_pkg "$PKG_B"
	after=$(wc -l <"$ZL_PREFIX/etc/zapret-lite/lists/ipset-all.txt")
	[ "$before" -ne "$after" ]

	run zl rollback
	[ "$status" -eq 0 ]
	rolled=$(wc -l <"$ZL_PREFIX/etc/zapret-lite/lists/ipset-all.txt")
	[ "$rolled" -eq "$before" ]
}

@test "откат не трогает пользовательские списки" {
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A"
	echo "мой.домен" >>"$ZL_PREFIX/etc/zapret-lite/lists/list-general-user.txt"
	install_pkg "$PKG_B"
	zl rollback

	grep -q "мой.домен" "$ZL_PREFIX/etc/zapret-lite/lists/list-general-user.txt"
}

@test "откат предупреждает, если стратегии нет в старом поколении" {
	# general-alt13 появилась только в 1.10.2
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A"
	install_pkg "$PKG_B"
	zl use general-alt13

	run zl rollback
	[[ "$output" == *"general-alt13"* ]]
	[[ "$output" == *"нет в поколении"* ]]
}

@test "конфиг отключает nfqws, если стратегия недоступна" {
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A"
	install_pkg "$PKG_B"
	zl use general-alt13
	zl rollback || true

	run load_config 'echo "enable=$NFQWS_ENABLE"'
	[[ "$output" == *"enable=0"* ]]
}

@test "повреждённое поколение не становится текущим" {
	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_A"
	install_pkg "$PKG_B"
	prev=$(readlink -f "$ZL_PREFIX/opt/zapret-lite/previous")
	echo X >>"$prev/lists/list-google.txt"

	run zl rollback
	[ "$status" -ne 0 ]
	run zl status
	[[ "$output" == *"flowseal-1.10.2"* ]]
}

@test "ротация оставляет заданное число поколений" {
	install_pkg "$PKG_A"
	versions="$ZL_PREFIX/opt/zapret-lite/versions"
	src=$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")
	for d in 2020-01-01 2020-02-02 2020-03-03; do
		cp -r "$src" "$versions/${d}_flowseal-x_zapret-0"
	done
	[ "$(gen_count)" -eq 4 ]

	build_pkg "$PKG_B" 1.10.2 72.13
	install_pkg "$PKG_B"
	[ "$(gen_count)" -le 3 ]
	# current и previous обязаны уцелеть
	[ -d "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")" ]
	[ -d "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/previous")" ]
}
