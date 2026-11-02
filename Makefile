build:
	zig run tools/compile_shaders.zig
	anygpu --wesl shaders/wesl/ -o shaders/bindings --validate
	zig run tools/anygpu_ziggen/cli.zig -- shaders/bindings/ -o src/shaders/

run: build
	zig build run
