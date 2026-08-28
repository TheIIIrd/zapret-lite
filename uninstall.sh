#!/bin/sh
# Удаление zapret-lite.
#
#   ./uninstall.sh [--purge] [--dry-run]
#
# По умолчанию удаляется всё, что поставил install.sh, но сохраняются
# ваши файлы в /etc/zapret-lite. --purge сносит и их.
#
# Проверка симметрии, которую стоит делать на боевой машине:
#   iptables-save > /tmp/before   (до установки)
#   ...установка, работа, удаление...
#   iptables-save > /tmp/after
#   diff /tmp/before /tmp/after   -> должно быть пусто

set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

PURGE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--purge)   PURGE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help)
			printf 'Использование: %s [--purge] [--dry-run]\n' "$0"
			printf '  --purge    удалить также %s\n' "$ZL_ETC"
			exit 0
			;;
		*) zl_die "неизвестная опция: $1" ;;
	esac
done

run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '      would: %s\n' "$*"
	else
		"$@"
	fi
}

[ "$DRY_RUN" = 1 ] || zl_require_root

# =====================================================================
# 1. Остановка службы. Это же снимает правила firewall.
# =====================================================================
zl_step "Остановка службы"

if zl_manage_systemd && systemctl list-unit-files zapret.service >/dev/null 2>&1; then
	# ExecStop у zapret.service вызывает init.d/sysv/zapret stop, который
	# снимает свои правила. Останавливаем ДО удаления файлов, иначе
	# снимать правила будет нечем и они останутся в системе.
	if systemctl is-active --quiet zapret 2>/dev/null; then
		run systemctl stop zapret || zl_warn "остановка вернула ошибку, продолжаю"
		zl_info "служба остановлена, правила сняты"
	else
		zl_info "служба не была запущена"
	fi
	run systemctl disable zapret >/dev/null 2>&1 || true
else
	zl_info "служба не зарегистрирована"
fi

# =====================================================================
# 1b. Осиротевшая таблица nftables
# =====================================================================
#
# zapret_unapply_firewall_nft() снимает только цепочки: nft_del_table()
# в common/nft.sh определена, но не вызывается ниоткуда. После остановки
# остаётся пустая "table inet zapret" с сетами. Сама по себе она
# безвредна, но мы сейчас удалим /opt/zapret, и снять её будет уже нечем.
zl_step "Очистка таблицы nftables"

if zl_have nft && nft list table inet zapret >/dev/null 2>&1; then
	if nft -t list table inet zapret 2>/dev/null | grep -q '^[[:space:]]*chain '; then
		zl_warn "в таблице inet zapret остались цепочки - не трогаю её"
		zl_warn "Похоже, служба не остановилась штатно. Проверьте: nft list table inet zapret"
	else
		run nft delete table inet zapret
		zl_info "пустая таблица inet zapret удалена"
	fi
else
	zl_info "таблицы inet zapret нет"
fi

# =====================================================================
# 2. Юниты
# =====================================================================
zl_step "Удаление юнитов"

# Таймер выключается до удаления файла юнита: иначе systemd оставит
# висеть symlink в multi-user.target.wants и будет ругаться при каждом
# daemon-reload.
if zl_manage_systemd; then
	run systemctl disable --now zapret-lite-check-update.timer >/dev/null 2>&1 || true
fi
run rm -f "$ZL_SYSTEMD_DIR/zapret-lite-check-update.service" \
          "$ZL_SYSTEMD_DIR/zapret-lite-check-update.timer"
run rm -f "$ZL_SYSTEMD_DIR/zapret.service"
run rm -f "$ZL_SYSTEMD_DIR/zapret.service.d/10-zapret-lite.conf"
run rmdir "$ZL_SYSTEMD_DIR/zapret.service.d" 2>/dev/null || true
# На случай, если раньше ставился install_easy.sh апстрима.
run rm -f "$ZL_SYSTEMD_DIR/zapret-list-update.service" \
          "$ZL_SYSTEMD_DIR/zapret-list-update.timer"
[ "$DRY_RUN" = 1 ] || ! zl_manage_systemd || systemctl daemon-reload
zl_info "юниты удалены"

# =====================================================================
# 3. Файлы
# =====================================================================
zl_step "Удаление файлов"

run rm -f "$ZL_BIN/zapret-lite"
run rm -rf "$ZL_BASE"
run rm -rf "$ZL_PREFIX/var/lib/zapret-lite"
zl_info "$ZL_BASE удалён"

# /opt/zapret сносим только если ставили его мы. Пользователь мог
# поставить zapret самостоятельно до нас, и снести чужую установку -
# худшее, что может сделать деинсталлятор.
if [ -f "$ZL_OWNED_MARKER" ]; then
	run rm -rf "$ZL_ZAPRET_DIR"
	zl_info "$ZL_ZAPRET_DIR удалён"
elif [ -d "$ZL_ZAPRET_DIR" ]; then
	zl_warn "$ZL_ZAPRET_DIR оставлен: нет метки, что его ставили мы."
	zl_warn "Если он вам не нужен, удалите вручную."
else
	zl_info "$ZL_ZAPRET_DIR отсутствует"
fi

if [ "$PURGE" = 1 ]; then
	run rm -rf "$ZL_ETC"
	zl_info "$ZL_ETC удалён"
else
	zl_info "$ZL_ETC сохранён (--purge чтобы удалить)"
fi

zl_step "Готово"
printf '  Проверьте, что правила снялись:\n'
printf '    nft list ruleset | grep -i zapret\n'
printf '    iptables-save | grep -i zapret\n'
printf '  Вывод должен быть пустым.\n'
