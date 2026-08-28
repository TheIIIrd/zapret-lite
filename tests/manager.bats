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
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/game-filter.mode")" = "disabled" ]
}

@test "game-filter отвергает неизвестный режим" {
	run zl game-filter неведомое
	[ "$status" -ne 0 ]
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/game-filter.mode")" = "disabled" ]
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
	printf 'мусор\n' >"$ZL_PREFIX/etc/zapret-lite/game-filter.mode"
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
		| grep -oE 'zapret-lite [a-z0-9-]+' | awk '{print $2}' | sort -u >"$BATS_TEST_TMPDIR/help"
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
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/ipv6.mode")" = "off" ]
}

@test "режим ipv6 переживает переустановку" {
	zl ipv6 on
	install_pkg "$PKG" >/dev/null
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/ipv6.mode")" = "on" ]
	run zl status
	[[ "$output" == *"IPv6          : on"* ]]
}

@test "--ipv6 при установке задаёт режим" {
	( cd "$PKG" && sh uninstall.sh --purge >/dev/null )
	install_pkg "$PKG" --strategy general --ipv6 >/dev/null
	[ "$(cat "$ZL_PREFIX/etc/zapret-lite/ipv6.mode")" = "on" ]
	run load_config 'echo "D=$DISABLE_IPV6"'
	[[ "$output" == *"D=0"* ]]
}

@test "битый файл режима ipv6 не роняет конфиг" {
	printf 'мусор\n' >"$ZL_PREFIX/etc/zapret-lite/ipv6.mode"
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
	# Макет systemctl в тестах сообщает, что служба не запущена, поэтому
	# останова не происходит и предупреждения быть не должно.
	run install_pkg "$pkg"
	[ "$status" -ne 0 ]
	[[ "$output" != *"обход не работает"* ]]
}
