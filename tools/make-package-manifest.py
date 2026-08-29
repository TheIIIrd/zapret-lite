#!/usr/bin/env python3
"""
Манифест целостности всего комплекта.

vendor/flowseal/MANIFEST.sha256 покрывает только данные flowseal - самое
безобидное, что есть в комплекте. Гораздо важнее защитить то, что
исполняется с правами root:

    strategies/*.conf   читаются через '.' из /opt/zapret/config
    lib/common.sh       подключается установщиком и менеджером
    bin/zapret-lite     запускается через sudo
    install.sh          он и есть root-процесс
    zapret/**           init-скрипт и сам nfqws
    systemd/*           юниты

Манифест не подпись: он ловит повреждение и точечную подмену файла, но
не защищает от замены комплекта целиком вместе с манифестом. Для этого
нужна подпись, см. docs/security.md.

Использование:
    make-package-manifest.py <каталог_комплекта> [--check]
"""

import argparse
import hashlib
import os
import sys

MANIFEST = "MANIFEST.sha256"

# Каталоги, которые в комплект не входят и в манифест попасть не должны.
#
# ВАЖНО: тот же список продублирован в zl_verify_manifest (lib/common.sh),
# и правила обязаны совпадать. Однажды они разошлись - здесь исключение
# работало на любой глубине, а в shell только на верхнем уровне, - и
# файлы zapret/.github/* оказались в проверке, но не в манифесте:
# установка обрывалась на "лишних файлах". Тест
# "оба обходчика видят одинаковый набор файлов" следит, чтобы это не
# повторилось.
SKIP_DIRS = {".git", "__pycache__", ".github", "tests", "dist"}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def walk(root):
    """Все файлы комплекта, кроме самого манифеста.

    Симлинки пропускаются: sha256 от них считать нечего, а внутри
    комплекта их и не бывает - install_bin.sh создаёт их уже на целевой
    машине.
    """
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if rel == MANIFEST:
                continue
            if os.path.islink(full):
                continue
            yield rel, full


def build(root):
    lines = []
    for rel, full in walk(root):
        lines.append(f"{sha256_file(full)}  {rel}\n")
    with open(os.path.join(root, MANIFEST), "w") as f:
        f.writelines(lines)
    print(f"[ + ] {MANIFEST}: {len(lines)} записей")
    return 0


def check(root):
    path = os.path.join(root, MANIFEST)
    if not os.path.isfile(path):
        print(f"[ - ] нет {MANIFEST}", file=sys.stderr)
        return 1

    expected = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            digest, _, rel = line.partition("  ")
            expected[rel] = digest

    actual = dict(walk(root))
    bad = []

    for rel, digest in expected.items():
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            bad.append(f"пропал: {rel}")
        elif sha256_file(full) != digest:
            bad.append(f"изменён: {rel}")

    # Лишние файлы важны не меньше пропавших: sha256sum -c их не замечает,
    # а подброшенная strategies/evil.conf прекрасно выберется через
    # zapret-lite use.
    for rel in actual:
        if rel not in expected:
            bad.append(f"лишний: {rel}")

    if bad:
        for b in bad:
            print(f"[ - ] {b}", file=sys.stderr)
        return 1

    print(f"[ + ] комплект цел: {len(expected)} файлов")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    return check(args.root) if args.check else build(args.root)


if __name__ == "__main__":
    sys.exit(main())
