#!/bin/bash
# FFI debe estar compilado, habilitado (ffi.enable=true) y llamar a libc de verdad.
"$PHP_BINARIES" -m | grep -qix 'FFI' || exit 1

OUTPUT=$("$PHP_BINARIES" -r 'echo FFI::cdef("int abs(int j);")->abs(-7);')
if [ "$OUTPUT" != "7" ]; then
	exit 1
fi

exit 0
