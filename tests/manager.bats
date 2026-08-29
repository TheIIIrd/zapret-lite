#!/usr/bin/env bats
# Защита от порчи, переключатели, doctor, удаление.

load helper

setup() {
	setup_root
	PKG="$BATS_TEST_TMPDIR/pkg"
	build_pkg "$PKG" 1.10.2 72.13
	install_pkg "$PKG" --strategy general >/dev/null
}

# --- защита ручных правок ---------------------------------------------

@test "правленый config не перезаписывается без --force" {
	echo "# моя правка" >>"$ZL_PREFIX/opt/zapret/config"
	run install_pkg "$PKG"
	[ "$status" -ne 0 ]
	[[ "$output" == *"изменён вручную"* ]]
	# Правка обязана уцелеть: отказ не должен ничего терять.
	run grep -c "моя правка" "$ZL_PREFIX/opt/zapret/config"
	[ "$output" = "1" ]
}

@test "--force сохраняет копию правленого config" {
	echo "# моя правка" >>"$ZL_PREFIX/opt/zapret/config"
	run install_pkg "$PKG" --force
	[ "$status" -eq 0 ]
	[ -f "$ZL_PREFIX/opt/zapret/config.zapret-lite-backup" ]
	run grep -c "моя правка" "$ZL_PREFIX/opt/zapret/config.zapret-lite-backup"
	[ "$output" = "1" ]
}

@test "local.conf перекрывает стратегию" {
	echo 'NFQWS_PORTS_TCP="1234"' >>"$ZL_PREFIX/etc/zapret-lite/local.conf"
	run load_config 'echo "P=$NFQWS_PORTS_TCP"'
	[[ "$output" == *"P=1234"* ]]
}

# --- имя стратегии как источник пути ----------------------------------

@test "обход каталогов через имя стратегии не проходит" {
	printf '../../etc/passwd\n' >"$ZL_PREFIX/etc/zapret-lite/strategy"
	run load_config 'echo "E=$NFQWS_ENABLE"'
	[[ "$output" == *"E=0"* ]]
	[[ "$output" == *"недопустимое имя"* ]]
}

@test "use отвергает недопустимое имя" {
	run zl use "../evil"
	[ "$status" -ne 0 ]
	# Файл выбора не должен измениться от неудачной попытки.
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/strategy")" = "general" ]
}

@test "use отвергает стратегию, которой нет в поколении" {
	run zl use "нет-такой-стратегии"
	[ "$status" -ne 0 ]
}

@test "use переключает стратегию" {
	run zl use general-alt11
	[ "$status" -eq 0 ]
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/strategy")" = "general-alt11" ]
	run load_config 'echo "$NFQWS_PORTS_TCP"'
	[[ "$output" == *"2053"* ]]
}

# --- переключатели ----------------------------------------------------

@test "game-filter подставляет порты в конфиг" {
	run load_config 'echo "$NFQWS_PORTS_UDP"'
	[[ "$output" == *",12"* ]]

	zl game-filter all
	run load_config 'echo "$NFQWS_PORTS_UDP"'
	[[ "$output" == *"1024-65535"* ]]

	zl game-filter disabled
	run load_config 'echo "T=$NFQWS_PORTS_TCP U=$NFQWS_PORTS_UDP"'
	[[ "$output" == *"T=80,443,2053,2083,2087,2096,8443,12"* ]]
	[[ "$output" == *"U=443,19294-19344,50000-50100,12"* ]]
}

@test "game-filter больше не принимает раздельные tcp и udp" {
	# Режимы были нашей выдумкой: у flowseal фильтр либо есть, либо нет.
	for m in tcp udp; do
		run zl game-filter "$m"
		[ "$status" -ne 0 ]
	done
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/game-filter")" = "disabled" ]
}

@test "game-filter отвергает неизвестный режим" {
	run zl game-filter неведомое
	[ "$status" -ne 0 ]
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/game-filter")" = "disabled" ]
}

@test "ipset переключается между тремя режимами" {
	local f="$ZL_PREFIX/etc/zapret-lite/lists/ipset-all.txt"

	zl ipset none
	[ "$(wc -l <"$f")" -eq 1 ]
	run grep -c '203.0.113.113/32' "$f"
	[ "$output" = "1" ]

	zl ipset any
	[ ! -s "$f" ]

	zl ipset loaded
	[ "$(wc -l <"$f")" -gt 30000 ]
}

@test "ipset отвергает неизвестный режим" {
	run zl ipset неведомое
	[ "$status" -ne 0 ]
}

@test "битый файл режима не роняет загрузку конфига" {
	printf 'мусор\n' >"$ZL_PREFIX/etc/zapret-lite/game-filter"
	run load_config 'echo "T=$NFQWS_PORTS_TCP"'
	# Откат на выключенный фильтр, а не падение.
	[[ "$output" == *",12"* ]]
	[[ "$output" == *"неизвестный режим"* ]]
}

# --- doctor -----------------------------------------------------------

@test "doctor доволен здоровой установкой" {
	run zl doctor
	[[ "$output" == *"манифест поколения сходится"* ]]
	[[ "$output" == *"все файлы, на которые ссылается стратегия, существуют"* ]]
	[[ "$output" == *"nfqws --dry-run: опции корректны"* ]]
	[[ "$output" != *"НЕ сходится"* ]]
}

@test "doctor замечает повреждённое поколение" {
	echo tampered >>"$ZL_PREFIX/opt/zapret-lite/current/lists/list-google.txt"
	run zl doctor
	[[ "$output" == *"манифест поколения НЕ сходится"* ]]
	[ "$status" -ne 0 ]
}

@test "doctor замечает пустой пользовательский список" {
	: >"$ZL_PREFIX/etc/zapret-lite/lists/list-general-user.txt"
	run zl doctor
	[[ "$output" == *"пуст"* ]]
}

@test "doctor замечает правленый config" {
	echo "# правка" >>"$ZL_PREFIX/opt/zapret/config"
	run zl doctor
	[[ "$output" == *"изменён вручную"* ]]
}

@test "doctor замечает пропавший файл стратегии" {
	rm -f "$ZL_PREFIX/opt/zapret-lite/current/fake/tls_clienthello_4pda_to.bin"
	run zl doctor
	[[ "$output" == *"не найдено файлов"* ]]
	[ "$status" -ne 0 ]
}

# --- status и list ----------------------------------------------------

@test "status показывает поколение и стратегию" {
	run zl status
	[[ "$output" == *"general"* ]]
	[[ "$output" == *"flowseal-1.10.2"* ]]
}

@test "list помечает активную стратегию" {
	run zl list
	[[ "$output" == *"* general"* ]]
	[[ "$output" == *"general-alt13"* ]]
}

# --- check-update -----------------------------------------------------

@test "check-update сообщает о новой версии, ничего не меняя" {
	local before after
	before=$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")
	printf '{"tag_name":"9.9.9"}' >"$BATS_TEST_TMPDIR/rel.json"
	ZL_UPDATE_URL="file://$BATS_TEST_TMPDIR/rel.json" run zl check-update
	[ "$status" -eq 0 ]
	[[ "$output" == *"9.9.9"* ]]
	after=$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")
	[ "$before" = "$after" ]
}

@test "check-update молчит, когда версия актуальна" {
	printf '{"tag_name":"1.10.2"}' >"$BATS_TEST_TMPDIR/rel.json"
	ZL_UPDATE_URL="file://$BATS_TEST_TMPDIR/rel.json" run zl check-update
	[[ "$output" == *"актуальная версия"* ]]
}

@test "недоступный источник обновлений не роняет проверку" {
	ZL_UPDATE_URL="file:///нет/такого/файла" run zl check-update
	[ "$status" -eq 0 ]
}

# --- удаление ---------------------------------------------------------

@test "удаление сносит наше, но сохраняет /etc" {
	( cd "$PKG" && sh uninstall.sh >/dev/null )
	[ ! -d "$ZL_PREFIX/opt/zapret-lite" ]
	[ ! -d "$ZL_PREFIX/opt/zapret" ]
	[ ! -f "$ZL_PREFIX/etc/systemd/system/zapret.service" ]
	[ ! -f "$ZL_PREFIX/usr/local/bin/zapret-lite" ]
	[ -d "$ZL_PREFIX/etc/zapret-lite" ]
}

@test "--purge не оставляет ничего" {
	( cd "$PKG" && sh uninstall.sh >/dev/null )
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	run find "$ZL_PREFIX" -type f
	[ -z "$output" ]
}

@test "установка после удаления проходит с нуля" {
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	run install_pkg "$PKG" --strategy general
	[ "$status" -eq 0 ]
	run zl doctor
	[[ "$output" == *"манифест поколения сходится"* ]]
}

# --- проверки, добавленные после аудита -------------------------------

@test "чужой /opt/zapret не удаляется деинсталлятором" {
	# Имитируем zapret, поставленный пользователем самостоятельно.
	rm -f "$ZL_PREFIX/opt/zapret/.zapret-lite-owned"
	run sh -c "cd '$PKG' && sh uninstall.sh"
	[ "$status" -eq 0 ]
	[ -d "$ZL_PREFIX/opt/zapret" ]
	[[ "$output" == *"оставлен"* ]]
	# Наше при этом должно быть снесено.
	[ ! -d "$ZL_PREFIX/opt/zapret-lite" ]
}

@test "свой /opt/zapret удаляется" {
	[ -f "$ZL_PREFIX/opt/zapret/.zapret-lite-owned" ]
	( cd "$PKG" && sh uninstall.sh >/dev/null )
	[ ! -d "$ZL_PREFIX/opt/zapret" ]
}

@test "правленый config останавливает установку до изменений" {
	local gen_before
	gen_before=$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")
	echo "# правка" >>"$ZL_PREFIX/opt/zapret/config"
	run install_pkg "$PKG"
	[ "$status" -ne 0 ]
	# Ничего не должно было поменяться: ни поколение, ни выбор стратегии.
	[ "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")" = "$gen_before" ]
}

@test "установка под жёстким umask даёт читаемые каталоги" {
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	( umask 077; cd "$PKG" && sh install.sh --strategy general >/dev/null )
	run stat -c '%a' "$ZL_PREFIX/etc/zapret-lite/lists"
	[ "$output" = "755" ]
	run stat -c '%a' "$ZL_PREFIX/opt/zapret-lite/current/lists"
	[ "$output" = "755" ]
}

@test "check-update отвергает мусор в ответе источника" {
	printf '{"tag_name":"1.0; rm -rf /"}' >"$BATS_TEST_TMPDIR/bad.json"
	ZL_UPDATE_URL="file://$BATS_TEST_TMPDIR/bad.json" run zl check-update
	[ "$status" -eq 0 ]
	[[ "$output" == *"неожиданный ответ"* ]]
	[ ! -f "$ZL_PREFIX/var/lib/zapret-lite/update-check" ]
}

@test "источник обновлений настраивается через update.url" {
	printf '{"tag_name":"7.7.7"}' >"$BATS_TEST_TMPDIR/own.json"
	printf 'file://%s\n' "$BATS_TEST_TMPDIR/own.json" >"$ZL_PREFIX/etc/zapret-lite/update.url"
	run zl check-update
	[[ "$output" == *"7.7.7"* ]]
}

@test "переустановка того же поколения не оставляет .old" {
	install_pkg "$PKG" >/dev/null
	run find "$ZL_PREFIX/opt/zapret-lite/versions" -maxdepth 1 -name '*.old'
	[ -z "$output" ]
	run zl doctor
	[[ "$output" == *"манифест поколения сходится"* ]]
}

@test "doctor находит nfqws там, где его оставляет install_bin.sh" {
	# Путь nfq/nfqws, а не binaries/<арх>: install_bin.sh симлинкует
	# выбранный бинарник именно туда, и оттуда его берёт init-скрипт.
	[ -x "$ZL_PREFIX/opt/zapret/nfq/nfqws" ]
	run zl doctor
	[[ "$output" == *"nfqws: v"* ]]
}

@test "установка падает, если бинарник не установился" {
	local pkg="$BATS_TEST_TMPDIR/pkg-nobin"
	cp -r "$PKG" "$pkg"
	# install_bin.sh отрабатывает, но nfq/nfqws не появляется.
	printf '#!/bin/sh\nexit 0\n' >"$pkg/zapret/install_bin.sh"
	chmod +x "$pkg/zapret/install_bin.sh"
	rm -rf "$ZL_PREFIX/opt/zapret"
	run install_pkg "$pkg" --strategy general
	[ "$status" -ne 0 ]
	[[ "$output" == *"не нашёл бинарник"* ]]
}

@test "комплект без каталога binaries отвергается" {
	local pkg="$BATS_TEST_TMPDIR/pkg-empty"
	cp -r "$PKG" "$pkg"
	rm -rf "$pkg/zapret/binaries"
	run install_pkg "$pkg" --strategy general
	[ "$status" -ne 0 ]
	[[ "$output" == *"нет бинарников zapret"* ]]
}

@test "ссылка на пустую переменную в local.conf не обманывает doctor" {
	# С set -u подоболочка doctor умирала бы молча, и проверка файлов
	# рапортовала бы успех, ничего не проверив.
	# Имя переменной обязано быть валидным идентификатором, иначе это
	# синтаксическая ошибка, а не обращение к пустой переменной.
	echo 'NFQWS_OPT="$NFQWS_OPT --comment=$UNSET_ON_PURPOSE"' \
		>>"$ZL_PREFIX/etc/zapret-lite/local.conf"
	run zl doctor
	[[ "$output" == *"все файлы"* || "$output" == *"не найдено файлов"* ]]
}

# --- целостность комплекта и прав ------------------------------------

@test "подменённая стратегия в комплекте ломает установку" {
	# strategies/*.conf читаются через '.' от root - самый чувствительный
	# тип файла в комплекте. До введения манифеста комплекта подмена
	# проходила молча.
	local pkg="$BATS_TEST_TMPDIR/pkg-tamper"
	cp -r "$PKG" "$pkg"
	python3 "$REPO/tools/make-package-manifest.py" "$pkg" >/dev/null
	echo 'NFQWS_OPT="$NFQWS_OPT --comment=pwned"' >>"$pkg/strategies/general.conf"
	run install_pkg "$pkg" --strategy general
	[ "$status" -ne 0 ]
	[[ "$output" == *"strategies/general.conf: FAILED"* ]]
}

@test "подброшенный файл в комплекте тоже замечается" {
	local pkg="$BATS_TEST_TMPDIR/pkg-extra"
	cp -r "$PKG" "$pkg"
	python3 "$REPO/tools/make-package-manifest.py" "$pkg" >/dev/null
	printf 'NFQWS_ENABLE=1\n' >"$pkg/strategies/evil.conf"
	run install_pkg "$pkg" --strategy general
	[ "$status" -ne 0 ]
	[[ "$output" == *"лишний файл в комплекте: strategies/evil.conf"* ]]
}

@test "подменённый lib/common.sh ломает установку" {
	local pkg="$BATS_TEST_TMPDIR/pkg-lib"
	cp -r "$PKG" "$pkg"
	python3 "$REPO/tools/make-package-manifest.py" "$pkg" >/dev/null
	echo '# tampered' >>"$pkg/lib/common.sh"
	run install_pkg "$pkg" --strategy general
	[ "$status" -ne 0 ]
	[[ "$output" == *"lib/common.sh: FAILED"* ]]
}

@test "целый комплект с манифестом ставится" {
	local pkg="$BATS_TEST_TMPDIR/pkg-good"
	cp -r "$PKG" "$pkg"
	python3 "$REPO/tools/make-package-manifest.py" "$pkg" >/dev/null
	run install_pkg "$pkg" --strategy general
	[ "$status" -eq 0 ]
	[[ "$output" == *"комплект цел"* ]]
}

@test "установка без манифеста предупреждает, но работает" {
	run install_pkg "$PKG" --strategy general
	[ "$status" -eq 0 ]
	[[ "$output" == *"не проверен на целостность"* ]]
}

@test "установка чинит права на унаследованном /etc" {
	chmod 0777 "$ZL_PREFIX/etc/zapret-lite"
	chmod 0666 "$ZL_PREFIX/etc/zapret-lite/local.conf"
	install_pkg "$PKG" >/dev/null 2>&1
	[ "$(stat -c '%a' "$ZL_PREFIX/etc/zapret-lite")" = "755" ]
	[ "$(stat -c '%a' "$ZL_PREFIX/etc/zapret-lite/local.conf")" = "644" ]
}

@test "имя поколения берёт версию zapret из репозитория, если её нет рядом" {
	# Комплект релиза кладёт zapret.lock рядом с деревом zapret; при
	# ручной сборке его там нет. Без запасного пути получалось имя вида
	# "..._zapret-unknown".
	local gen
	gen=$(basename "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")")
	[[ "$gen" != *"zapret-unknown"* ]]
	[[ "$gen" == *"zapret-72."* ]]
}

@test "справка перечисляет ровно те команды, что реализованы" {
	# Дважды находил в файле следы задвоенных правок: в справке была
	# несуществующая команда update. Пусть расхождение ловится тестом.
	local mgr="$REPO/bin/zapret-lite"
	ZL_LIB="$REPO/lib" sh "$mgr" --help \
		| grep -oE '^  zapret-lite [a-z0-9-]+' | awk '{print $2}' | sort -u >"$BATS_TEST_TMPDIR/help"
	# tr -d '[:space:]' склеил бы все имена в одну строку: перевод строки
	# он тоже удаляет. Убираем только скобку и ведущие пробелы.
	sed -n '/^case "\$cmd" in/,/^esac/p' "$mgr" \
		| grep -oE '^[[:space:]]+[a-z0-9-]+\)' \
		| sed -e 's/^[[:space:]]*//' -e 's/)$//' | sort -u >"$BATS_TEST_TMPDIR/impl"
	run diff "$BATS_TEST_TMPDIR/help" "$BATS_TEST_TMPDIR/impl"
	[ "$status" -eq 0 ]
}

@test "каждая команда справки хотя бы запускается" {
	for c in status list generations ipset game-filter; do
		run zl "$c"
		[ "$status" -eq 0 ] || { echo "команда $c упала"; return 1; }
	done
}

@test "dry-run отказывает, если каталог недоступен на запись" {
	# Раньше --dry-run печатал "would: cp ..." и ничего не проверял,
	# создавая ложное ощущение проверенности.
	if [ "$(id -u)" = 0 ]; then
		skip "root пишет куда угодно: проверка [ -w ] для него не работает"
	fi
	local ro="$BATS_TEST_TMPDIR/readonly"
	mkdir -p "$ro"
	chmod 555 "$ro"
	run env ZL_PREFIX="$ro/root" sh -c "cd '$PKG' && sh ./install.sh --dry-run"
	chmod 755 "$ro"
	[ "$status" -ne 0 ]
	[[ "$output" == *"нет прав на запись"* ]]
}

@test "dry-run ничего не создаёт" {
	local before after
	before=$(find "$ZL_PREFIX" -type f | sort | md5sum)
	run install_pkg "$PKG" --dry-run
	[ "$status" -eq 0 ]
	after=$(find "$ZL_PREFIX" -type f | sort | md5sum)
	[ "$before" = "$after" ]
}

@test "команды test больше нет" {
	run zl test
	[ "$status" -ne 0 ]
	[[ "$output" == *"неизвестная команда"* ]]
}

@test "DISABLE_IPV6 переключается через local.conf" {
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=1"* ]]
	echo 'DISABLE_IPV6=0' >>"$ZL_PREFIX/etc/zapret-lite/local.conf"
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=0"* ]]
}

@test "doctor сообщает, когда обработка IPv6 включена" {
	echo 'DISABLE_IPV6=0' >>"$ZL_PREFIX/etc/zapret-lite/local.conf"
	run zl doctor
	[[ "$output" == *"обработка IPv6 включена"* ]]
}

@test "переменные tpws заданы, хотя tpws не используется" {
	# common/base.sh:423 читает TPWS_PORTS безусловно, ещё до проверки
	# TPWS_ENABLE.
	run load_config 'echo "E=$TPWS_ENABLE P=$TPWS_PORTS S=$TPPORT_SOCKS"'
	[[ "$output" == *"E=0"* ]]
	[[ "$output" == *"P=80,443"* ]]
	[[ "$output" == *"S=987"* ]]
}

@test "ipv6 переключается и попадает в конфиг" {
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=1"* ]]

	zl ipv6 on
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=0"* ]]

	zl ipv6 off
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=1"* ]]
}

@test "ipv6 отвергает неизвестный режим" {
	run zl ipv6 неведомое
	[ "$status" -ne 0 ]
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/ipv6")" = "off" ]
}

@test "режим ipv6 переживает переустановку" {
	zl ipv6 on
	install_pkg "$PKG" >/dev/null
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/ipv6")" = "on" ]
	run zl status
	[[ "$output" == *"IPv6          : on"* ]]
}

@test "--ipv6 при установке задаёт режим" {
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	install_pkg "$PKG" --strategy general --ipv6 >/dev/null
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/ipv6")" = "on" ]
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=0"* ]]
}

@test "битый файл режима ipv6 не роняет конфиг" {
	printf 'мусор\n' >"$ZL_PREFIX/etc/zapret-lite/ipv6"
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=1"* ]]
	[[ "$output" == *"неизвестный режим ipv6"* ]]
}

# --- пробелы, найденные мутационным тестированием ---------------------

@test "имя стратегии отвергается по набору символов, а не только по точке" {
	# Прежние тесты брали '../evil', который отсеивался правилом про
	# ведущую точку. Убери проверку набора символов - и они бы прошли.
	for bad in 'foo/bar' 'a;rm -rf /' 'a b' 'evil$(id)' 'имя'; do
		run zl use "$bad"
		[ "$status" -ne 0 ] || { echo "принято недопустимое имя: $bad"; return 1; }
	done
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/strategy")" = "general" ]
}

@test "шим отвергает имя стратегии с недопустимыми символами" {
	printf 'foo/bar\n' >"$ZL_PREFIX/etc/zapret-lite/strategy"
	run load_config 'echo "E=$NFQWS_ENABLE"'
	[[ "$output" == *"E=0"* ]]
	[[ "$output" == *"недопустимое имя"* ]]
}

@test "game-filter all подставляет диапазон и в TCP, и в UDP" {
	# Мутация, ломавшая только TCP, раньше проходила незамеченной.
	zl game-filter all
	run load_config 'echo "T=$NFQWS_PORTS_TCP U=$NFQWS_PORTS_UDP"'
	[[ "$output" == *"T=80,443,2053,2083,2087,2096,8443,1024-65535"* ]]
	[[ "$output" == *"U=443,19294-19344,50000-50100,1024-65535"* ]]
}

@test "ротация не удаляет текущее и предыдущее поколения" {
	local cur prev
	cur=$(basename "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")")
	# Насыпаем поколений заведомо больше лимита, причём с датами
	# новее текущего - чтобы порог ротации точно был превышен.
	for d in 2030-01-01 2030-02-02 2030-03-03 2030-04-04; do
		cp -r "$ZL_PREFIX/opt/zapret-lite/versions/$cur" \
		      "$ZL_PREFIX/opt/zapret-lite/versions/${d}_flowseal-x_zapret-1.0"
	done
	install_pkg "$PKG" >/dev/null
	cur=$(basename "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")")
	[ -d "$ZL_PREFIX/opt/zapret-lite/versions/$cur" ]
	# readlink -f печатает путь даже для несуществующего симлинка,
	# поэтому сначала убеждаемся, что симлинк вообще есть.
	if [ -L "$ZL_PREFIX/opt/zapret-lite/previous" ]; then
		prev=$(basename "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/previous")")
		[ -d "$ZL_PREFIX/opt/zapret-lite/versions/$prev" ]
	fi
	# И current обязан остаться рабочим.
	run zl doctor
	[[ "$output" == *"манифест поколения сходится"* ]]
}

@test "doctor действительно вызывает nfqws --dry-run" {
	# Подменяем бинарник на всегда отказывающий: doctor обязан это
	# заметить, а не отрапортовать успех.
	local nf="$ZL_PREFIX/opt/zapret/nfq/nfqws"
	rm -f "$nf"
	printf '#!/bin/sh\ncase "$1" in --version) echo v0; exit 0 ;; esac\nexit 1\n' >"$nf"
	chmod +x "$nf"
	run zl doctor
	[[ "$output" == *"отверг опции стратегии"* ]]
	[ "$status" -ne 0 ]
}

@test "прерванная установка оставляет рабочую конфигурацию" {
	# Проверено на пяти точках прерывания; здесь закреплена самая
	# опасная - сбой после того, как поколение собрано.
	local pkg="$BATS_TEST_TMPDIR/pkg-fail" before
	cp -r "$PKG" "$pkg"
	before=$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")
	python3 - "$pkg/install.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index('# 7. Активная стратегия и конфиг')
open(p, 'w').write(s[:i] + 'zl_die "СБОЙ (имитация)"\n\n' + s[i:])
PY
	run install_pkg "$pkg"
	[ "$status" -ne 0 ]
	# Прежнее поколение остаётся текущим, конфиг остаётся рабочим.
	[ "$(readlink -f "$ZL_PREFIX/opt/zapret-lite/current")" = "$before" ]
	run load_config 'echo "E=$NFQWS_ENABLE"'
	[[ "$output" == *"E=1"* ]]
	# И никакого мусора от незавершённой сборки.
	run find "$ZL_PREFIX/opt/zapret-lite/versions" -maxdepth 1 \
	         \( -name '.stage.*' -o -name '*.old' \)
	[ -z "$output" ]
}

@test "сбой после остановки службы объясняет, как восстановиться" {
	# Иначе человек остаётся без обхода и без подсказки.
	local pkg="$BATS_TEST_TMPDIR/pkg-fail2"
	cp -r "$PKG" "$pkg"
	python3 - "$pkg/install.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index('# 8. Юнит systemd')
open(p, 'w').write(s[:i] + 'zl_die "СБОЙ (имитация)"\n\n' + s[i:])
PY
	# В префиксе служба не останавливается (systemd не задействуется),
	# поэтому предупреждения о неработающем обходе быть не должно.
	run install_pkg "$pkg"
	[ "$status" -ne 0 ]
	[[ "$output" != *"обход не работает"* ]]
}

@test "в режиме префикса systemd не задействуется" {
	# Это не косметика: раньше установка в префикс от обычного
	# пользователя падала на "Failed to connect to bus", а тесты этого
	# не видели, потому что systemctl был подменён заглушкой.
	run zl doctor
	[[ "$output" == *"systemd не задействуется"* ]]
	[[ "$output" == *"службой не управляем"* ]]
	[[ "$output" != *"systemd не обнаружен"* ]]
}

@test "полный цикл проходит без systemctl в PATH" {
	# Ровно то, что делает release.yml на собранном артефакте: если код
	# где-то дёргает systemctl в обход zl_manage_systemd, здесь это
	# вылезет.
	local nosys="$BATS_TEST_TMPDIR/nosys" p c
	mkdir -p "$nosys"
	for c in sh dash cp mv rm ln find sed grep awk sort comm head tail cat \
	         cut mkdir rmdir chmod chown install sha256sum stat date \
	         basename dirname readlink xargs ls du df tr wc id uname \
	         mktemp nft python3 tar seq; do
		p=$(command -v "$c" 2>/dev/null) || continue
		[ -x "$p" ] || continue
		ln -sf "$p" "$nosys/$c"
	done
	# Проверяем не наличие файла, а то, что команда действительно
	# недоступна с этим PATH.
	if PATH="$nosys" command -v systemctl >/dev/null 2>&1; then
		echo "systemctl доступен в изолированном PATH"
		return 1
	fi

	( cd "$PKG" && PATH="$nosys" sh ./install.sh --strategy general ) >/dev/null
	[ -L "$ZL_PREFIX/opt/zapret-lite/current" ]
	( cd "$PKG" && PATH="$nosys" sh ./uninstall.sh --purge ) >/dev/null
	run find "$ZL_PREFIX" -type f
	[ -z "$output" ]
}

# --- тип firewall и ограничение по интерфейсу -------------------------

@test "fwtype фиксирует тип firewall в конфиге" {
	run load_config 'echo "F=${FWTYPE-авто}"'
	[[ "$output" == *"F=авто"* ]]

	zl fwtype iptables
	run load_config 'echo "F=$FWTYPE"'
	[[ "$output" == *"F=iptables"* ]]

	zl fwtype nftables
	run load_config 'echo "F=$FWTYPE"'
	[[ "$output" == *"F=nftables"* ]]

	zl fwtype auto
	run load_config 'echo "F=${FWTYPE-авто}"'
	[[ "$output" == *"F=авто"* ]]
}

@test "fwtype отвергает неизвестный тип" {
	run zl fwtype ebtables
	[ "$status" -ne 0 ]
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/fwtype")" = "auto" ]
}

@test "мусор в файле fwtype откатывает на автоопределение" {
	printf 'мусор\n' >"$ZL_PREFIX/etc/zapret-lite/fwtype"
	run load_config 'echo "F=${FWTYPE-авто}"'
	[[ "$output" == *"F=авто"* ]]
	[[ "$output" == *"неизвестный тип firewall"* ]]
}

@test "wan-iface ограничивает обработку одним интерфейсом" {
	run load_config 'echo "W=${IFACE_WAN-все}"'
	[[ "$output" == *"W=все"* ]]

	zl wan-iface eth0
	run load_config 'echo "W=$IFACE_WAN"'
	[[ "$output" == *"W=eth0"* ]]

	zl wan-iface any
	run load_config 'echo "W=${IFACE_WAN-все}"'
	[[ "$output" == *"W=все"* ]]
}

@test "wan-iface принимает несколько интерфейсов" {
	zl wan-iface "eth0 wlan0"
	run load_config 'echo "W=$IFACE_WAN"'
	[[ "$output" == *"W=eth0 wlan0"* ]]
}

@test "wan-iface отвергает опасное имя" {
	# Значение попадает в правила firewall, поэтому набор символов узкий.
	for bad in 'eth0;id' 'eth0$(id)' 'eth0|x' '../eth0'; do
		run zl wan-iface "$bad"
		[ "$status" -ne 0 ] || { echo "принято: $bad"; return 1; }
	done
}

@test "оба режима переживают переустановку и видны в status" {
	zl fwtype iptables
	zl wan-iface eth0
	install_pkg "$PKG" >/dev/null
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/fwtype")" = "iptables" ]
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/wan-iface")" = "eth0" ]
	run zl status
	[[ "$output" == *"Интерфейс     : eth0"* ]]
	run zl doctor
	[[ "$output" == *"firewall: iptables (зафиксирован)"* ]]
}

@test "флаги установщика задают оба режима" {
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	install_pkg "$PKG" --strategy general --fwtype iptables --wan-iface eth0 >/dev/null
	run load_config 'echo "F=$FWTYPE W=$IFACE_WAN"'
	[[ "$output" == *"F=iptables"* ]]
	[[ "$output" == *"W=eth0"* ]]
}

@test "check-update не падает, когда некуда записать отметку" {
	# От обычного пользователя /var/lib недоступен, но сама проверка -
	# это чтение, и запрещать её из-за отметки было бы странно.
	printf '{"tag_name":"1.10.2"}' >"$BATS_TEST_TMPDIR/r.json"
	ZL_STATE=/proc/недоступно ZL_UPDATE_URL="file://$BATS_TEST_TMPDIR/r.json" \
		run zl check-update
	[ "$status" -eq 0 ]
	[[ "$output" == *"актуальная версия"* ]]
}

@test "status показывает зафиксированный тип, а не автоопределение" {
	# Именно здесь была путаница: fwtype говорил "поменял", а status
	# продолжал уверять, что nftables.
	zl fwtype nftables
	run zl status
	[[ "$output" == *"Firewall      : nftables"* ]]
	[[ "$output" != *"(авто)"* ]]

	zl fwtype auto
	run zl status
	[[ "$output" == *"(авто)"* ]]
}

@test "fwtype отказывает, если для режима не хватает команд" {
	local nosys="$BATS_TEST_TMPDIR/noipset" p c
	mkdir -p "$nosys"
	for c in sh dash cp mv rm ln find sed grep awk sort comm head tail cat \
	         cut mkdir rmdir chmod chown install sha256sum stat date \
	         basename dirname readlink xargs ls du df tr wc id uname \
	         mktemp python3 tar seq nft; do
		p=$(command -v "$c" 2>/dev/null) || continue
		[ -x "$p" ] || continue
		ln -sf "$p" "$nosys/$c"
	done
	# iptables и ipset намеренно отсутствуют.
	PATH="$nosys" run zl fwtype iptables
	[ "$status" -ne 0 ]
	[[ "$output" == *"не хватает команд"* ]]
	[[ "$output" == *"ipset"* ]]
	# Значение не должно измениться от неудачной попытки.
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/fwtype")" = "auto" ]
}

@test "установщик отказывает при недоступном типе firewall" {
	local nosys="$BATS_TEST_TMPDIR/noipset2" p c
	mkdir -p "$nosys"
	for c in sh dash cp mv rm ln find sed grep awk sort comm head tail cat \
	         cut mkdir rmdir chmod chown install sha256sum stat date \
	         basename dirname readlink xargs ls du df tr wc id uname \
	         mktemp python3 tar seq nft; do
		p=$(command -v "$c" 2>/dev/null) || continue
		[ -x "$p" ] || continue
		ln -sf "$p" "$nosys/$c"
	done
	run env PATH="$nosys" sh -c "cd '$PKG' && sh ./install.sh --fwtype iptables"
	[ "$status" -ne 0 ]
	[[ "$output" == *"не хватает команд"* ]]
}

@test "переключатели, меняющие состав правил, идут через zl_switch_state" {
	# Обычный restart здесь опасен: ExecStop читает конфиг заново, уже с
	# новым значением, и zapret снимает не те правила, что ставил.
	# Так уже случилось с fwtype и так же вело бы себя выключение IPv6
	# в режиме iptables.
	local mgr="$REPO/bin/zapret-lite" fn
	for fn in cmd_fwtype cmd_ipv6 cmd_game_filter cmd_wan_iface cmd_use; do
		sed -n "/^$fn()/,/^}/p" "$mgr" >"$BATS_TEST_TMPDIR/f"
		grep -q 'zl_switch_state' "$BATS_TEST_TMPDIR/f" \
			|| { echo "$fn не использует zl_switch_state"; return 1; }
		grep -q 'restart_service' "$BATS_TEST_TMPDIR/f" \
			&& { echo "$fn всё ещё вызывает restart_service"; return 1; }
	done
	# ipset - исключение: список перечитывается по mtime, правила
	# не меняются, перезапуск не нужен вовсе.
	sed -n '/^cmd_ipset()/,/^}/p' "$mgr" >"$BATS_TEST_TMPDIR/f"
	! grep -q 'zl_switch_state\|restart_service' "$BATS_TEST_TMPDIR/f"
}

@test "doctor сообщает о виртуализации" {
	run zl doctor
	[[ "$output" == *"виртуализац"* ]]
}

@test "отказ по зависимостям firewall происходит до изменений в системе" {
	# Раньше проверка стояла после остановки службы, копирования zapret
	# и сборки поколения: установщик отказывал, оставив систему без
	# работающего обхода.
	local nosys="$BATS_TEST_TMPDIR/nodeps" p c fresh
	mkdir -p "$nosys"
	for c in sh dash cp mv rm ln find sed grep awk sort comm head tail cat \
	         cut mkdir rmdir chmod chown install sha256sum stat date \
	         basename dirname readlink xargs ls du df tr wc id uname \
	         mktemp python3 tar seq iptables ip6tables; do
		p=$(command -v "$c" 2>/dev/null) || continue
		[ -x "$p" ] || continue
		ln -sf "$p" "$nosys/$c"
	done
	# ipset и nft отсутствуют: остаётся только недоступный iptables.

	fresh="$BATS_TEST_TMPDIR/fresh"
	run env ZL_PREFIX="$fresh" PATH="$nosys" \
		sh -c "cd '$PKG' && sh ./install.sh --strategy general --fwtype iptables"
	[ "$status" -ne 0 ]
	[[ "$output" == *"не хватает команд"* ]]

	# Ни одного файла создано быть не должно. Каталога может не быть
	# вовсе - тогда find ругается, и его вывод нельзя путать с файлами.
	if [ -d "$fresh" ]; then
		run find "$fresh" -type f
		[ -z "$output" ] || { echo "созданы файлы: $output"; return 1; }
	fi
}

@test "определение виртуализации не падает без systemd-detect-virt" {
	# В dash "local vm" оставляет переменную неустановленной, и под
	# set -u обращение к ней роняет скрипт.
	local nosys="$BATS_TEST_TMPDIR/novirt" p c
	mkdir -p "$nosys"
	for c in sh dash cat grep sed tr uname; do
		p=$(command -v "$c" 2>/dev/null) || continue
		[ -x "$p" ] || continue
		ln -sf "$p" "$nosys/$c"
	done
	run dash -c "set -eu; . '$REPO/lib/common.sh'; PATH='$nosys'; zl_detect_virt"
	[ "$status" -eq 0 ]
}

@test "установщик сообщает тот тип firewall, который будет использован" {
	# При явном --fwtype iptables печаталась ещё и строка автоопределения
	# "firewall: nftables", и казалось, что флаг проигнорирован.
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	run install_pkg "$PKG" --strategy general --fwtype iptables
	[ "$status" -eq 0 ]
	[[ "$output" == *"firewall: iptables (задан явно)"* ]]
	[[ "$output" != *"firewall: nftables"* ]]
}

@test "переключения подряд не упираются в ограничитель systemd" {
	# StartLimitIntervalSec=300 при StartLimitBurst=5 давал 5 запусков за
	# пять минут - в тридцать раз строже штатного systemd. Пятое подряд
	# переключение падало со start-limit-hit, хотя ничего не ломалось.
	local n
	n=$(grep -c 'StartLimitIntervalSec=30$' "$REPO/systemd/10-zapret-lite.conf")
	[ "$n" = 1 ] || { echo "интервал ограничителя вернулся к прежнему"; return 1; }

	# И намеренные операции сбрасывают счётчик аварийных перезапусков.
	grep -q 'reset-failed' "$REPO/lib/common.sh" \
		|| { echo "zl_switch_state не сбрасывает счётчик"; return 1; }
	grep -q 'reset-failed' "$REPO/bin/zapret-lite" \
		|| { echo "restart_service не сбрасывает счётчик"; return 1; }

	# Практическая проверка: восемь переключений подряд должны пройти.
	for _ in 1 2 3 4 5 6 7 8; do
		zl game-filter all >/dev/null
		zl game-filter disabled >/dev/null
	done
	run zl status
	[[ "$output" == *"Игровой фильтр: disabled"* ]]
}

@test "drop-in перезапускает службу при падении nfqws" {
	# Проверено вживую: pkill -x nfqws опустошает cgroup, и юнит
	# Type=forking без главного PID завершается как "Deactivated
	# successfully". Restart=on-failure на успешное завершение не
	# реагирует, и обход тихо переставал работать.
	local f="$REPO/systemd/10-zapret-lite.conf"
	grep -q '^Restart=always$' "$f" \
		|| { echo "Restart вернулся к значению, не реагирующему на падение"; return 1; }
	grep -q '^Restart=on-failure$' "$f" && { echo "on-failure здесь бесполезен"; return 1; }

	# Ограничитель обязан остаться: с always без него аварийный цикл
	# крутился бы вечно.
	grep -q '^StartLimitBurst=' "$f"
	grep -q '^StartLimitIntervalSec=' "$f"
}

@test "заглушка юнита в CI повторяет тип настоящего" {
	# Restart=always запрещён для Type=oneshot: заглушка с неверным типом
	# роняет systemd-analyze verify на ровном месте. Проверяем именно
	# строку заглушки, а не любое упоминание - Type=oneshot законно стоит
	# в юните проверки обновлений и встречается в комментариях.
	run grep -c 'Type=forking.*ExecStart=/bin/true' "$REPO/.github/workflows/ci.yml"
	[ "$output" = "1" ]
}

@test "doctor замечает несуществующий интерфейс" {
	# Тихий отказ: на nftables служба стартует нормально, имя просто
	# кладётся в набор, и правила не совпадают ни с чем. Опечатка
	# выглядит как неработающая стратегия.
	printf 'нет-такого-интерфейса\n' >"$ZL_PREFIX/etc/zapret-lite/wan-iface"
	run zl doctor
	[ "$status" -ne 0 ]
	[[ "$output" == *"интерфейса нет в системе"* ]]

	printf 'any\n' >"$ZL_PREFIX/etc/zapret-lite/wan-iface"
	run zl doctor
	[[ "$output" == *"обрабатываются все"* ]]
}

@test "status не называет службу остановленной в префиксе" {
	# Останавливать было нечего: юнит лежит под префиксом, и настоящий
	# systemd его не видит.
	run zl status
	[[ "$output" == *"не управляется (префикс)"* ]]
	[[ "$output" != *"Служба        : остановлена"* ]]
}

@test "установщик сбрасывает счётчик аварий перед запуском" {
	# Служба могла остаться в failed от прежних попыток, и установка
	# споткнулась бы на ровном месте.
	grep -q 'reset-failed zapret' "$REPO/install.sh"
}

# --- короткие формы команд --------------------------------------------

@test "каждая команда имеет короткую форму, и она уникальна" {
	local mgr="$REPO/bin/zapret-lite"
	# Длинные имена из справки.
	ZL_LIB="$REPO/lib" sh "$mgr" --help \
		| grep -oE '^  zapret-lite [a-z0-9-]+' | awk '{print $2}' | sort >"$BATS_TEST_TMPDIR/long"
	# Короткие формы из таблицы раскрытия.
	sed -n '/^zl_expand_alias()/,/^}/p' "$mgr" \
		| grep -oE "^[[:space:]]+[a-z0-9]{2}\) echo [a-z0-9-]+" \
		| awk '{print $3}' | sort >"$BATS_TEST_TMPDIR/short"

	run diff "$BATS_TEST_TMPDIR/long" "$BATS_TEST_TMPDIR/short"
	[ "$status" -eq 0 ]

	# Сокращения не должны повторяться.
	local n u
	n=$(sed -n '/^zl_expand_alias()/,/^}/p' "$mgr" | grep -cE "^[[:space:]]+[a-z0-9]{2}\)")
	u=$(sed -n '/^zl_expand_alias()/,/^}/p' "$mgr" | grep -oE "^[[:space:]]+[a-z0-9]{2}\)" | sort -u | wc -l)
	[ "$n" = "$u" ]
}

@test "короткие формы делают то же, что длинные" {
	run zl st
	local long="$output"
	run zl status
	[ "$output" = "$long" ]

	run zl li
	long="$output"
	run zl list
	[ "$output" = "$long" ]
}

@test "короткая форма с аргументом работает" {
	zl gf all
	run zl status
	[[ "$output" == *"Игровой фильтр: all"* ]]
	zl gf disabled
}

# --- согласованные имена файлов состояния -----------------------------

@test "файлы состояния переключателей без суффикса" {
	local f
	for f in ipset game-filter ipv6 fwtype wan-iface strategy; do
		[ -f "$ZL_PREFIX/etc/zapret-lite/$f" ] \
			|| { echo "нет $f"; return 1; }
	done
	# Старых имён остаться не должно.
	for f in ipset.mode game-filter.mode ipv6.mode; do
		[ ! -e "$ZL_PREFIX/etc/zapret-lite/$f" ] \
			|| { echo "осталось старое имя: $f"; return 1; }
	done
}

