DUB_FLAGS = --quiet --arch wasm32-unknown-unknown-wasm --build release
ifneq ($(origin WASI_SDK_PATH), undefined)
	override DUB_FLAGS += --config wasi
endif

build:
	dub build ${DUB_FLAGS}

bundle: build
	w4 bundle cart.wasm --html index.html --title "WASM-4 MetaBoy Game Boy Emulator"
	python3 scripts/patch_html.py index.html

run: build
	w4 run cart.wasm

serve: bundle
	@echo "Serving MetaBoy at http://localhost:8000 (Ctrl+C to stop)..."
	python3 -m http.server 8000

play: serve

test:
	ldc2 -i -I=source -unittest -main -run source/gb/gameboy.d

TEST_ROMS_DIR = tests/gb-test-roms
TEST_ROMS_REPO = https://github.com/retrio/gb-test-roms.git

test-blargg:
	@if [ ! -d "$(TEST_ROMS_DIR)" ]; then \
		echo "Cloning $(TEST_ROMS_REPO) into $(TEST_ROMS_DIR)..."; \
		git clone --depth 1 $(TEST_ROMS_REPO) $(TEST_ROMS_DIR); \
	fi
	ldc2 -i -I=source -run tests/run_blargg.d $(TEST_ROMS_DIR)

test-roms: test-blargg

test-all: test test-blargg

clean:
	rm -rf cart.wasm .dub screenshot.ppm tests/gb-test-roms

