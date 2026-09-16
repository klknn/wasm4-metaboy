module app;

import w4 = wasm4;
import gb.gameboy;

// Global Game Boy instance
static GameBoy gameboy;

extern(C) void start() {
    // Set classic Game Boy DMG palette:
    // Color 1: Lightest
    // Color 2: Light Gray
    // Color 3: Dark Gray
    // Color 4: Darkest
    w4.palette[0] = 0xE0F8D0;
    w4.palette[1] = 0x88C070;
    w4.palette[2] = 0x346856;
    w4.palette[3] = 0x081820;

    // Preserve framebuffer so PPU writes are retained
    *w4.systemFlags |= w4.systemPreserveFramebuffer;

    // Initialize Game Boy emulator and load debug ROM
    gameboy.init();

    w4.trace("MetaBoy Game Boy Emulator Initialized!\0".ptr);
}

extern(C) void update() {
    const ubyte pad = *w4.gamepad1;

    // Emulate 1 frame (70,224 cycles)
    gameboy.stepFrame(pad);

    // Draw bottom debug status bar (lines 144..159)
    // Horizontal divider
    *w4.drawColors = 0x03; // Color 3 (dark)
    w4.hline(0, 144, 160);

    // Debug status text
    *w4.drawColors = 0x31; // Color 3 on Color 1 background
    
    // Create a simple hex string for PC and SP
    char[16] status = [
        'P', 'C', ':',
        toHexChar((gameboy.cpu.pc >> 12) & 0xF),
        toHexChar((gameboy.cpu.pc >> 8) & 0xF),
        toHexChar((gameboy.cpu.pc >> 4) & 0xF),
        toHexChar(gameboy.cpu.pc & 0xF),
        ' ',
        'S', 'P', ':',
        toHexChar((gameboy.cpu.sp >> 12) & 0xF),
        toHexChar((gameboy.cpu.sp >> 8) & 0xF),
        toHexChar((gameboy.cpu.sp >> 4) & 0xF),
        toHexChar(gameboy.cpu.sp & 0xF),
        '\0'
    ];
    w4.text(status.ptr, 4, 148);
}

private char toHexChar(int v) {
    v &= 0xF;
    if (v < 10) return cast(char)('0' + v);
    return cast(char)('A' + (v - 10));
}
