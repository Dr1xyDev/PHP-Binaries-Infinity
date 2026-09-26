#!/usr/bin/env bash
# Empaqueta bin/ en .tar.gz Y .zip, garantizando que ninguna lib .so se pierda
# ni quede vacia al descomprimir en cualquier lado (FileZilla, Windows, cPanel, etc.).
#
# Uso: ./package.sh <nombre-salida.tar.gz> [directorio=bin]
#   ej: ./package.sh PHP-8.4-Linux-x86_64-PM5.tar.gz
#
# PROBLEMA QUE RESUELVE:
#   Las libs dinamicas viven como CADENA DE SYMLINKS:
#       libssl.so -> libssl.so.3 -> libssl.so.3.0.x   (solo el ultimo es un archivo real)
#   El tarball conserva los symlinks, pero al descomprimir con herramientas que NO
#   soportan symlinks (FileZilla, explorador de Windows, cPanel, zip sin -y, etc.)
#   cada symlink se convierte en un archivo de 0 bytes:
#       - php arranca con "File too short" (el linker abre el .so de 0 bytes), o
#       - "libXXX.so.NN: cannot open shared object file: No such file or directory"
#
# SOLUCION (doble):
#   1) Dentro del TAR, las cadenas de symlinks se convierten en HARDLINKS al archivo
#      real. Un hardlink apunta al mismo inodo/datos: al descomprimir en cualquier
#      sistema se materializa como un archivo NORMAL con el contenido completo del
#      .so. El loader dinámico resuelve libssl.so.3 sin importar que sea hardlink
#      o symlink. (Antes solo se verificaba que fueran symlinks, no que sirvieran.)
#   2) Se genera tambien un .zip GEMELO con el mismo contenido. El formato zip NO
#      soporta symlinks/hardlinks en extractores comunes, pero como ahora todo es
#      un archivo normal con datos, el zip queda completo y usable. El .zip es la
#      descarga recomendada para usuarios de FileZilla/Windows/cPanel.
#
# Reglas clave:
#  - se comprueba ANTES de empaquetar que no haya symlinks rotos
#  - se comprueba DESPUES (extrayendo en un tmp) que cada .so/.dylib extraido tenga
#    el MISMO tamano y checksum que el original => no hay archivos vacios ni truncados
set -euo pipefail

OUT_TAR="${1:?Uso: $0 <salida.tar.gz> [directorio]}"
SRC="${2:-bin}"
OUT_ZIP="${OUT_TAR%.tar.gz}.zip"

if [ ! -d "$SRC" ]; then
	echo "[package] ERROR: no existe el directorio '$SRC'" >&2
	exit 1
fi

echo "[package] Preparando $SRC (symlinks -> hardlinks) ..."

# 1) Symlinks rotos = libs que se perderian. Abortar.
BROKEN="$(find "$SRC" -xtype l 2>/dev/null || true)"
if [ -n "$BROKEN" ]; then
	echo "[package] ERROR: symlinks rotos detectados (apuntan a algo que no existe):" >&2
	echo "$BROKEN" >&2
	exit 1
fi

NUM_LINKS="$(find "$SRC" -type l | wc -l)"
NUM_SO="$(find "$SRC" \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dylib.*' \) ! -type l | wc -l)"
echo "[package] symlinks: $NUM_LINKS | archivos .so/.dylib reales: $NUM_SO"

# 2) Convertir cada cadena de symlinks en HARDLINKS al destino real.
#    Un hardlink se extrae como archivo normal (con todo su contenido) en
#    cualquier sistema, evitando los temidos .so de 0 bytes.
#    Nota: find -type l no sigue symlinks, asi que no hay riesgo de tocar el real.
LINKS_LIST="$(mktemp)"
find "$SRC" -type l -print0 | sort -z > "$LINKS_LIST"
while IFS= read -r -d '' link; do
	target="$(readlink "$link")"
	case "$target" in
		/*) echo "[package] ERROR: symlink absoluto no soportado: $link -> $target" >&2; exit 1 ;;
	esac
	dir="$(dirname "$link")"
	resolved="$(cd "$dir" && readlink -m "$target")"
	if [ ! -f "$resolved" ]; then
		echo "[package] ERROR: el destino del symlink no es un archivo regular: $link -> $target" >&2
		exit 1
	fi
	rm "$link"
	ln "$resolved" "$link"   # hardlink
done < "$LINKS_LIST"
rm -f "$LINKS_LIST"
echo "[package] $(find "$SRC" -type l | wc -l) symlinks restantes; $(find "$SRC" -type l -links 1 -o -type f -links +1 | wc -l) archivos enlazados"

# 3) Empaquetar .tar.gz. NUNCA usar -h / --dereference aqui: los hardlinks ya
#    comparten inodo y tar los guarda como multiplos enlaces al mismo dato.
#    --numeric-owner evita depender de usuarios locales del runner.
tar --numeric-owner -czf "$OUT_TAR" "$SRC"

# 4) Empaquetar .zip gemelo (recomendado para FileZilla / Windows / cPanel).
#    Todos los .so son archivos normales => el zip no puede dejarlos vacios.
if command -v zip >/dev/null 2>&1; then
	rm -f "$OUT_ZIP"
	zip -q -r "$OUT_ZIP" "$SRC"
	echo "[package] zip gemelo: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
else
	echo "[package] AVISO: 'zip' no disponible; se omite el .zip gemelo" >&2
fi

# 5) Verificar el resultado: extraer en un dir temporal y comparar el CONTENIDO
#    de cada .so/.dylib (tamano + sha256) contra el original.
#    Esto detecta archivos vacios o truncados, que antes pasaban desapercibidos.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/tar" "$TMP/zip"
tar -xzf "$OUT_TAR" -C "$TMP/tar"

EXPECTED="$(cd "$SRC" && find . \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dylib.*' \) -type f -print0 | sort -z | xargs -0 sha256sum)"
GOT_TAR="$(cd "$TMP/tar/$SRC" && find . \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dylib.*' \) -type f -print0 | sort -z | xargs -0 sha256sum)"

if [ "$EXPECTED" != "$GOT_TAR" ]; then
	echo "[package] ERROR: el contenido de las libs en el tarball NO coincide con el original" >&2
	diff <(echo "$EXPECTED") <(echo "$GOT_TAR") >&2 || true
	exit 1
fi
echo "[package] tar OK: $NUM_SO libs verificadas por sha256 (sin archivos vacios ni truncados)"

if [ -f "$OUT_ZIP" ]; then
	(unzip -q -o "$OUT_ZIP" -d "$TMP/zip") || { echo "[package] ERROR: el .zip no se puede extraer" >&2; exit 1; }
	GOT_ZIP="$(cd "$TMP/zip/$SRC" && find . \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dylib.*' \) -type f -print0 | sort -z | xargs -0 sha256sum)"
	if [ "$EXPECTED" != "$GOT_ZIP" ]; then
		echo "[package] ERROR: el contenido de las libs en el .zip NO coincide con el original" >&2
		diff <(echo "$EXPECTED") <(echo "$GOT_ZIP") >&2 || true
		exit 1
	fi
	echo "[package] zip OK: $NUM_SO libs verificadas por sha256"
fi

# 6) En el tarball, las antiguas cadenas de symlinks ahora son hardlinks (mismos
#    datos, varios nombres). Verificar que ningun link quedo roto tras extraer.
BROKEN_AFTER="$(find "$TMP/tar/$SRC" -xtype l 2>/dev/null || true)"
if [ -n "$BROKEN_AFTER" ]; then
	echo "[package] ERROR: symlinks rotos despues de extraer:" >&2
	echo "$BROKEN_AFTER" >&2
	exit 1
fi

echo "[package] OK -> $OUT_TAR ($(du -h "$OUT_TAR" | cut -f1)) - $NUM_SO libs verificadas, symlinks convertidos a hardlinks"
