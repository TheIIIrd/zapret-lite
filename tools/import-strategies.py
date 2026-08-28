#!/usr/bin/env python3
"""
Конвертер стратегий flowseal (.bat для winws) в фрагменты конфигов
апстримного zapret (формат NFQWS_OPT / NFQWS_PORTS_*).

Запускается в CI, в рантайме не участвует.

Использование:
    import-strategies.py <каталог_релиза_flowseal> <каталог_вывода>
                         [--options-file nfqws-options.txt]

Коды возврата: 0 - все стратегии сконвертированы, 1 - есть ошибки.
"""

import argparse
import hashlib
import os
import re
import sys
import unicodedata

# ---------------------------------------------------------------- константы

# Куда конфиг будет ссылаться на нашем целевом хосте. Пути подставляются
# как shell-переменные: их определяет общий config, а не фрагмент стратегии.
FAKE_DIR_VAR = "$ZAPRET_FAKE_DIR"
# Списки живут в двух каталогах. Вендорные заменяются целиком при каждой
# синхронизации, локальные принадлежат пользователю и не трогаются никогда.
LISTS_DIR_VAR = "$ZAPRET_LISTS_DIR"
LOCAL_LISTS_DIR_VAR = "$ZAPRET_LOCAL_LISTS_DIR"

# Порт-заглушка, которым flowseal обозначает выключенный игровой фильтр.
GAME_FILTER_OFF = "12"

# Опции, задающие путь к файлу. Для них проверяем существование артефакта.
FILE_OPTS_FAKE = {
    "dpi-desync-fake-http",
    "dpi-desync-fake-tls",
    "dpi-desync-fake-unknown",
    "dpi-desync-fake-syndata",
    "dpi-desync-fake-quic",
    "dpi-desync-fake-wireguard",
    "dpi-desync-fake-dht",
    "dpi-desync-fake-discord",
    "dpi-desync-fake-stun",
    "dpi-desync-fake-unknown-udp",
    "dpi-desync-split-seqovl-pattern",
}
FILE_OPTS_LISTS = {
    "hostlist",
    "hostlist-exclude",
    "hostlist-auto",
    "ipset",
    "ipset-exclude",
}

# Значения file-опций, которые файлами не являются.
NOT_A_FILE = re.compile(r"^(0x[0-9a-fA-F]+|!|\^!|)$")

# Пользовательские списки. В релизе flowseal их нет: service.bat создаёт их
# при первом запуске. Мы обязаны создать их при установке, иначе nfqws
# не найдёт файл.
USER_LISTS = {
    "list-general-user.txt",
    "list-exclude-user.txt",
    "ipset-exclude-user.txt",
}

# Файлы, которые установщик материализует в локальном каталоге.
# ipset-all.txt переключаемый (loaded/none/any), поэтому он изменяемое
# состояние, а не вендорные данные.
LOCAL_LISTS = USER_LISTS | {"ipset-all.txt"}

# Опции, при которых nfqws ПИШЕТ в указанный файл. Каталог поколения
# неизменяем, и запись туда сломала бы его манифест: doctor начал бы
# сообщать о повреждении на исправной системе. Сейчас таких опций в
# стратегиях нет, но появиться они могут.
WRITING_OPTS = {
    "hostlist-auto",
    "hostlist-auto-debuglog",
    "debug",
}

# Опции, задающие include-хостлист профиля. Если все они окажутся пустыми,
# nfqws снимает фильтрацию по хостам целиком (hostlist.c, HostlistCheck:
# "all include lists are empty means check passes"), и профиль начинает
# применяться ко всем доменам подряд.
INCLUDE_LIST_OPTS = {"hostlist", "hostlist-domains"}


class Problem(Exception):
    pass


# ---------------------------------------------------------------- утилиты

def slugify(name: str) -> str:
    """'general (FAKE TLS AUTO ALT2)' -> 'general-fake-tls-auto-alt2'"""
    s = unicodedata.normalize("NFKD", name).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def unescape_cmd(s: str) -> str:
    """Снимает экранирование cmd.exe: ^! ^" ^> ^| ^^ -> ! " > | ^

    Это не косметика. В 'general (FAKE TLS AUTO)' записано
    --dpi-desync-fake-tls=^! , и значение здесь '!' (стандартный фейк),
    а не '^!'. Без этого шага конвертер тихо сгенерирует мусор.
    """
    return re.sub(r"\^(.)", r"\1", s)


def split_args(line: str):
    """Разбивает командную строку на аргументы, уважая кавычки."""
    out, cur, in_q = [], [], False
    for ch in line:
        if ch == '"':
            in_q = not in_q
        elif ch.isspace() and not in_q:
            if cur:
                out.append("".join(cur))
                cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur))
    return out


# ---------------------------------------------------------------- разбор .bat

WINWS_RE = re.compile(r'winws\.exe"?\s*(.*)$', re.IGNORECASE)


def extract_command(path: str) -> str:
    """Достаёт из .bat командную строку winws, склеивая переносы по '^'."""
    with open(path, encoding="utf-8-sig", errors="strict") as f:
        raw = f.read().replace("\r\n", "\n").replace("\r", "\n")

    lines = raw.split("\n")
    start = None
    for i, line in enumerate(lines):
        if "winws.exe" in line.lower() and line.lstrip().lower().startswith("start"):
            start = i
            break
    if start is None:
        raise Problem("не найдена строка запуска winws.exe")

    parts = []
    i = start
    while True:
        line = lines[i].rstrip()
        if line.endswith("^"):
            parts.append(line[:-1].strip())
            i += 1
            if i >= len(lines):
                raise Problem("файл обрывается на продолжении строки")
        else:
            parts.append(line.strip())
            break

    cmd = " ".join(p for p in parts if p)
    m = WINWS_RE.search(cmd)
    if not m:
        raise Problem("не удалось выделить аргументы winws.exe")
    return unescape_cmd(m.group(1))


def artifact_basename(value: str) -> str:
    """Имя файла из значения опции.

    В .bat переменные раскрываются как '%LISTS%list-general.txt' - разделителя
    после '%LISTS%' нет, поэтому обычный basename вернёт всю строку целиком.
    """
    value = re.sub(r"^--[a-z0-9-]+=", "", value)
    value = re.sub(r"^%(BIN|LISTS)%", "", value)
    return re.split(r"[\\/]", value)[-1]


def rewrite_paths(value: str) -> str:
    value = value.replace("%BIN%", FAKE_DIR_VAR + "/")
    if "%LISTS%" in value:
        base = artifact_basename(value)
        target = LOCAL_LISTS_DIR_VAR if base in LOCAL_LISTS else LISTS_DIR_VAR
        value = value.replace("%LISTS%", target + "/")
    return value


def rewrite_vars(value: str) -> str:
    value = value.replace("%GameFilterTCP%", "$GAME_FILTER_TCP")
    value = value.replace("%GameFilterUDP%", "$GAME_FILTER_UDP")
    return value


def parse_ports(spec: str):
    """'80,443,1024-65535,$GAME_FILTER_TCP' -> множество портов + флаг переменных.

    Возвращает (set_портов, есть_ли_подстановки). Порты из подстановок
    учесть статически нельзя, поэтому такие фильтры проверке не подлежат.
    """
    ports, dynamic = set(), False
    for token in spec.split(","):
        token = token.strip()
        if not token:
            continue
        if token.startswith("$"):
            dynamic = True
            continue
        if "-" in token:
            a, b = token.split("-", 1)
            try:
                ports.update(range(int(a), int(b) + 1))
            except ValueError:
                raise Problem(f"не разобран диапазон портов '{token}'")
        else:
            try:
                ports.add(int(token))
            except ValueError:
                raise Problem(f"не разобран порт '{token}'")
    return ports, dynamic


# ---------------------------------------------------------------- конвертация

def convert(bat_path, release_dir, valid_options):
    """Возвращает (текст_конфига, список_предупреждений). Бросает Problem."""
    warnings = []
    args = split_args(extract_command(bat_path))

    wf = {}
    profile_args = []
    for arg in args:
        m = re.match(r"^--wf-(tcp|udp|l3|raw|save)=(.*)$", arg)
        if m:
            wf[m.group(1)] = m.group(2)
        else:
            profile_args.append(arg)

    if "tcp" not in wf and "udp" not in wf:
        raise Problem("в стратегии нет ни --wf-tcp, ни --wf-udp")
    for key in ("l3", "raw", "save"):
        if key in wf:
            warnings.append(f"--wf-{key} отброшен: на Linux фильтрацию задаёт firewall")

    bin_dir = os.path.join(release_dir, "bin")
    lists_dir = os.path.join(release_dir, "lists")

    # --- разбор профилей и проверка каждого аргумента
    profiles, current = [], []
    include_lists, includes = [], []
    local_lists_seen = set()
    for arg in profile_args:
        if arg == "--new":
            profiles.append(current)
            include_lists.append(includes)
            current, includes = [], []
            continue
        if not arg.startswith("--"):
            raise Problem(f"аргумент без '--': {arg!r}")

        name, _, value = arg[2:].partition("=")
        if name not in valid_options:
            raise Problem(f"неизвестная опция nfqws: --{name}")

        if name in WRITING_OPTS:
            raise Problem(
                f"--{name} заставляет nfqws писать в файл. Каталог поколения "
                f"неизменяем: определите, куда должна идти запись, и вынесите "
                f"путь в локальный каталог, прежде чем принимать эту стратегию"
            )

        if (name in FILE_OPTS_FAKE or name in FILE_OPTS_LISTS) and not NOT_A_FILE.match(
            value
        ):
            base = artifact_basename(value)
            root = bin_dir if name in FILE_OPTS_FAKE else lists_dir
            if base in LOCAL_LISTS:
                local_lists_seen.add(base)
            elif not os.path.isfile(os.path.join(root, base)):
                raise Problem(f"--{name} ссылается на отсутствующий файл: {base}")

        if name in INCLUDE_LIST_OPTS:
            includes.append(artifact_basename(value))

        current.append(rewrite_vars(rewrite_paths(arg)))
    profiles.append(current)
    include_lists.append(includes)

    if not any(profiles):
        raise Problem("не найдено ни одного профиля")

    for idx, inc in enumerate(include_lists, 1):
        if inc and all(name in USER_LISTS for name in inc):
            warnings.append(
                f"профиль {idx}: все include-хостлисты пользовательские; "
                f"если пользователь их опустошит, профиль применится ко всем доменам"
            )

    # --- порты профилей должны быть подмножеством портов firewall
    for proto in ("tcp", "udp"):
        if proto not in wf:
            continue
        allowed, wf_dynamic = parse_ports(rewrite_vars(wf[proto]))
        for idx, prof in enumerate(profiles, 1):
            for arg in prof:
                m = re.match(rf"^--filter-{proto}=(.*)$", arg)
                if not m:
                    continue
                used, used_dynamic = parse_ports(m.group(1))
                if used_dynamic and not wf_dynamic:
                    raise Problem(
                        f"профиль {idx}: --filter-{proto} использует подстановку, "
                        f"которой нет в --wf-{proto}"
                    )
                missing = used - allowed
                if missing and not wf_dynamic:
                    raise Problem(
                        f"профиль {idx}: порты {sorted(missing)} есть в "
                        f"--filter-{proto}, но не заворачиваются "
                        f"(--wf-{proto}={wf[proto]})"
                    )

    # --- сборка фрагмента в формате апстримного zapret
    name = slugify(os.path.basename(bat_path)[:-4])
    lines = [
        f"# {name}",
        "# Сгенерировано import-strategies.py. Не редактировать вручную:",
        "# правки будут потеряны при следующей синхронизации с flowseal.",
        f"# Источник: {os.path.basename(bat_path)}",
        "",
        "NFQWS_ENABLE=1",
    ]
    for proto in ("tcp", "udp"):
        if proto in wf:
            lines.append(
                f"NFQWS_PORTS_{proto.upper()}=\"{rewrite_vars(wf[proto])}\""
            )
    lines.append("")
    lines.append('NFQWS_OPT="')
    body = [" ".join(p) for p in profiles if p]
    for i, prof in enumerate(body):
        lines.append(prof + (" --new" if i < len(body) - 1 else ""))
    lines.append('"')
    lines.append("")

    return "\n".join(lines), warnings, len(body), sorted(local_lists_seen)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("release_dir")
    ap.add_argument("out_dir")
    ap.add_argument(
        "--options-file",
        default=os.path.join(os.path.dirname(__file__), "nfqws-options.txt"),
    )
    args = ap.parse_args()

    with open(args.options_file) as f:
        valid_options = {l.strip() for l in f if l.strip()}

    bats = sorted(
        p
        for p in os.listdir(args.release_dir)
        if p.endswith(".bat") and p != "service.bat"
    )
    if not bats:
        print("в каталоге релиза нет .bat", file=sys.stderr)
        return 1

    os.makedirs(args.out_dir, exist_ok=True)
    ok, failed = 0, []

    for bat in bats:
        path = os.path.join(args.release_dir, bat)
        try:
            text, warnings, nprof, _ulists = convert(path, args.release_dir, valid_options)
        except Problem as e:
            failed.append((bat, str(e)))
            print(f"[ - ] {bat}: {e}")
            continue
        except Exception as e:  # noqa: BLE001
            failed.append((bat, f"{type(e).__name__}: {e}"))
            print(f"[ - ] {bat}: {type(e).__name__}: {e}")
            continue

        out = os.path.join(args.out_dir, slugify(bat[:-4]) + ".conf")
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        ok += 1
        note = f" ({nprof} проф.)"
        print(f"[ + ] {bat} -> {os.path.basename(out)}{note}")
        for w in warnings:
            print(f"      предупреждение: {w}")

    print(f"\nИтог: {ok} из {len(bats)} стратегий сконвертировано.")
    if failed:
        print("Не удалось:")
        for bat, err in failed:
            print(f"  {bat}: {err}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
