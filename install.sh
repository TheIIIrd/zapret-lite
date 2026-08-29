#!/bin/sh
# Установщик zapret-lite.
#
# Ставит апстримный zapret из комплекта, свои данные поверх и юнит systemd.
# Идемпотентен: повторный запуск приводит систему в то же состояние.
#
#   ./install.sh [--strategy ИМЯ] [--force] [--dry-run]
#
# Что НЕ делается намеренно:
#   - не трогается sysctl, SELinux, /etc/hosts, ~/.bashrc
#   - не ставится zapret-list-update.timer (GETLIST пуст, таймер пустой)
#   - не навязывается FWTYPE: автоопределение, явный выбор - в local.conf
#   - не угадывается способ повышения прав: нужен root, и точка

set -eu

# Права выставляются явно, но mkdir/cp зависят от umask вызывающего.
# При umask 077 каталоги получились бы 700 и nfqws не прочитал бы списки.
umask 022

SRC="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

STRATEGY=
STRATEGY_EXPLICIT=0
IPV6_MODE=
FWTYPE_MODE=
WAN_IFACE=
EFFECTIVE_FWTYPE=
DRY_RUN=0
ZL_FORCE=0

usage() {
	cat <<EOF
Использование: $0 [опции]

  --strategy ИМЯ   стратегия для активации (по умолчанию: general)
  --ipv6           обрабатывать также трафик IPv6
  --no-ipv6        не обрабатывать IPv6 (по умолчанию)
  --fwtype ТИП     auto | iptables | nftables (по умолчанию auto)
  --wan-iface ИМЯ  обрабатывать только этот интерфейс, "any" - все
  --force          перезаписать /opt/zapret/config, даже если он правлен руками
  --dry-run        показать, что будет сделано, ничего не менять
  --list           показать доступные стратегии и выйти
  -h, --help       эта справка
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--strategy) STRATEGY="${2:?--strategy требует аргумент}"; STRATEGY_EXPLICIT=1; shift 2 ;;
		--strategy=*) STRATEGY="${1#*=}"; STRATEGY_EXPLICIT=1; shift ;;
		--ipv6)    IPV6_MODE=on; shift ;;
		--no-ipv6) IPV6_MODE=off; shift ;;
		--fwtype)  FWTYPE_MODE="${2:?--fwtype требует аргумент}"; shift 2 ;;
		--fwtype=*) FWTYPE_MODE="${1#*=}"; shift ;;
		--wan-iface)  WAN_IFACE="${2:?--wan-iface требует аргумент}"; shift 2 ;;
		--wan-iface=*) WAN_IFACE="${1#*=}"; shift ;;
		--force)   ZL_FORCE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--list)
			for f in "$SRC"/strategies/*.conf; do
				[ -e "$f" ] || continue
				b="$(basename "$f")"
				printf '  %s\n' "${b%.conf}"
			done
			exit 0
			;;
		-h|--help) usage; exit 0 ;;
		*) zl_die "неизвестная опция: $1 (см. --help)" ;;
	esac
done
export ZL_FORCE

run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '      would: %s\n' "$*"
	else
		"$@"
	fi
}

# =====================================================================
# 1. Предусловия
# =====================================================================
zl_step "Проверка системы"

[ "$DRY_RUN" = 1 ] || zl_require_root

if [ -n "$ZL_PREFIX" ]; then
	zl_info "установка в префикс $ZL_PREFIX: systemd не задействуется"
elif zl_systemd_ok; then
	zl_info "systemd: есть"
else
	zl_die "systemd не обнаружен. zapret-lite поддерживает только systemd-системы."
fi

ARCH="$(zl_detect_arch)"
zl_info "архитектура: $ARCH"

# Каталог под архитектуру не угадываем: у апстрима они называются
# linux-x86_64, linux-arm64, linux-arm и так далее, а выбор с проверкой
# запуска делает сам install_bin.sh. Наше дело - убедиться, что выбирать
# есть из чего, и проверить результат.
if [ ! -d "$SRC/zapret/binaries" ] ||
   [ -z "$(ls -A "$SRC/zapret/binaries" 2>/dev/null)" ]; then
	zl_die "в комплекте нет бинарников zapret.
      Так выглядит дерево репозитория: бинарники в git не хранятся, они
      добавляются при сборке релиза. Возьмите готовый комплект со
      страницы Releases, либо соберите zapret сами:
        docs/development.md, раздел «Сборка zapret из исходников»"
fi

VIRT="$(zl_detect_virt)"
if [ -n "$VIRT" ] && [ "$VIRT" != none ]; then
	if zl_virt_breaks_bypass "$VIRT"; then
		zl_warn "обнаружена виртуализация $VIRT."
		zl_warn "Её внутренний NAT ломает большинство техник обхода:"
		zl_warn "стратегии будут перебираться безрезультатно."
		zl_warn "Переключите сеть виртуальной машины с NAT на мост."
	else
		zl_info "виртуализация: $VIRT"
	fi
fi

FWTYPE="$(zl_detect_fwtype)"
[ -n "$FWTYPE" ] || zl_die "не найдены ни nft, ни iptables. Установите один из них."

# Выбор стратегии - состояние пользователя. Обновление его не меняет:
# без явного --strategy берём уже выбранную, и только при первой
# установке падаем на general.
if [ "$STRATEGY_EXPLICIT" = 0 ]; then
	if [ -r "$ZL_ETC/strategy" ]; then
		read -r STRATEGY <"$ZL_ETC/strategy"
		zl_info "стратегия сохранена с прошлой установки"
	else
		STRATEGY=general
	fi
fi
zl_valid_name "$STRATEGY" || zl_die "недопустимое имя стратегии: $STRATEGY"

# Проверяем ПРЕЖДЕ, чем что-либо менять. Иначе отказ на последнем шаге
# оставил бы систему с новым поколением и старым конфигом.
if ! zl_shim_is_ours && [ "$ZL_FORCE" = 0 ]; then
	zl_error "$ZL_ZAPRET_DIR/config изменён вручную или создан не нами."
	zl_error "Перенесите правки в $ZL_ETC/local.conf, либо запустите с --force."
	exit 1
fi

# Тип firewall решается ЗДЕСЬ, до единого изменения в системе.
# Раньше проверка стояла в секции 6: установщик успевал остановить
# службу, скопировать zapret и собрать поколение, и только потом
# отказывался. Оставлять человека без работающего обхода из-за
# отсутствующего пакета - плохой размен.
if [ -n "$FWTYPE_MODE" ]; then
	case "$FWTYPE_MODE" in
		auto|iptables|nftables) ;;
		*) zl_die "--fwtype: допустимо auto, iptables или nftables" ;;
	esac
	EFFECTIVE_FWTYPE="$FWTYPE_MODE"
elif [ -r "$ZL_ETC/fwtype" ]; then
	read -r EFFECTIVE_FWTYPE <"$ZL_ETC/fwtype"
else
	EFFECTIVE_FWTYPE=auto
fi
# auto означает "тот, который выберет zapret", то есть определённый выше.
# Сообщение одно, и оно про то, что будет использовано на самом деле.
# Раньше здесь печаталось ещё и автоопределение - и при явном
# "--fwtype iptables" строка "firewall: nftables" сбивала с толку,
# заставляя думать, что флаг проигнорирован.
if [ "$EFFECTIVE_FWTYPE" = auto ]; then
	EFFECTIVE_FWTYPE="$FWTYPE"
	zl_fwtype_available "$EFFECTIVE_FWTYPE" || exit 1
	zl_info "firewall: $EFFECTIVE_FWTYPE (автоопределение; зафиксировать: --fwtype)"
else
	zl_fwtype_available "$EFFECTIVE_FWTYPE" || exit 1
	zl_info "firewall: $EFFECTIVE_FWTYPE (задан явно)"
fi

if [ -n "$WAN_IFACE" ]; then
	case "$WAN_IFACE" in
		*[!A-Za-z0-9._@:-\ ]*) zl_die "--wan-iface: недопустимое имя интерфейса" ;;
	esac
fi

STRATEGY_SRC="$SRC/strategies/$STRATEGY.conf"
[ -f "$STRATEGY_SRC" ] || {
	# Стратегия могла исчезнуть в новом релизе. Молча подменять её нельзя:
	# пользователь получит другое поведение и не поймёт почему.
	zl_error "в этом комплекте нет стратегии '$STRATEGY'."
	zl_error "Доступные: $0 --list"
	zl_error "Выберите явно: $0 --strategy <имя>"
	exit 1
}
zl_info "стратегия: $STRATEGY"

if [ -e /proc/net/netfilter/nfnetlink_queue ] || zl_have modprobe; then
	:
else
	zl_warn "не удалось убедиться, что доступен nfnetlink_queue"
fi

# =====================================================================
# 2. Целостность комплекта
# =====================================================================
zl_step "Проверка целостности комплекта"

# Манифест комплекта покрывает ВСЁ, включая то, что исполняется от root:
# strategies/*.conf читаются через '.', lib и bin запускаются, в zapret
# лежит nfqws. Манифест только для данных flowseal защищал бы самое
# безобидное и оставлял без внимания самое опасное.
if [ -f "$SRC/MANIFEST.sha256" ]; then
	if zl_verify_manifest "$SRC" strict; then
		zl_info "комплект цел: манифест сходится"
	else
		zl_die "комплект не сходится с манифестом, установка прервана"
	fi
else
	# Дерево репозитория манифеста не имеет - он появляется при сборке
	# релиза. Ставить из репозитория можно, но об этом надо знать.
	zl_warn "нет MANIFEST.sha256: комплект не проверен на целостность."
	zl_warn "Так выглядит установка из дерева репозитория, а не из релиза."
fi

if [ -f "$SRC/vendor/flowseal/MANIFEST.sha256" ]; then
	if zl_verify_manifest "$SRC/vendor/flowseal"; then
		zl_info "vendor/flowseal: манифест сходится"
	else
		zl_die "vendor/flowseal: манифест не сходится, установка прервана"
	fi
else
	zl_die "нет vendor/flowseal/MANIFEST.sha256"
fi

# =====================================================================
# 2b. Выполнимость установки
# =====================================================================
#
# Печатать "would: cp ..." и не проверять, получится ли этот cp - значит
# давать ложное чувство проверенности. Здесь проверяется то, что
# действительно может помешать: права на каталоги и место на диске.
zl_step "Проверка выполнимости"

for d in "$ZL_ZAPRET_DIR" "$ZL_BASE" "$ZL_ETC" "$ZL_BIN" "$ZL_SYSTEMD_DIR"; do
	# Ищем ближайшего существующего предка: сам каталог мы создадим.
	probe="$d"
	# Поднимаемся, пока не найдём существующий каталог. Останавливаться
	# на $ZL_PREFIX нельзя: в тестах его самого ещё нет.
	while [ ! -e "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
		probe=$(dirname "$probe")
	done
	[ -w "$probe" ] || zl_die "нет прав на запись в $probe (нужно для $d)"
done
zl_info "каталоги доступны на запись"

# Оценка сверху: комплект плюс одно поколение плюс распакованный zapret.
need_kb=$(du -sk "$SRC" 2>/dev/null | cut -f1)
need_kb=$((need_kb * 2))
target="$ZL_PREFIX/opt"
[ -d "$target" ] || target="${ZL_PREFIX:-/}"
free_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ]; then
	zl_die "на $target свободно ${free_kb}K, нужно около ${need_kb}K"
fi
zl_info "места достаточно (нужно около $((need_kb / 1024)) МБ)"

if [ "$DRY_RUN" = 1 ]; then
	zl_info "проверки пройдены; дальше показано, что было бы сделано"
fi

# =====================================================================
# 3. Остановка службы перед изменениями
# =====================================================================
#
# Всё, что может отказать, проверено выше. Но отказать может и то, что
# мы не предвидели, а служба к этому моменту уже остановлена - то есть
# обход не работает. Молча оставлять человека в таком состоянии нельзя.
SERVICE_WAS_STOPPED=0

on_exit() {
	rc=$?
	[ "$rc" = 0 ] && return 0
	[ "$SERVICE_WAS_STOPPED" = 1 ] || return 0
	zl_warn ""
	zl_warn "Установка прервана, а служба zapret была остановлена перед началом."
	zl_warn "Сейчас обход не работает. Что делать:"
	zl_warn "  sudo systemctl start zapret     # если конфигурация цела"
	zl_warn "  zapret-lite doctor              # проверить, что именно сломано"
	zl_warn "  zapret-lite rollback            # вернуться к прежнему поколению"
	return 0
}
trap on_exit EXIT

if [ "$DRY_RUN" = 0 ] && zl_manage_systemd && systemctl is-active --quiet zapret 2>/dev/null; then
	zl_step "Остановка zapret"
	run systemctl stop zapret
	SERVICE_WAS_STOPPED=1
fi

# =====================================================================
# 4. Апстримный zapret
# =====================================================================
zl_step "Установка zapret в $ZL_ZAPRET_DIR"

run mkdir -p "$ZL_ZAPRET_DIR"
# Копируем всё, кроме config: он наш и пишется отдельно, в самом конце.
run sh -c "cd '$SRC/zapret' && tar -cf - --exclude=./config . | tar -xf - -C '$ZL_ZAPRET_DIR'"
# Права восстанавливаются по той же схеме, что в fix_perms() апстрима
# (install_easy.sh:439). Сначала всё в 644/755, потом бит исполнения
# возвращается тем файлам, которым он нужен: массовый chmod 0644 иначе
# ломает и бинарники, и все запускаемые скрипты.
run zl_chown -R root:root "$ZL_ZAPRET_DIR"
run find "$ZL_ZAPRET_DIR" -type d -exec chmod 0755 {} +
run find "$ZL_ZAPRET_DIR" -type f -exec chmod 0644 {} +
run find "$ZL_ZAPRET_DIR/binaries" \
	'(' -name nfqws -o -name tpws -o -name dvtws -o -name ip2net -o -name mdig ')' \
	-exec chmod 0755 {} +
for f in install_bin.sh blockcheck.sh install_prereq.sh uninstall_easy.sh \
         init.d/sysv/zapret init.d/openrc/zapret init.d/macos/zapret; do
	[ -f "$ZL_ZAPRET_DIR/$f" ] && run chmod 0755 "$ZL_ZAPRET_DIR/$f"
done
# ipset/*.sh нам не нужны для работы, но пусть остаются рабочими:
# blockcheck.sh и ручная диагностика на них опираются.
run find "$ZL_ZAPRET_DIR/ipset" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
zl_info "файлы скопированы, права восстановлены"

# install_bin.sh сам выбирает подходящий бинарник под архитектуру
# install_bin.sh перебирает каталоги binaries/*, проверяет, что бинарник
# запускается на этой системе, и симлинкует выбранный в nfq/nfqws
# (install_bin.sh:126). Свой код выбора архитектуры писать не нужно.
run sh "$ZL_ZAPRET_DIR/install_bin.sh"
if [ "$DRY_RUN" = 0 ] && [ ! -x "$ZL_ZAPRET_DIR/nfq/nfqws" ]; then
	zl_die "install_bin.sh не нашёл бинарник, подходящий для $ARCH.
      Соберите zapret из исходников и положите результат в
      $SRC/zapret/binaries/my/"
fi
zl_info "бинарники установлены"

# Метка, по которой деинсталлятор понимает, что каталог наш. Без неё он
# не станет сносить чужую установку zapret, которая могла быть здесь
# до нас.
run sh -c "printf 'installed_by=zapret-lite\n' > '$ZL_ZAPRET_DIR/.zapret-lite-owned'"

# =====================================================================
# 5. Сборка поколения
# =====================================================================
GEN_ID="$(zl_generation_id "$SRC")"
GEN_DIR="$ZL_VERSIONS/$GEN_ID"

zl_step "Сборка поколения $GEN_ID"

if [ -d "$GEN_DIR" ] && [ "$DRY_RUN" = 0 ]; then
	zl_info "поколение уже существует, пересобираю"
fi

# Поколение собирается в соседнем каталоге и переезжает на место целиком.
# Так прерванная на середине установка не оставит полуготовое поколение,
# на которое потом переключится current.
STAGE="$ZL_VERSIONS/.stage.$$"
run rm -rf "$STAGE"
run mkdir -p "$STAGE/fake" "$STAGE/lists" "$STAGE/strategies" "$STAGE/config"

run sh -c "cp -f '$SRC'/vendor/flowseal/fake/*.bin '$STAGE/fake/'"
run sh -c "cp -f '$SRC'/vendor/flowseal/lists/*.txt '$STAGE/lists/'"
run sh -c "cp -f '$SRC'/strategies/*.conf '$STAGE/strategies/'"
run zl_render "$SRC/config/base.conf.in" "$STAGE/config/base.conf"
run cp -f "$SRC/vendor/flowseal/flowseal.lock" "$STAGE/flowseal.lock"
[ -f "$SRC/zapret/zapret.lock" ] && run cp -f "$SRC/zapret/zapret.lock" "$STAGE/zapret.lock"

# Манифест поколения считается по факту, а не копируется из комплекта:
# в нём base.conf с подставленными путями, которого в комплекте нет.
if [ "$DRY_RUN" = 0 ]; then
	( cd "$STAGE" && find . -type f -printf '%P\n' | sort \
	    | xargs -r sha256sum >"$STAGE.manifest" )
	mv -f "$STAGE.manifest" "$STAGE/MANIFEST.sha256"
	zl_chown -R root:root "$STAGE"
	find "$STAGE" -type d -exec chmod 0755 {} +
	find "$STAGE" -type f -exec chmod 0644 {} +
	zl_verify_manifest "$STAGE" || zl_die "собранное поколение не сходится с манифестом"
	# Старое одноимённое поколение сначала отодвигается, и только потом
	# удаляется. Прямой rm -rf по живому каталогу оставил бы current
	# указывающим в никуда, пока распаковывается замена.
	if [ -d "$GEN_DIR" ]; then
		rm -rf "$GEN_DIR.old"
		mv -T "$GEN_DIR" "$GEN_DIR.old"
	fi
	mv -T "$STAGE" "$GEN_DIR"
	rm -rf "$GEN_DIR.old"
else
	printf '      would: посчитать манифест и переместить в %s\n' "$GEN_DIR"
fi
zl_info "поколение готово"

# =====================================================================
# 6. Состояние и пользовательские файлы
# =====================================================================
zl_step "Подготовка $ZL_ETC"

run mkdir -p "$ZL_ETC/lists"


# Пользовательские списки: создаём только если их нет. Существующие
# не трогаем никогда - это данные пользователя.
#
# Заглушка не косметическая. Если ВСЕ include-хостлисты профиля пусты,
# nfqws снимает фильтрацию по хостам целиком (hostlist.c:243) и профиль
# начинает применяться ко всем доменам подряд.
for f in list-general-user.txt list-exclude-user.txt; do
	if [ -e "$ZL_ETC/lists/$f" ]; then
		zl_info "$f: уже есть, не трогаю"
	else
		run sh -c "printf '# Свои домены, по одному в строке.\n# Не оставляйте файл пустым: пустой список снимает фильтрацию.\ndomain.example.abc\n' > '$ZL_ETC/lists/$f'"
		zl_info "$f: создан с заглушкой"
	fi
done

if [ -e "$ZL_ETC/lists/ipset-exclude-user.txt" ]; then
	zl_info "ipset-exclude-user.txt: уже есть, не трогаю"
else
	run sh -c "printf '# Свои подсети-исключения, по одной в строке.\n203.0.113.113/32\n' > '$ZL_ETC/lists/ipset-exclude-user.txt'"
	zl_info "ipset-exclude-user.txt: создан с заглушкой"
fi

# ipset-all.txt - переключаемое состояние, режим по умолчанию loaded.
if [ -e "$ZL_ETC/ipset" ]; then
	IPSET_MODE="$(cat "$ZL_ETC/ipset")"
	zl_info "режим ipset: $IPSET_MODE (сохранён с прошлой установки)"
else
	IPSET_MODE=loaded
	run sh -c "echo loaded > '$ZL_ETC/ipset'"
	zl_info "режим ipset: loaded"
fi

# Материализация ipset-all.txt делается ПОСЛЕ переключения поколения:
# источник берётся из current. См. секцию 7.

# Тип firewall и интерфейс уже проверены в секции 1; здесь только запись.
if [ -n "$FWTYPE_MODE" ]; then
	run sh -c "echo '$FWTYPE_MODE' > '$ZL_ETC/fwtype'"
	zl_info "тип firewall: $FWTYPE_MODE"
elif [ -e "$ZL_ETC/fwtype" ]; then
	zl_info "тип firewall: $(cat "$ZL_ETC/fwtype") (сохранено)"
else
	run sh -c "echo auto > '$ZL_ETC/fwtype'"
fi

if [ -n "$WAN_IFACE" ]; then
	run sh -c "echo '$WAN_IFACE' > '$ZL_ETC/wan-iface'"
	zl_info "интерфейс: $WAN_IFACE"
elif [ -e "$ZL_ETC/wan-iface" ]; then
	zl_info "интерфейс: $(cat "$ZL_ETC/wan-iface") (сохранено)"
else
	run sh -c "echo any > '$ZL_ETC/wan-iface'"
fi

# IPv6. Апстримный install_easy.sh задаёт этот вопрос вслух; у нас это
# флаг, а выбор сохраняется и переживает обновление.
if [ -n "$IPV6_MODE" ]; then
	run sh -c "echo '$IPV6_MODE' > '$ZL_ETC/ipv6'"
	zl_info "IPv6: $IPV6_MODE"
elif [ -e "$ZL_ETC/ipv6" ]; then
	zl_info "IPv6: $(cat "$ZL_ETC/ipv6") (сохранено)"
else
	run sh -c "echo off > '$ZL_ETC/ipv6'"
	if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
		zl_warn "IPv6: off, но у машины есть глобальный IPv6."
		zl_warn "Часть трафика пойдёт мимо обхода. Включить: zapret-lite ipv6 on"
	else
		zl_info "IPv6: off"
	fi
fi

if [ -e "$ZL_ETC/game-filter" ]; then
	zl_info "игровой фильтр: $(cat "$ZL_ETC/game-filter") (сохранён)"
else
	run sh -c "echo disabled > '$ZL_ETC/game-filter'"
	zl_info "игровой фильтр: disabled"
fi

if [ ! -e "$ZL_ETC/local.conf" ]; then
	run sh -c "printf '# Ваши правки. Подключается последним и перекрывает всё остальное.\n# Примеры:\n#FWTYPE=iptables\n#DISABLE_IPV6=0\n' > '$ZL_ETC/local.conf'"
	zl_info "local.conf: создан"
else
	zl_info "local.conf: уже есть, не трогаю"
fi

# Владелец и права выставляются принудительно. Каталог мог остаться от
# прежней установки, и если он окажется доступен на запись обычному
# пользователю, тот сможет положить в local.conf что угодно - а он
# читается через '.' с правами root.
run zl_chown -R root:root "$ZL_ETC"
run chmod 0755 "$ZL_ETC" "$ZL_ETC/lists"
run find "$ZL_ETC" -type d -exec chmod 0755 {} +
run find "$ZL_ETC" -type f -exec chmod 0644 {} +

# =====================================================================
# 7. Активная стратегия и конфиг
# =====================================================================
zl_step "Активация стратегии и запись конфига"

if [ "$DRY_RUN" = 0 ]; then
	zl_generation_switch "$GEN_ID" || exit 1
	zl_info "current -> $GEN_ID"
	prev=$(zl_generation_previous 2>/dev/null) || prev=
	[ -n "$prev" ] && zl_info "previous -> $prev"
	IPSET_MODE=$(zl_apply_ipset_mode) || exit 1
	zl_info "ipset-all.txt собран в режиме $IPSET_MODE"
	zl_generation_prune
else
	printf '      would: переключить current на %s и собрать ipset-all.txt\n' "$GEN_ID"
fi

run sh -c "echo '$STRATEGY' > '$ZL_ETC/strategy'"
zl_info "активна стратегия: $STRATEGY"

if [ "$DRY_RUN" = 1 ]; then
	printf '      would: записать %s (шим из трёх слоёв)\n' "$ZL_ZAPRET_DIR/config"
else
	# Каталог комплекта может быть смонтирован только на чтение,
	# поэтому промежуточный файл - во временном каталоге.
	shim_tmp=$(mktemp)
	zl_render "$SRC/config/zapret-config.shim.in" "$shim_tmp"
	zl_write_shim "$shim_tmp" || { rm -f "$shim_tmp"; exit 1; }
	rm -f "$shim_tmp"
	zl_info "$ZL_ZAPRET_DIR/config записан"
fi

# =====================================================================
# 8. Юнит systemd
# =====================================================================
zl_step "Установка службы"

if [ -f "$SRC/bin/zapret-lite" ]; then
	run mkdir -p "$ZL_BIN" "$ZL_BASE/lib"
	# Библиотека лежит вне поколений: она относится к самому zapret-lite,
	# а не к данным из релиза flowseal.
	run install -m 0644 "$SRC/lib/common.sh" "$ZL_BASE/lib/common.sh"
	run install -m 0755 "$SRC/bin/zapret-lite" "$ZL_BIN/zapret-lite"
	run sh -c "sed -i 's|^ZL_LIB=.*|ZL_LIB=\"\${ZL_LIB:-$ZL_BASE/lib}\"|' '$ZL_BIN/zapret-lite'"
	zl_info "менеджер установлен: $ZL_BIN/zapret-lite"
fi

run mkdir -p "$ZL_SYSTEMD_DIR"
run cp -f "$ZL_ZAPRET_DIR/init.d/systemd/zapret.service" "$ZL_SYSTEMD_DIR/zapret.service"
run mkdir -p "$ZL_SYSTEMD_DIR/zapret.service.d"
run cp -f "$SRC/systemd/10-zapret-lite.conf" "$ZL_SYSTEMD_DIR/zapret.service.d/10-zapret-lite.conf"

# Таймер проверки обновлений. Только уведомляет: ничего не скачивает,
# ничего не применяет, к firewall не прикасается.
run cp -f "$SRC/systemd/zapret-lite-check-update.service" "$ZL_SYSTEMD_DIR/"
run cp -f "$SRC/systemd/zapret-lite-check-update.timer" "$ZL_SYSTEMD_DIR/"

if [ "$DRY_RUN" = 0 ] && ! zl_manage_systemd; then
	zl_info "служба не регистрируется: установка в префикс"
elif [ "$DRY_RUN" = 0 ]; then
	systemctl daemon-reload
	systemctl enable zapret >/dev/null 2>&1 || zl_die "не удалось включить службу zapret"
	# Источник по умолчанию - релизы flowseal, поэтому ждать
	# $ZL_ETC/update.url незачем: он лишь переопределяет источник.
	if systemctl enable --now zapret-lite-check-update.timer >/dev/null 2>&1; then
		if [ -s "$ZL_ETC/update.url" ]; then
			zl_info "проверка обновлений: раз в сутки, источник из update.url"
		else
			zl_info "проверка обновлений: раз в сутки (релизы flowseal)"
		fi
	else
		zl_warn "не удалось включить таймер проверки обновлений"
	fi
	zl_info "служба включена"
	# Служба могла остаться в состоянии failed от прежних попыток -
	# например, после неудачного конфига или упёршегося ограничителя.
	# Без сброса счётчика установка споткнулась бы на ровном месте.
	systemctl reset-failed zapret >/dev/null 2>&1 || true
	if systemctl start zapret; then
		zl_info "служба запущена"
	else
		zl_error "служба не запустилась. Диагностика: journalctl -u zapret -n 50"
		exit 1
	fi
else
	printf '      would: systemctl daemon-reload && enable && start zapret\n'
fi

zl_step "Готово"
cat <<EOF
  Поколение      : $GEN_ID
  Стратегия      : $STRATEGY
  Firewall       : $FWTYPE (автоопределение)
  Режим ipset    : $IPSET_MODE
  Ваши настройки : $ZL_ETC/local.conf
  Ваши списки    : $ZL_ETC/lists/

  Проверить      : zapret-lite status
  Сменить        : zapret-lite use <имя>
  Откатиться     : zapret-lite rollback
  Удалить        : $SRC/uninstall.sh
EOF
