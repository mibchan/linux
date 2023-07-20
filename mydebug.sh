#!/bin/sh

qemu-system-aarch64 \
	-S \
	-machine virt \
	-cpu cortex-a57 \
	-machine type=virt \
	-nographic \
	-smp 4 \
	-m 4096 \
	-kernel /usr/src/linux-stable/arch/arm64/boot/Image \
	--append "console=ttyAMA0 nokaslr" \
	-s
