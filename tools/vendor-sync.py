#!/usr/bin/env python3
"""
Снимок релиза flowseal в vendor/.

Каталоги заменяются целиком, а не сливаются: имена .bin между релизами
меняются (quic_initial_4pda.to.bin -> quic_initial_4pda_to.bin), и доливка
поверх старого оставила бы мёртвые файлы, на которые однажды сошлётся конфиг.

Файлы копируются побайтово, включая CRLF. nfqws обрезает '\\r' сам
(ipset.c:16, hostlist.c), а нормализация переносов сломала бы сверку
sha256 с исходным релизом.

Использование:
    vendor-sync.py <каталог_релиза_flowseal> <каталог_vendor>
                   --version 1.10.2
                   [--zapret-version 72.13]

Коды возврата: 0 - успех, 1 - ошибка.
"""

import argparse
import datetime
import hashlib
import os
import re
import shutil
import sys

LOCK_NAME = "flowseal.lock"
MANIFEST_NAME = "MANIFEST.sha256"

# Списки, которые ставит и правит пользователь. В релизе flowseal их нет
# (service.bat создаёт их при первом запуске), в vendor они не попадают.
USER_LISTS = {
    "list-general-user.txt",
    "list-exclude-user.txt",
    "ipset-exclude-user.txt",
}

# ipset-all.txt в релизе - заглушка 203.0.113.113/32, а реальные данные
# лежат в ipset-all.txt.backup. Кладём полный список под однозначным именем;
# рабочую копию нужного режима материализует установщик.
IPSET_SOURCE = "ipset-all.txt.backup"
IPSET_TARGET = "ipset-all.full.txt"
IPSET_PLACEHOLDER = "203.0.113.113/32"


def copy_list(src, dst):
    """Копирует текстовый список, приводя переносы строк к LF.

    Только для списков: .bin - двоичные пейлоады, их трогать нельзя.
    """
    with open(src, "rb") as f:
        data = f.read()
    data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    with open(dst, "wb") as f:
        f.write(data)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def engine_version(winws_path):
    """Версия nfqws, с которой собран winws.exe релиза.

    Нужна, чтобы поймать ситуацию, когда flowseal ушёл вперёд по движку
    и начал использовать опции, которых нет в нашей сборке nfqws.
    """
    if not os.path.isfile(winws_path):
        return None
    with open(winws_path, "rb") as f:
        blob = f.read()
    found = set()
    for m in re.finditer(rb"v(\d+)\.(\d+)", blob):
        major, minor = int(m.group(1)), int(m.group(2))
        # версии zapret живут в диапазоне 60..99, отсекаем совпадения
        # с адресами и прочим мусором
        if 60 <= major <= 99:
            found.add((major, minor))
    if not found:
        return None
    major, minor = max(found)
    return f"{major}.{minor}"


def version_tuple(v):
    return tuple(int(x) for x in v.split("."))


def replace_dir(dst):
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("release_dir")
    ap.add_argument("vendor_dir")
    ap.add_argument("--version", required=True, help="тег релиза flowseal, например 1.10.2")
    ap.add_argument(
        "--zapret-version",
        help="версия nfqws нашей сборки, например 72.13. "
        "Если указана и меньше версии движка релиза - ошибка.",
    )
    args = ap.parse_args()

    rel = args.release_dir
    out = os.path.join(args.vendor_dir, "flowseal")
    src_bin = os.path.join(rel, "bin")
    src_lists = os.path.join(rel, "lists")

    for d in (src_bin, src_lists):
        if not os.path.isdir(d):
            print(f"[ - ] в релизе нет каталога {os.path.basename(d)}", file=sys.stderr)
            return 1

    # --- версия движка
    eng = engine_version(os.path.join(src_bin, "winws.exe"))
    if eng is None:
        # Молча продолжать нельзя: сверка версий - единственное, что
        # ловит уход flowseal на движок новее нашего. Пропустить её
        # значит потерять защиту, не заметив этого.
        print("[ ! ] не удалось определить версию nfqws из winws.exe", file=sys.stderr)
        if args.zapret_version:
            print(
                "[ - ] сверка версий движка невозможна, а она и есть смысл "
                "--zapret-version. Проверьте, что в релизе есть bin/winws.exe.",
                file=sys.stderr,
            )
            return 1
    else:
        print(f"[ + ] движок релиза: nfqws v{eng}")
        if args.zapret_version:
            if version_tuple(args.zapret_version) < version_tuple(eng):
                print(
                    f"[ - ] наш zapret v{args.zapret_version} старше движка релиза "
                    f"v{eng}. Поднимите pin zapret до >= {eng}, иначе стратегии "
                    f"могут использовать неизвестные нашей сборке опции.",
                    file=sys.stderr,
                )
                return 1
            print(f"[ + ] наш zapret v{args.zapret_version} не старше движка релиза")

    # --- fake
    dst_fake = os.path.join(out, "fake")
    replace_dir(dst_fake)
    fakes = sorted(f for f in os.listdir(src_bin) if f.endswith(".bin"))
    for f in fakes:
        shutil.copy2(os.path.join(src_bin, f), os.path.join(dst_fake, f))
    print(f"[ + ] fake: {len(fakes)} файлов")

    # --- lists
    dst_lists = os.path.join(out, "lists")
    replace_dir(dst_lists)
    copied = []
    for f in sorted(os.listdir(src_lists)):
        if f in USER_LISTS:
            continue
        if f == IPSET_SOURCE:
            continue
        if f == "ipset-all.txt":
            # заглушка, реальные данные приезжают из .backup ниже
            continue
        if not f.endswith(".txt"):
            continue
        copy_list(os.path.join(src_lists, f), os.path.join(dst_lists, f))
        copied.append(f)

    ipset_src = os.path.join(src_lists, IPSET_SOURCE)
    if os.path.isfile(ipset_src):
        copy_list(ipset_src, os.path.join(dst_lists, IPSET_TARGET))
        copied.append(IPSET_TARGET)
    else:
        # в редком случае релиз может приехать уже в режиме loaded
        plain = os.path.join(src_lists, "ipset-all.txt")
        with open(plain, "rb") as f:
            head = f.read(64)
        if IPSET_PLACEHOLDER.encode() in head:
            print(
                f"[ - ] нет {IPSET_SOURCE}, а ipset-all.txt содержит только "
                f"заглушку: полного списка в релизе нет",
                file=sys.stderr,
            )
            return 1
        copy_list(plain, os.path.join(dst_lists, IPSET_TARGET))
        copied.append(IPSET_TARGET)
    print(f"[ + ] lists: {len(copied)} файлов")



    # --- lock пишется ДО манифеста, чтобы попасть в него
    #
    # Установщик доверяет этому файлу: из него берётся имя поколения и
    # версия, с которой сравнивает check-update. Значит он должен быть
    # защищён контрольной суммой наравне со списками.
    with open(os.path.join(out, LOCK_NAME), "w") as f:
        f.write(f"flowseal_version={args.version}\n")
        f.write(f"engine_nfqws_version={eng or 'unknown'}\n")
        f.write(
            "source_url=https://github.com/Flowseal/zapret-discord-youtube"
            f"/releases/tag/{args.version}\n"
        )
        f.write(f"synced_utc={datetime.datetime.now(datetime.timezone.utc):%Y-%m-%dT%H:%M:%SZ}\n")

    # --- манифест
    entries = []
    for root, _, files in os.walk(out):
        for f in sorted(files):
            if f == MANIFEST_NAME:
                continue
            p = os.path.join(root, f)
            entries.append((sha256_file(p), os.path.relpath(p, out)))
    entries.sort(key=lambda e: e[1])
    with open(os.path.join(out, MANIFEST_NAME), "w") as f:
        f.writelines(f"{digest}  {name}\n" for digest, name in entries)

    print(f"[ + ] манифест: {len(entries)} записей -> {MANIFEST_NAME}")
    print(f"[ + ] {LOCK_NAME}: flowseal {args.version}, движок nfqws v{eng or '?'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
