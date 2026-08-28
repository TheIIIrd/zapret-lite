#!/usr/bin/env bash
# Общая обвязка для bats-тестов.
#
# Всё ставится в префикс ZL_PREFIX, поэтому тесты не трогают настоящую
# систему и не требуют прав на /.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO

# Каталоги с распакованными релизами flowseal (v1.10.0, v1.10.2 и т.п.).
# Если их нет, тесты собирают синтетический релиз сами: локальные пути
# разработчика в тестах - гарантия того, что в CI они не запустятся.
: "${ZL_TEST_RELEASES:=$REPO/.test-releases}"

# Дерево апстримного zapret. В тестах нужен только каркас: настоящий
# zapret тут ничего не делает, его init-скрипт заглушён.
: "${ZL_TEST_ZAPRET:=}"

setup_root() {
	ZL_PREFIX="$BATS_TEST_TMPDIR/root"
	export ZL_PREFIX
	mkdir -p "$ZL_PREFIX"
	# Библиотека читается менеджером по этому пути.
	export ZL_LIB="$ZL_PREFIX/opt/zapret-lite/lib"
	export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
	make_fakebin
}

# systemctl больше НЕ подменяется. В режиме префикса код к systemd не
# обращается вовсе - юнит лежит под префиксом, настоящий systemd его не
# видит, так что обращение было бы и бесполезным, и лезущим в систему.
#
# Подмена была вредна: она скрывала дефект. Настоящая установка в
# префикс от обычного пользователя падала на "Failed to connect to bus",
# а тесты этого не видели, потому что говорили с заглушкой.
#
# nft подменяется по другой причине: определение типа firewall от
# обычного пользователя опирается на наличие команды, и без неё
# установщик справедливо откажется работать.
make_fakebin() {
	mkdir -p "$BATS_TEST_TMPDIR/fakebin"
	cat >"$BATS_TEST_TMPDIR/fakebin/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/fakebin/nft"
}

# Собирает комплект для установки: наши файлы + vendor из указанного
# релиза flowseal + макет апстримного zapret.
build_pkg() {
	local dst="$1" fsver="$2" zpver="$3"
	local rel="$ZL_TEST_RELEASES/v$fsver"

	mkdir -p "$dst"

	# Понятное сообщение вместо "cp: cannot stat". Чаще всего причина -
	# каталог не попал в git: шаблон .gitignore для Python содержит
	# строку "lib/".
	for need in lib/common.sh bin/zapret-lite config/base.conf.in \
	            systemd/10-zapret-lite.conf install.sh uninstall.sh; do
		[ -e "$REPO/$need" ] || {
			echo "в репозитории нет $need" >&2
			echo "проверьте: git check-ignore -v $need" >&2
			return 1
		}
	done

	cp -r "$REPO"/lib "$REPO"/bin "$REPO"/config "$REPO"/systemd \
	      "$REPO"/install.sh "$REPO"/uninstall.sh "$dst/"
	mkdir -p "$dst/strategies" "$dst/vendor"

	if [ -d "$rel" ]; then
		python3 "$REPO/tools/vendor-sync.py" "$rel" "$dst/vendor" \
			--version "$fsver" >/dev/null
		python3 "$REPO/tools/import-strategies.py" "$rel" "$dst/strategies" \
			>/dev/null
	else
		synth_release "$dst" "$fsver"
	fi

	make_zapret_tree "$dst" "$zpver"
	# Настоящий install_bin.sh симлинкует выбранный бинарник в nfq/nfqws
	# (install_bin.sh:126). Макет повторяет именно это.
	cat >"$dst/zapret/install_bin.sh" <<'IBIN'
#!/bin/sh
base="$(cd "$(dirname "$0")" && pwd)"
arch=$(find "$base/binaries" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$arch" ] || { echo "no compatible binaries found"; exit 1; }
mkdir -p "$base/nfq"
ln -fs "../binaries/$(basename "$arch")/nfqws" "$base/nfq/nfqws"
exit 0
IBIN
	chmod +x "$dst/zapret/install_bin.sh"
	# Намеренно только в vendor: так проверяется запасной путь поиска
	# версии, из-за отсутствия которого имя поколения выходило
	# "zapret-unknown".
	mkdir -p "$dst/vendor/zapret"
	printf 'zapret_version=%s\n' "$zpver" >"$dst/vendor/zapret/zapret.lock"
}

# Синтетический "релиз": ровно то, что нужно тестам, без зависимости от
# скачанных архивов flowseal. Имена файлов и стратегий совпадают с
# настоящими, чтобы утверждения в тестах не расходились.
synth_release() {
	local dst="$1" fsver="$2" v s n
	mkdir -p "$dst/vendor/flowseal/fake" "$dst/vendor/flowseal/lists" \
	         "$dst/strategies"

	for b in tls_clienthello_www_google_com quic_initial_www_google_com \
	         tls_clienthello_4pda_to stun ACTIVE_DISCORD_UDP; do
		printf 'fake-payload-%s\n' "$b" >"$dst/vendor/flowseal/fake/$b.bin"
	done

	printf 'discord.com\nyoutube.com\n' \
		>"$dst/vendor/flowseal/lists/list-general.txt"
	printf 'googlevideo.com\n' >"$dst/vendor/flowseal/lists/list-google.txt"
	printf 'steampowered.com\n' >"$dst/vendor/flowseal/lists/list-exclude.txt"
	printf '203.0.113.0/24\n' >"$dst/vendor/flowseal/lists/ipset-exclude.txt"
	# Больше 30000 строк: тест на режим loaded смотрит на размер.
	# Число строк намеренно разное у разных версий: тест отката
	# убеждается, что ipset-all пересобран из своего поколения.
	case "$fsver" in
		1.10.2) n=32200 ;;
		*)      n=31100 ;;
	esac
	seq 0 "$n" | awk '{printf "10.%d.%d.0/24\n", int($1/256), $1%256}' \
		>"$dst/vendor/flowseal/lists/ipset-all.full.txt"
	printf 'Loopback = "PING:127.0.0.1"\n' >"$dst/vendor/flowseal/targets.txt"

	# general и general-alt11 - обе есть всегда; general-alt13 только в
	# "новом" релизе, на этом построены тесты про исчезнувшую стратегию.
	s="general general-alt5 general-alt11"
	[ "$fsver" = 1.10.2 ] && s="$s general-alt13"
	for v in $s; do
		synth_strategy "$dst/strategies/$v.conf"
	done

	printf 'flowseal_version=%s\nengine_nfqws_version=72.9\nsynced_utc=%s\n' \
		"$fsver" "1970-01-01T00:00:00Z" \
		>"$dst/vendor/flowseal/flowseal.lock"
	( cd "$dst/vendor/flowseal" \
	  && find . -type f -printf '%P\n' | sort | xargs sha256sum >../m.tmp )
	mv "$dst/vendor/m.tmp" "$dst/vendor/flowseal/MANIFEST.sha256"
}

synth_strategy() {
	cat >"$1" <<'STRAT'
NFQWS_ENABLE=1
NFQWS_PORTS_TCP="80,443,2053,2083,2087,2096,8443,$GAME_FILTER_TCP"
NFQWS_PORTS_UDP="443,19294-19344,50000-50100,$GAME_FILTER_UDP"

NFQWS_OPT="
--filter-tcp=80,443 --hostlist=$ZAPRET_LISTS_DIR/list-general.txt --hostlist=$ZAPRET_LOCAL_LISTS_DIR/list-general-user.txt --hostlist-exclude=$ZAPRET_LISTS_DIR/list-exclude.txt --hostlist-exclude=$ZAPRET_LOCAL_LISTS_DIR/list-exclude-user.txt --ipset=$ZAPRET_LOCAL_LISTS_DIR/ipset-all.txt --ipset-exclude=$ZAPRET_LOCAL_LISTS_DIR/ipset-exclude-user.txt --dpi-desync=fake --dpi-desync-fake-tls=$ZAPRET_FAKE_DIR/tls_clienthello_4pda_to.bin --new
--filter-udp=443 --dpi-desync=fake --dpi-desync-fake-quic=$ZAPRET_FAKE_DIR/quic_initial_www_google_com.bin
"
STRAT
}

# Каркас апстримного zapret. Настоящие common/*.sh и init.d тестам не
# нужны: служба заглушена, а проверяется раскладка и логика.
make_zapret_tree() {
	local dst="$1" zpver="$2" arch up
	arch="$(uname -m)"
	# Имена каталогов - как у настоящего zapret: linux-x86_64 и т.п.
	# Макет с binaries/$(uname -m) закреплял бы неверную схему.
	case "$arch" in
		x86_64)  up=linux-x86_64 ;;
		aarch64) up=linux-arm64 ;;
		armv7l)  up=linux-arm ;;
		*)       up=linux-$arch ;;
	esac
	mkdir -p "$dst/zapret/init.d/sysv" "$dst/zapret/init.d/systemd" \
	         "$dst/zapret/binaries/$up" "$dst/zapret/ipset" \
	         "$dst/zapret/common"
	printf '#!/bin/sh\ncase "$1" in --version) echo v%s ;; esac\nexit 0\n' \
		"$zpver" >"$dst/zapret/binaries/$up/nfqws"
	chmod +x "$dst/zapret/binaries/$up/nfqws"

	printf '#!/bin/sh\nexit 0\n' >"$dst/zapret/init.d/sysv/zapret"
	printf '[Unit]\nDescription=zapret\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
		>"$dst/zapret/init.d/systemd/zapret.service"
	printf '# stub\n' >"$dst/zapret/common/base.sh"
	printf '#!/bin/sh\nexit 0\n' >"$dst/zapret/ipset/get_config.sh"
	chmod +x "$dst/zapret/init.d/sysv/zapret"
}

install_pkg() {
	local pkg="$1"; shift
	( cd "$pkg" && sh install.sh "$@" )
}

zl() {
	sh "$ZL_PREFIX/usr/local/bin/zapret-lite" "$@"
}

# Загружает итоговый конфиг через dash - ровно так, как это делает
# init-скрипт zapret (init.d/sysv/functions:6, шебанг /bin/sh).
load_config() {
	dash -c ". $ZL_PREFIX/opt/zapret/config; $1"
}

gen_count() {
	find "$ZL_PREFIX/opt/zapret-lite/versions" -mindepth 1 -maxdepth 1 \
		-type d 2>/dev/null | wc -l
}
