#!/usr/bin/env bats
# Конвертер стратегий: правила перевода и проверки, которые валят сборку.
#
# Мутационное тестирование показало, что раньше конвертер не был покрыт
# вовсе: можно было убрать снятие экранирования, проверку существования
# файлов и сверку портов - и вся остальная сборка оставалась зелёной.

setup_file() {
	REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	export REPO
}

setup() {
	REL="$BATS_TEST_TMPDIR/rel"
	OUT="$BATS_TEST_TMPDIR/out"
	mkdir -p "$REL/bin" "$REL/lists" "$OUT"
	printf 'fake\n' >"$REL/bin/tls.bin"
	printf 'fake\n' >"$REL/bin/quic.bin"
	printf 'example.com\n' >"$REL/lists/list-general.txt"
}

# Собирает .bat так же, как это делает flowseal: строка запуска winws
# с переносами через ^ в конце строки.
mkbat() {
	# $1 - имя, далее строки аргументов
	local name="$1"; shift
	{
		printf 'start "zapret" /min "%%~dp0bin\\winws.exe" ^\n'
		local n=$# i=0
		for a in "$@"; do
			i=$((i + 1))
			if [ "$i" -lt "$n" ]; then printf '%s ^\n' "$a"; else printf '%s\n' "$a"; fi
		done
	} >"$REL/$name.bat"
}

convert() {
	python3 "$REPO/tools/import-strategies.py" "$REL" "$OUT"
}

# --- перевод синтаксиса -----------------------------------------------

@test "экранирование cmd снимается" {
	# В 'general (FAKE TLS AUTO)' записано --dpi-desync-fake-tls=^!
	# Это экранированный '!', а не значение '^!'. Наивный конвертер
	# сгенерировал бы мусор молча.
	mkbat s --wf-tcp=443 '--filter-tcp=443 --dpi-desync-fake-tls=^!'
	run convert
	[ "$status" -eq 0 ]
	grep -q -- '--dpi-desync-fake-tls=!' "$OUT/s.conf"
	! grep -q -- '\^!' "$OUT/s.conf"
}

@test "пути %BIN% и %LISTS% заменяются переменными" {
	mkbat s --wf-tcp=443 \
		'--filter-tcp=443 --hostlist=%LISTS%list-general.txt --dpi-desync-fake-tls=%BIN%tls.bin'
	run convert
	[ "$status" -eq 0 ]
	grep -q -- '--hostlist=$ZAPRET_LISTS_DIR/list-general.txt' "$OUT/s.conf"
	grep -q -- '--dpi-desync-fake-tls=$ZAPRET_FAKE_DIR/tls.bin' "$OUT/s.conf"
}

@test "пользовательские списки уезжают в локальный каталог" {
	# Вендорный каталог заменяется целиком при синхронизации, поэтому
	# файлы пользователя обязаны лежать отдельно.
	mkbat s --wf-tcp=443 \
		'--filter-tcp=443 --hostlist=%LISTS%list-general.txt --hostlist=%LISTS%list-general-user.txt'
	run convert
	[ "$status" -eq 0 ]
	grep -q -- '--hostlist=$ZAPRET_LISTS_DIR/list-general.txt' "$OUT/s.conf"
	grep -q -- '--hostlist=$ZAPRET_LOCAL_LISTS_DIR/list-general-user.txt' "$OUT/s.conf"
}

@test "порты из --wf-* становятся NFQWS_PORTS_*" {
	mkbat s --wf-tcp=80,443,2053 --wf-udp=443,50000-50100 '--filter-tcp=80 --dpi-desync=fake'
	run convert
	[ "$status" -eq 0 ]
	grep -q 'NFQWS_PORTS_TCP="80,443,2053"' "$OUT/s.conf"
	grep -q 'NFQWS_PORTS_UDP="443,50000-50100"' "$OUT/s.conf"
}

@test "игровой фильтр становится shell-переменной" {
	mkbat s '--wf-tcp=443,%GameFilterTCP%' '--wf-udp=443,%GameFilterUDP%' \
		'--filter-tcp=443 --dpi-desync=fake'
	run convert
	[ "$status" -eq 0 ]
	grep -q 'NFQWS_PORTS_TCP="443,\$GAME_FILTER_TCP"' "$OUT/s.conf"
	grep -q 'NFQWS_PORTS_UDP="443,\$GAME_FILTER_UDP"' "$OUT/s.conf"
}

@test "профили разделяются --new и сохраняют порядок" {
	mkbat s --wf-tcp=80,443 \
		'--filter-tcp=80 --dpi-desync=fake --new' \
		'--filter-tcp=443 --dpi-desync=disorder'
	run convert
	[ "$status" -eq 0 ]
	grep -q -- '--filter-tcp=80 --dpi-desync=fake --new' "$OUT/s.conf"
	grep -q -- '--filter-tcp=443 --dpi-desync=disorder' "$OUT/s.conf"
}

@test "имя файла превращается в слаг" {
	mkbat 'general (ALT11)' --wf-tcp=443 '--filter-tcp=443 --dpi-desync=fake'
	run convert
	[ "$status" -eq 0 ]
	[ -f "$OUT/general-alt11.conf" ]
}

# --- проверки, которые обязаны валить сборку --------------------------

@test "ссылка на несуществующий .bin валит сборку" {
	# Ровно так в чужом форке выжила ссылка на файл, удалённый из
	# апстрима двумя релизами ранее.
	mkbat s --wf-tcp=443 '--filter-tcp=443 --dpi-desync-fake-tls=%BIN%нет-такого.bin'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"отсутствующий файл"* ]]
}

@test "опечатка в имени файла валит сборку" {
	# В том же форке было ACTIVE_DISCORD_UDP.binn - лишняя буква.
	mkbat s --wf-tcp=443 '--filter-tcp=443 --dpi-desync-fake-tls=%BIN%tls.binn'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"отсутствующий файл"* ]]
}

@test "ссылка на несуществующий список валит сборку" {
	mkbat s --wf-tcp=443 '--filter-tcp=443 --hostlist=%LISTS%нет-списка.txt'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"отсутствующий файл"* ]]
}

@test "порт вне --wf-tcp валит сборку" {
	# Из-за такого расхождения в чужом форке профиль discord.media был
	# мёртв: трафик на эти порты firewall не заворачивал.
	mkbat s --wf-tcp=80,443 '--filter-tcp=2053,8443 --dpi-desync=fake'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"2053"* ]]
	[[ "$output" == *"не заворачиваются"* ]]
}

@test "порт вне --wf-udp валит сборку" {
	mkbat s --wf-udp=443 '--filter-udp=19294 --dpi-desync=fake'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"19294"* ]]
}

@test "порт внутри диапазона --wf-* принимается" {
	mkbat s --wf-udp=443,50000-50100 '--filter-udp=50050 --dpi-desync=fake'
	run convert
	[ "$status" -eq 0 ]
}

@test "неизвестная опция nfqws валит сборку" {
	mkbat s --wf-tcp=443 '--filter-tcp=443 --такой-опции-нет=1'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"неизвестная опция"* ]]
}

@test "опция, при которой nfqws пишет в файл, валит сборку" {
	# Каталог поколения неизменяем: запись туда сломала бы его манифест.
	mkbat s --wf-tcp=443 '--filter-tcp=443 --hostlist-auto=%LISTS%auto.txt'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"писать в файл"* ]]
}

@test "одна битая стратегия валит всю сборку, а не пропускается" {
	mkbat ok1 --wf-tcp=443 '--filter-tcp=443 --dpi-desync=fake'
	mkbat bad --wf-tcp=443 '--filter-tcp=443 --dpi-desync-fake-tls=%BIN%нет.bin'
	run convert
	[ "$status" -ne 0 ]
	[[ "$output" == *"Итог: 1 из 2"* ]]
}

@test "service.bat не конвертируется" {
	mkbat service --wf-tcp=443 '--filter-tcp=443 --dpi-desync=fake'
	mkbat s --wf-tcp=443 '--filter-tcp=443 --dpi-desync=fake'
	run convert
	[ "$status" -eq 0 ]
	[ ! -f "$OUT/service.conf" ]
	[ -f "$OUT/s.conf" ]
}

# --- результат пригоден к употреблению --------------------------------

@test "сгенерированный конфиг читается shell-ом" {
	mkbat s --wf-tcp=80,443 --wf-udp=443 \
		'--filter-tcp=80 --hostlist=%LISTS%list-general.txt --dpi-desync=fake --new' \
		'--filter-udp=443 --dpi-desync-fake-quic=%BIN%quic.bin'
	convert
	run dash -c '
		ZAPRET_FAKE_DIR=/f ZAPRET_LISTS_DIR=/l ZAPRET_LOCAL_LISTS_DIR=/u
		GAME_FILTER_TCP=12 GAME_FILTER_UDP=12
		. '"$OUT"'/s.conf
		[ "$NFQWS_ENABLE" = 1 ] || exit 1
		set -- $NFQWS_OPT
		[ $# -gt 5 ] || exit 2
		echo "ARGS=$#"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"ARGS="* ]]
}

# --- формат списков ---------------------------------------------------

@test "vendor-sync приводит списки к LF, а .bin не трогает" {
	# Два пути синхронизации брали списки из разных мест: релиз даёт
	# CRLF, main через raw.githubusercontent - LF. Из-за этого после
	# каждого релиза списки переворачивались, и PR показывал изменение
	# всех 32 тысяч строк.
	local rel="$BATS_TEST_TMPDIR/rel2" out="$BATS_TEST_TMPDIR/vendor2"
	mkdir -p "$rel/bin" "$rel/lists"
	printf 'a.example\r\nb.example\r\n' >"$rel/lists/list-general.txt"
	printf '1.2.3.0/24\r\n' >"$rel/lists/ipset-all.txt.backup"
	printf '203.0.113.113/32\r\n' >"$rel/lists/ipset-all.txt"
	# Двоичный пейлоад с байтом 0x0d внутри: он обязан уцелеть.
	printf 'A\r\nB' >"$rel/bin/payload.bin"

	python3 "$REPO/tools/vendor-sync.py" "$rel" "$out" --version 9.9.9 >/dev/null

	run grep -c $'\r' "$out/flowseal/lists/list-general.txt"
	[ "$output" = "0" ]
	run grep -c $'\r' "$out/flowseal/lists/ipset-all.full.txt"
	[ "$output" = "0" ]

	# .bin должен остаться байт в байт.
	cmp "$rel/bin/payload.bin" "$out/flowseal/fake/payload.bin"
}
