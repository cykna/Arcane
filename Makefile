build:
	zig run tools/compile_shaders.zig
	cargo run --quiet --manifest-path ../anygpu/Cargo.toml -- shaders/wgsl/ -o shaders/bindings --validate
	zig run tools/anygpu_ziggen/cli.zig -- shaders/bindings/ -o src/shaders/

run: build
	zig build run
