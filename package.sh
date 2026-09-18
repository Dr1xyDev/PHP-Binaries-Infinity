#!/usr/bin/env bash
# Empaqueta bin/ conservando SYMLINKS (libffi.so -> libffi.so.8 -> libffi.so.8.x.y)
# y verifica que ninguna libreria .so se pierda ni quede rota.
#
# Uso: ./package.sh <nombre-salida.tar.gz> [directorio=bin]
#   ej: ./package.sh PHP-8.4-Linux-x86_64-PM5.tar.gz
#
# Reglas clave:
#  - tar SIN la opcion -h/--dereference  => guarda el symlink como symlink (no copia el archivo)
#  - se comprueba ANTES de empaquetar que no haya symlinks rotos
#  - se comprueba DESPUES (extrayendo en un tmp) que los symlinks sigan siendo symlinks
set -euo pipefail

OUT="${1:?Uso: $0 <salida.tar.gz> [directorio]}"
SRC="${2:-bin}"

if [ ! -d "$SRC" ]; then
	echo "[package] ERROR: no existe el directorio '$SRC'" >&2
	exit 1
fi

echo "[package] Revisando symlinks en $SRC ..."

# 1) Symlinks rotos = libs que se perderian. Abortar.
BROKEN="$(find "$SRC" -xtype l 2>/dev/null || true)"
if [ -n "$BROKEN" ]; then
	echo "[package] ERROR: symlinks rotos detectados (apuntan a algo que no existe):" >&2
	echo "$BROKEN" >&2
	exit 1
fi

NUM_LINKS="$(find "$SRC" -type l | wc -l)"
NUM_SO="$(find "$SRC" \( -name '*.so' -o -name '*.so.*' \) | wc -l)"
echo "[package] symlinks: $NUM_LINKS | archivos .so (incl. links): $NUM_SO"

# 2) Empaquetar. NUNCA usar -h / --dereference aqui.
#    --numeric-owner evita depender de usuarios locales del runner.
tar --numeric-owner -czf "$OUT" "$SRC"

# 3) Verificar el resultado: extraer en un dir temporal y comparar symlinks
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$OUT" -C "$TMP"

EXPECTED="$(cd "$SRC" && find . -type l | sort)"
GOT="$(cd "$TMP/$SRC" && find . -type l | sort)"

if [ "$EXPECTED" != "$GOT" ]; then
	echo "[package] ERROR: los symlinks del tarball NO coinciden con los originales" >&2
	diff <(echo "$EXPECTED") <(echo "$GOT") >&2 || true
	exit 1
fi

# 4) Ningun link roto tras extraer
BROKEN_AFTER="$(find "$TMP/$SRC" -xtype l 2>/dev/null || true)"
if [ -n "$BROKEN_AFTER" ]; then
	echo "[package] ERROR: symlinks rotos despues de extraer:" >&2
	echo "$BROKEN_AFTER" >&2
	exit 1
fi

echo "[package] OK -> $OUT ($(du -h "$OUT" | cut -f1)) - $NUM_LINKS symlinks preservados"
