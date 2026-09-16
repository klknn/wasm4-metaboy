module app;

import w4 = wasm4;
import gb.types;
import gb.gameboy;

static GameBoy gameboy;

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
