/**
 * WASM-4 MetaBoy Game Boy Emulator - Main Application Entrypoint
 *
 * Architecture & Hardware Mapping:
 * - Canvas: WASM-4 provides a 160x160 4-color framebuffer (6,400 bytes, 2bpp).
 *   - Y=0..143:   Active Game Boy display area (160x144 pixels).
 *   - Y=144..159: MetaBoy status bar displaying live PC (Program Counter) & SP (Stack Pointer).
 * - Palette: Custom 4-color classic DMG green palette configured in start().
 * - Linear Memory Allocation (with 2 MB extended WebAssembly memory):
 *   - 0x00000 - 0x0FFFF: WASM-4 memory-mapped I/O, framebuffer, stack, and globals (64 KiB).
 *   - 0x10000 - 0x8FFFF: Game Boy Cartridge ROM buffer (up to 512 KiB, e.g. Pokemon Red).
 *   - 0x90000 - 0x97FFF: Game Boy Cartridge SRAM buffer (32 KiB, 4 banks of 8 KiB).
 */
module app;

import w4 = wasm4;
import gb.types;
import gb.gameboy;

static GameBoy gameboy;

/**
 * Called once when the WASM-4 cartridge is initialized.
 */
extern(C) void start() {
    // Classic DMG Green Palette
    w4.palette[0] = 0xE0F8D0;
    w4.palette[1] = 0x88C070;
    w4.palette[2] = 0x346856;
    w4.palette[3] = 0x081820;

    *w4.systemFlags |= w4.systemPreserveFramebuffer;
    gameboy.init();
    w4.trace("MetaBoy Game Boy Emulator Initialized!\0".ptr);
}

/**
 * Called at 60 Hz by WASM-4 runtime to update state and render a frame.
 */
extern(C) void update() {
    gameboy.stepFrame(*w4.gamepad1, *w4.gamepad2, *w4.mouseButtons);

    // Bottom debug status bar (lines 144..159)
    *w4.drawColors = 0x03;
    w4.hline(0, 144, 160);

    *w4.drawColors = 0x31;
    char[16] status = "PC:0000 SP:0000\0";
    formatHex16(status.ptr + 3, gameboy.cpu.pc);
    formatHex16(status.ptr + 11, gameboy.cpu.sp);
    w4.text(status.ptr, 4, 148);
}

extern(C) ubyte* getRomBuffer(size_t size) {
    return cast(ubyte*)0x10000;
}

extern(C) void loadRom(size_t size) {
    ubyte* romPtr = cast(ubyte*)0x10000;
    ubyte* ramPtr = cast(ubyte*)0x90000;
    gameboy.loadCustomRom(romPtr[0 .. size], ramPtr[0 .. 32768]);
    w4.trace("Custom Game Boy ROM loaded!\0".ptr);
}

private void formatHex16(char* dest, u16 val) {
    for (int i = 3; i >= 0; i--) {
        int nib = val & 0xF;
        dest[i] = cast(char)(nib < 10 ? '0' + nib : 'A' + nib - 10);
        val >>= 4;
    }
}
