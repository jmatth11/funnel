
.PHONY: all
all:
	gcc main.c -L../../zig-out/lib/ -I../../headers/ -lfunnel -o simple_example

.PHONY: run
run: all
	./simple_example
