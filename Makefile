CLANG ?= clang
CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra -Werror

ebpf/omatunnel-connect.bpf.o: ebpf/omatunnel-connect.bpf.c
	$(CLANG) -target bpf -D__TARGET_ARCH_x86 -O2 -g -I/usr/include/$(shell uname -m)-linux-gnu -c $< -o $@

.PHONY: ebpf-check
ebpf-check: ebpf/omatunnel-connect.bpf.o ebpf/omatunnel-ebpf

ebpf/omatunnel-ebpf: ebpf/omatunnel-ebpf.c
	$(CC) $(CFLAGS) $< $$(pkg-config --cflags --libs libbpf) -pthread -o $@

.PHONY: clean
clean:
	rm -f ebpf/omatunnel-connect.bpf.o ebpf/omatunnel-ebpf
