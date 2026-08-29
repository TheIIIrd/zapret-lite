#!/usr/bin/env bats
# Модульные тесты lib/common.sh.
#
# Отдельно от сквозных: в cmd_use недопустимое имя отсеивается ещё и
# проверкой существования файла, и сломанный валидатор через неё
# незаметен. Здесь функция вызывается напрямую.

setup() {
	REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	export ZL_PREFIX="$BATS_TEST_TMPDIR/root"
	# shellcheck source=../lib/common.sh
	. "$REPO/lib/common.sh"
}

@test "zl_valid_name принимает обычные имена" {
	for n in general general-alt11 general.alt a_b 2026-08-28_flowseal-1.10.2_zapret-72.13; do
		zl_valid_name "$n" || { echo "отвергнуто корректное имя: $n"; return 1; }
	done
}

@test "zl_valid_name отвергает всё, что может стать путём или командой" {
	for n in '' '.' '..' '../evil' 'foo/bar' 'foo\bar' 'a b' 'a;id' 'a|b' 'a&b' \
	         '$(id)' '`id`' 'a>b' 'a*b' 'кириллица' '.hidden'; do
		if zl_valid_name "$n"; then
			echo "принято недопустимое имя: '$n'"
			return 1
		fi
	done
}

@test "zl_lock_get читает ключ и отличает пустое значение от отсутствующего" {
	local f="$BATS_TEST_TMPDIR/l"
	printf 'a=1\nb=\nc=hello world\n' >"$f"
	[ "$(zl_lock_get "$f" a)" = "1" ]
	[ "$(zl_lock_get "$f" c)" = "hello world" ]
	# Пустое значение - это "не нашли": иначе вызывающий не отличит его
	# от отсутствующего ключа и уйдёт с пустой строкой.
	run zl_lock_get "$f" b
	[ "$status" -ne 0 ]
	run zl_lock_get "$f" нет
	[ "$status" -ne 0 ]
	run zl_lock_get "$BATS_TEST_TMPDIR/нет-файла" a
	[ "$status" -ne 0 ]
}

@test "zl_verify_manifest ловит изменение, пропажу и лишний файл" {
	local d="$BATS_TEST_TMPDIR/d"
	mkdir -p "$d"
	printf 'one\n' >"$d/a"
	printf 'two\n' >"$d/b"
	( cd "$d" && sha256sum a b >MANIFEST.sha256 )

	run zl_verify_manifest "$d"
	[ "$status" -eq 0 ]

	printf 'changed\n' >"$d/a"
	run zl_verify_manifest "$d"
	[ "$status" -ne 0 ]

	printf 'one\n' >"$d/a"
	rm -f "$d/b"
	run zl_verify_manifest "$d"
	[ "$status" -ne 0 ]

	printf 'two\n' >"$d/b"
	printf 'extra\n' >"$d/c"
	# Обычный режим лишние файлы не замечает - это осознанно.
	run zl_verify_manifest "$d"
	[ "$status" -eq 0 ]
	# Строгий обязан заметить.
	run zl_verify_manifest "$d" strict
	[ "$status" -ne 0 ]
	[[ "$output" == *"лишний файл"* ]]
}

@test "zl_verify_manifest различает отсутствие манифеста и несовпадение" {
	local d="$BATS_TEST_TMPDIR/e"
	mkdir -p "$d"
	run zl_verify_manifest "$d"
	# Код 2 - манифеста нет; код 1 - есть, но не сходится.
	[ "$status" -eq 2 ]
}

@test "zl_generation_id собирает имя из обоих lock-файлов" {
	local p="$BATS_TEST_TMPDIR/pkg"
	mkdir -p "$p/vendor/flowseal" "$p/zapret"
	printf 'flowseal_version=1.2.3\n' >"$p/vendor/flowseal/flowseal.lock"
	printf 'zapret_version=99.9\n' >"$p/zapret/zapret.lock"
	[[ "$(zl_generation_id "$p")" == *"_flowseal-1.2.3_zapret-99.9" ]]
}

@test "zl_generation_id берёт версию zapret из vendor, если рядом её нет" {
	local p="$BATS_TEST_TMPDIR/pkg2"
	mkdir -p "$p/vendor/flowseal" "$p/vendor/zapret"
	printf 'flowseal_version=1.2.3\n' >"$p/vendor/flowseal/flowseal.lock"
	printf 'zapret_version=88.8\n' >"$p/vendor/zapret/zapret.lock"
	[[ "$(zl_generation_id "$p")" == *"_zapret-88.8" ]]
	[[ "$(zl_generation_id "$p")" != *"unknown"* ]]
}

@test "zl_group_or_world_writable различает режимы доступа" {
	# В doctor эта проверка работает только при настоящей установке от
	# root, то есть сквозным тестом недостижима. Раньше вместо неё стоял
	# тест, который проверял совсем другое и потому ничего не значил.
	local f="$BATS_TEST_TMPDIR/f"
	: >"$f"

	for m in 600 640 644 700 750 755 400; do
		chmod "$m" "$f"
		if zl_group_or_world_writable "$f"; then
			echo "режим $m ошибочно признан открытым на запись"
			return 1
		fi
	done

	for m in 660 666 664 646 777 622 607 070; do
		chmod "$m" "$f"
		if ! zl_group_or_world_writable "$f"; then
			echo "режим $m не распознан как открытый на запись"
			return 1
		fi
	done

	# Несуществующий путь - не повод сообщать о проблеме.
	run zl_group_or_world_writable "$BATS_TEST_TMPDIR/нет-такого"
	[ "$status" -ne 0 ]
}

@test "zl_require_root пропускает установку в префикс" {
	# Иначе тесты пришлось бы гонять от root, а в CI их запускает
	# обычный пользователь.
	ZL_PREFIX=/tmp/somewhere run zl_require_root
	[ "$status" -eq 0 ]
}

@test "zl_switch_state пишет значение и не требует systemd в префиксе" {
	local f="$BATS_TEST_TMPDIR/state"
	mkdir -p "$(dirname "$f")"
	run zl_switch_state "$f" "значение"
	[ "$status" -eq 0 ]
	[ "$(cat "$f")" = "значение" ]
	[ "$(stat -c '%a' "$f")" = "644" ]
}

@test "zl_virt_breaks_bypass знает проблемные гипервизоры" {
	# VMware и VirtualBox с внутренним NAT ломают большинство техник
	# обхода (апстрим предупреждает об этом в common/virt.sh:24).
	for v in vmware oracle virtualbox vmw; do
		zl_virt_breaks_bypass "$v" || { echo "не распознан: $v"; return 1; }
	done
	for v in kvm qemu xen none ""; do
		if zl_virt_breaks_bypass "$v"; then
			echo "ложное срабатывание: $v"
			return 1
		fi
	done
}
