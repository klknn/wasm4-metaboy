DUB_FLAGS = --quiet --arch wasm32-unknown-unknown-wasm --build release
ifneq ($(origin WASI_SDK_PATH), undefined)
	override DUB_FLAGS += --config wasi
endif

build:
	dub build ${DUB_FLAGS}

bundle: build
	w4 bundle cart.wasm --html index.html --title "WASM-4 MetaBoy Game Boy Emulator"

run: build
	w4 run cart.wasm

test:
	ldc2 -i -I=source -unittest -main -run source/gb/gameboy.d

clean:
	rm -rf cart.wasm .dub screenshot.ppm
