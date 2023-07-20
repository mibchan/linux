#!/bin/sh

gdb-multiarch \
	-ex "set arch aarch64" \
	-ex "file vmlinux" \
	-ex "target remote:1234" \
