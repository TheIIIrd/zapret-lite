#!/bin/sh
# shellcheck disable=SC3043  # 'local' не в POSIX, но есть в dash/ash/bash;
#                              апстримный zapret использует его повсеместно
# Общие функции zapret-lite.

ZL_PREFIX="${ZL_PREFIX:-}"
ZL_ZAPRET_DIR="$ZL_PREFIX/opt/zapret"
ZL_BASE="$ZL_PREFIX/opt/zapret-lite"
ZL_ETC="$ZL_PREFIX/etc/zapret-lite"
# shellcheck disable=SC2034  # используется установщиком и менеджером
ZL_BIN="$ZL_PREFIX/usr/local/bin"
# shellcheck disable=SC2034  # используется установщиком и менеджером
ZL_SYSTEMD_DIR="$ZL_PREFIX/etc/systemd/system"

ZL_VERSIONS="$ZL_BASE/versions"
ZL_CURRENT="$ZL_BASE/current"
ZL_PREVIOUS="$ZL_BASE/previous"
ZL_SHIM_HASH_FILE="$ZL_BASE/.config.sha256"
# shellcheck disable=SC2034  # используется деинсталлятором
# Метка, что /opt/zapret поставили мы. Без неё чужую установку не сносим.
ZL_OWNED_MARKER="$ZL_ZAPRET_DIR/.zapret-lite-owned"

# Сколько поколений держим. Меньше трёх смысла нет: текущее, для отката
# и ещё одно на случай, что откат тоже не помог.
ZL_KEEP_GENERATIONS="${ZL_KEEP_GENERATIONS:-3}"

# --- вывод ------------------------------------------------------------

zl_info()  { printf '[ + ] %s\n' "$*"; }
zl_warn()  { printf '[ ! ] %s\n' "$*" >&2; }
zl_error() { printf '[ - ] %s\n' "$*" >&2; }
zl_step()  { printf '\n=== %s\n' "$*"; }

zl_die() {
	zl_error "$*"
	exit 1
}

# --- проверки ---------------------------------------------------------

# shellcheck disable=SC2120  # аргументы необязательны
zl_require_root() {
	[ "$(id -u)" = 0 ] && return 0
	# Установка в префикс ничего не делает с настоящей системой: все пути
	# уезжают под $ZL_PREFIX. Именно так работают тесты, и требовать там
	# root бессмысленно - в CI они выполняются от обычного пользователя.
	[ -n "$ZL_PREFIX" ] && return 0
	zl_die "нужны права root. Запустите скрипт через sudo."
}

# chown имеет смысл только от root. В префиксе файлы и так принадлежат
# тому, кто запустил, и попытка сменить владельца просто провалится.
zl_chown() {
	[ "$(id -u)" = 0 ] || return 0
	chown "$@"
}

zl_have() {
	command -v "$1" >/dev/null 2>&1
}

zl_sha256() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# Проверка каталога по его MANIFEST.sha256.
#
# $2 = strict - дополнительно ловит ЛИШНИЕ файлы. sha256sum -c их не
# замечает, а подброшенная strategies/evil.conf - это shell-код, который
# прекрасно выберется через zapret-lite use. Для vendor-каталога строгий
# режим не нужен: он целиком пересоздаётся синхронизацией.
zl_verify_manifest() {
	# $1 - каталог, $2 - "strict" или пусто
	local dir rc listed present extra
	dir="$1"
	rc=0

	[ -r "$dir/MANIFEST.sha256" ] || {
		zl_error "нет $dir/MANIFEST.sha256"
		return 2
	}

	( cd "$dir" && sha256sum --quiet -c MANIFEST.sha256 ) || rc=1

	[ "${2:-}" = strict ] || return $rc

	listed="$(mktemp)"
	present="$(mktemp)"
	sed 's/^[0-9a-f]*  //' "$dir/MANIFEST.sha256" | sort >"$listed"
	# Каталоги, которых в релизном комплекте не бывает. При установке из
	# дерева репозитория они есть и лишними не считаются.
	# Список исключений обязан совпадать со SKIP_DIRS в
	# tools/make-package-manifest.py, причём и по глубине: там пропуск
	# работает на любом уровне вложенности, значит и здесь тоже.
	# Когда правила разошлись, файлы zapret/.github/* попали в проверку,
	# но не в манифест, и установка обрывалась на "лишних файлах".
	( cd "$dir" && find . -type f \
	    ! -path '*/.git/*' ! -path '*/.github/*' ! -path '*/tests/*' \
	    ! -path '*/dist/*' ! -name '*.pyc' ! -path '*/__pycache__/*' \
	    ! -name MANIFEST.sha256 -printf '%P\n' ) | sort >"$present"

	extra="$(comm -13 "$listed" "$present")"
	rm -f "$listed" "$present"

	if [ -n "$extra" ]; then
		printf '%s\n' "$extra" | while IFS= read -r f; do
			[ -n "$f" ] && zl_error "лишний файл в комплекте: $f"
		done
		rc=1
	fi
	return $rc
}

# Доступен ли путь на запись кому-то кроме владельца.
#
# Отдельной функцией, а не строчкой внутри doctor: в doctor эта проверка
# работает только при настоящей установке от root, то есть в тестах не
# исполняется вовсе. Как функцию её можно вызвать напрямую и проверить
# на самом деле.
zl_group_or_world_writable() {
	# $1 - путь. 0 - доступен посторонним, 1 - нет или неизвестно.
	local mode
	mode=$(stat -c '%a' "$1" 2>/dev/null) || return 1
	case "$mode" in
		?)  mode="00$mode" ;;
		??) mode="0$mode" ;;
	esac
	# Смотрим последние два разряда: группа и остальные.
	case "${mode#"${mode%??}"}" in
		*[2367]*) return 0 ;;
		*)        return 1 ;;
	esac
}

# Имя стратегии попадает в путь, поэтому проверяется до использования.
zl_valid_name() {
	case "$1" in
		""|*[!A-Za-z0-9._-]*) return 1 ;;
		.*) return 1 ;;
		*) return 0 ;;
	esac
}

# --- определение системы ----------------------------------------------

zl_detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64)   echo x86_64 ;;
		aarch64|arm64)  echo aarch64 ;;
		armv7l|armv7)   echo arm ;;
		*)              uname -m ;;
	esac
}

zl_detect_fwtype() {
	# Запрос к nft требует прав: от обычного пользователя "nft list
	# tables" всегда неудачен, и проверка "установлен ли nft" по нему
	# давала бы неверное "не найдены ни nft, ни iptables". Поэтому
	# опрашиваем ядро только от root, иначе судим по наличию команды.
	if [ "$(id -u)" = 0 ]; then
		if zl_have nft && nft list tables >/dev/null 2>&1; then
			echo nftables
			return 0
		fi
	elif zl_have nft; then
		echo nftables
		return 0
	fi
	if zl_have iptables; then
		echo iptables
	else
		echo ""
	fi
}

# Доступен ли выбранный тип firewall на этой машине.
#
# Режим iptables требует не только сам iptables, но и ipset: апстрим
# перечисляет их вместе в списке зависимостей (common/installer.sh:633),
# а create_ipset.sh вызывает "ipset -! restore". В Debian и производных
# пакет ipset по умолчанию не стоит, и без него правила не применяются -
# служба стартует, а обхода нет.
zl_fwtype_available() {
	# $1 - iptables | nftables | auto
	local missing=
	case "$1" in
		nftables)
			zl_have nft || missing="nft"
			;;
		iptables)
			zl_have iptables || missing="iptables"
			zl_have ip6tables || missing="${missing:+$missing }ip6tables"
			zl_have ipset || missing="${missing:+$missing }ipset"
			;;
		*)
			return 0
			;;
	esac
	[ -z "$missing" ] && return 0
	zl_error "для режима $1 не хватает команд: $missing"
	case "$1" in
		iptables) zl_error "$(zl_install_hint 'iptables ipset')" ;;
		nftables) zl_error "$(zl_install_hint nftables)" ;;
	esac
	return 1
}

# Подсказка по установке пакетов для текущего дистрибутива.
#
# Совет "sudo apt install" на Arch или Fedora бесполезен, а проект
# заявлен для Debian, Ubuntu, Mint, RHEL, Fedora, openSUSE и Arch.
# Определяем по наличию менеджера пакетов, а не по /etc/os-release:
# производных дистрибутивов слишком много, чтобы перечислять их имена.
zl_install_hint() {
	# $1 - имена пакетов через пробел
	if zl_have apt-get; then
		printf 'Установите и повторите: sudo apt install %s' "$1"
	elif zl_have dnf; then
		printf 'Установите и повторите: sudo dnf install %s' "$1"
	elif zl_have pacman; then
		printf 'Установите и повторите: sudo pacman -S %s' "$1"
	elif zl_have zypper; then
		printf 'Установите и повторите: sudo zypper install %s' "$1"
	else
		printf 'Установите пакеты (%s) средствами вашего дистрибутива' "$1"
	fi
}

# Меняет переключатель, влияющий на СОСТАВ правил firewall.
#
# Обычный restart здесь не годится: ExecStop читает конфиг заново, уже с
# новым значением, и zapret снимает не те правила, что ставил. Старые
# остаются висеть, а снять их нечем - каталог к тому времени описывает
# другую конфигурацию.
#
# Так уже случилось с типом firewall (снимал бы правила не в той
# подсистеме) и так же вело бы себя выключение IPv6 в режиме iptables:
# добавление и удаление идут через один и тот же
# [ "$DISABLE_IPV6" = 1 ] || (common/ipt.sh:413).
#
# Поэтому: остановить старым конфигом, записать, запустить новым.
zl_switch_state() {
	# $1 - файл состояния, $2 - новое значение
	local file="$1" value="$2" was_active=0 old=''

	[ -r "$file" ] && read -r old <"$file"

	if zl_manage_systemd && systemctl is-active --quiet zapret 2>/dev/null; then
		was_active=1
		systemctl stop zapret \
			|| zl_die "не удалось остановить службу; значение не изменено"
	fi

	printf '%s\n' "$value" >"$file"
	chmod 0644 "$file"

	[ "$was_active" = 1 ] || return 0

	# Намеренная остановка и запуск не должны копиться в счётчике
	# аварийных перезапусков: иначе несколько переключений подряд
	# упираются в start-limit-hit, хотя ничего не ломалось.
	systemctl reset-failed zapret >/dev/null 2>&1 || true
	if systemctl start zapret; then
		return 0
	fi

	# Служба не поднялась с новым значением. Оставлять человека без
	# работающего обхода из-за опечатки нельзя: возвращаем прежнее.
	# Так, например, "wan-iface ens32" вместо "ens33" перестаёт быть
	# необратимой ошибкой.
	zl_error "служба не запустилась с новым значением '$value'."
	if [ -n "$old" ]; then
		printf '%s\n' "$old" >"$file"
		chmod 0644 "$file"
		systemctl reset-failed zapret >/dev/null 2>&1 || true
		if systemctl start zapret; then
			zl_error "значение возвращено к '$old', служба работает."
		else
			zl_error "возврат к '$old' тоже не помог."
			zl_error "Смотрите: journalctl -u zapret -n 50"
		fi
	else
		zl_error "Смотрите: journalctl -u zapret -n 50"
	fi
	return 1
}

# Гипервизор, если машина виртуальная.
#
# Апстрим предупреждает об этом не зря (common/virt.sh:24): VMware и
# VirtualBox с внутренним NAT ломают большинство техник обхода. Человек
# перебирает двадцать стратегий, ни одна не работает, и причина вовсе
# не в них. Мост вместо NAT обычно решает.
zl_detect_virt() {
	# Инициализация обязательна: в dash "local vm" оставляет переменную
	# неустановленной, и под set -u обращение к ней роняет скрипт. Это
	# всплыло на машине без systemd-detect-virt.
	local vm='' s='' v=''
	if zl_have systemd-detect-virt; then
		vm=$(systemd-detect-virt --vm 2>/dev/null) || vm=
	elif [ -r /sys/class/dmi/id/product_name ]; then
		read -r s </sys/class/dmi/id/product_name || s=
		for v in KVM QEMU VMware VMW VirtualBox Xen Bochs Parallels BHYVE Hyper-V; do
			case "$s" in "$v"*) vm="$v"; break ;; esac
		done
	fi
	printf '%s' "$vm" | tr '[:upper:]' '[:lower:]'
}

# Известно ли, что этот гипервизор мешает обходу.
zl_virt_breaks_bypass() {
	case "$1" in
		vmware|oracle|virtualbox|vmw*) return 0 ;;
		*) return 1 ;;
	esac
}

# Подключён ли кто-нибудь к очереди NFQUEUE с указанным номером.
#
# Различает три исхода, и это важно: 0 - подключён, 1 - нет, 2 - узнать
# не удалось. Файл /proc/net/netfilter/nfnetlink_queue читается только
# root, и от обычного пользователя его недоступность не значит, что
# очередь пуста.
#
# Второй аргумент нужен тестам: без него функцию можно было бы проверить
# только на живой системе с работающим nfqws.
zl_queue_attached() {
	# $1 - номер очереди, $2 - файл (по умолчанию системный)
	local num="$1" file="${2:-/proc/net/netfilter/nfnetlink_queue}" q
	[ -r "$file" ] || return 2
	while read -r q _; do
		[ "$q" = "$num" ] && return 0
	done <"$file"
	return 1
}

zl_systemd_ok() {
	[ -d /run/systemd/system ] && zl_have systemctl
}

# Можно ли нам вообще управлять systemd.
#
# В режиме префикса - нельзя, и не потому что запрещено, а потому что
# бессмысленно: юнит лежит под $ZL_PREFIX, настоящий systemd его не
# видит. Обращение к нему в этом случае и не помогает, и лезет в
# систему, которую префикс как раз должен уберечь.
zl_manage_systemd() {
	[ -z "$ZL_PREFIX" ] || return 1
	zl_systemd_ok
}

# --- шаблоны ----------------------------------------------------------

zl_render() {
	# $1 - шаблон, $2 - результат
	sed -e "s|@ZL_BASE@|$ZL_BASE|g" \
	    -e "s|@ZL_ETC@|$ZL_ETC|g" \
	    -e "s|@ZL_ZAPRET_DIR@|$ZL_ZAPRET_DIR|g" \
	    "$1" >"$2"
	chmod 0644 "$2"
}

# --- поколения --------------------------------------------------------
#
# Поколение - неизменяемый снимок того, что приезжает из релиза: фейки,
# вендорные списки, стратегии и base.conf. Пользовательские файлы в
# $ZL_ETC поколениями НЕ управляются и при откате не трогаются.
#
# Переключение - смена симлинка через rename(), то есть атомарно.
# Откат работает и через минуту, и через месяц, и не требует сети.

zl_lock_get() {
	# $1 - lock-файл, $2 - ключ
	local v
	[ -r "$1" ] || return 1
	v=$(sed -n "s/^$2=//p" "$1" | head -1)
	# Пустое значение - это тоже "не нашли": иначе вызывающий не сможет
	# отличить отсутствующий ключ от найденного и уйдёт с пустой строкой.
	[ -n "$v" ] || return 1
	printf '%s\n' "$v"
}

zl_generation_id() {
	# $1 - каталог комплекта
	local fs zp
	fs=$(zl_lock_get "$1/vendor/flowseal/flowseal.lock" flowseal_version) || fs=
	# Релизный комплект кладёт lock рядом с деревом zapret. При ручной
	# сборке его там нет, но в репозитории он есть всегда - иначе имя
	# поколения получалось бы "zapret-unknown".
	zp=$(zl_lock_get "$1/zapret/zapret.lock" zapret_version) \
		|| zp=$(zl_lock_get "$1/vendor/zapret/zapret.lock" zapret_version) \
		|| zp=
	printf '%s_flowseal-%s_zapret-%s\n' \
		"$(date -u +%Y-%m-%d)" "${fs:-unknown}" "${zp:-unknown}"
}

zl_generation_list() {
	# Имя начинается с YYYY-MM-DD, поэтому сортировка по имени - это
	# сортировка по дате.
	[ -d "$ZL_VERSIONS" ] || return 0
	find "$ZL_VERSIONS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

zl_generation_current() {
	[ -L "$ZL_CURRENT" ] || return 1
	basename "$(readlink -f "$ZL_CURRENT")"
}

zl_generation_previous() {
	[ -L "$ZL_PREVIOUS" ] || return 1
	basename "$(readlink -f "$ZL_PREVIOUS")"
}

zl_generation_switch() {
	# $1 - имя поколения
	local target old
	target="$ZL_VERSIONS/$1"

	[ -d "$target" ] || {
		zl_error "нет поколения $1"
		return 1
	}
	zl_verify_manifest "$target" || {
		zl_error "поколение $1 повреждено, переключение отменено"
		return 1
	}

	old=$(zl_generation_current 2>/dev/null) || old=

	# Симлинк создаётся рядом и переезжает через rename: current в любой
	# момент указывает либо на старое, либо на новое, но никогда никуда.
	ln -sfn "$target" "$ZL_CURRENT.new"
	mv -T "$ZL_CURRENT.new" "$ZL_CURRENT"

	if [ -n "$old" ] && [ "$old" != "$1" ]; then
		ln -sfn "$ZL_VERSIONS/$old" "$ZL_PREVIOUS.new"
		mv -T "$ZL_PREVIOUS.new" "$ZL_PREVIOUS"
	fi
	return 0
}

zl_generation_prune() {
	local keep cur prev all n g
	keep="$ZL_KEEP_GENERATIONS"
	cur=$(zl_generation_current 2>/dev/null) || cur=
	prev=$(zl_generation_previous 2>/dev/null) || prev=

	all=$(zl_generation_list | sort -r)
	n=0
	for g in $all; do
		n=$((n + 1))
		[ "$n" -le "$keep" ] && continue
		[ "$g" = "$cur" ] && continue
		[ "$g" = "$prev" ] && continue
		rm -rf "${ZL_VERSIONS:?}/$g"
		zl_info "удалено старое поколение: $g"
	done
}

# --- переключаемое состояние ------------------------------------------
#
# ipset-all.txt собирается из ТЕКУЩЕГО поколения, поэтому его надо
# перематериализовать после каждого переключения. Иначе после отката
# останется список от версии, от которой откатились.

zl_apply_ipset_mode() {
	local mode src dst tmp
	dst="$ZL_ETC/lists/ipset-all.txt"
	src="$ZL_CURRENT/lists/ipset-all.full.txt"

	if [ -r "$ZL_ETC/ipset" ]; then
		read -r mode <"$ZL_ETC/ipset"
	else
		mode=loaded
	fi

	# Запись атомарная. nfqws перечитывает список по mtime (ipset.c:193)
	# и вполне может прочитать файл на середине записи полумегабайта.
	tmp="$dst.tmp.$$"
	case "$mode" in
		loaded)
			[ -r "$src" ] || { zl_error "нет $src"; return 1; }
			cp -f "$src" "$tmp"
			;;
		none)  echo '203.0.113.113/32' >"$tmp" ;;
		any)   : >"$tmp" ;;
		*)     zl_error "неизвестный режим ipset: $mode"; return 1 ;;
	esac
	chmod 0644 "$tmp"
	mv -f "$tmp" "$dst"
	printf '%s\n' "$mode"
}

# --- защита ручных правок ---------------------------------------------

zl_shim_is_ours() {
	local cfg current stored
	cfg="$ZL_ZAPRET_DIR/config"

	[ -f "$cfg" ] || return 0
	[ -f "$ZL_SHIM_HASH_FILE" ] || return 1

	current=$(zl_sha256 "$cfg")
	stored=$(cat "$ZL_SHIM_HASH_FILE" 2>/dev/null)
	[ -n "$current" ] && [ "$current" = "$stored" ]
}

zl_write_shim() {
	# $1 - путь к готовому шиму
	local cfg
	cfg="$ZL_ZAPRET_DIR/config"

	if ! zl_shim_is_ours; then
		if [ "${ZL_FORCE:-0}" = 1 ]; then
			zl_warn "$cfg изменён вручную, перезаписываю (--force)"
			cp -f "$cfg" "$cfg.zapret-lite-backup"
			zl_info "старая версия сохранена: $cfg.zapret-lite-backup"
		else
			zl_error "$cfg изменён вручную или создан не нами."
			zl_error "Перенесите свои правки в $ZL_ETC/local.conf и"
			zl_error "повторите, либо запустите с --force (будет сделана копия)."
			return 1
		fi
	fi

	install -m 0644 "$1" "$cfg"
	mkdir -p "$(dirname "$ZL_SHIM_HASH_FILE")"
	zl_sha256 "$cfg" >"$ZL_SHIM_HASH_FILE"
	chmod 0644 "$ZL_SHIM_HASH_FILE"
}
