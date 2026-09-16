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
    gameboy.stepFrame(*w4.gamepad1);

    // Bottom debug status bar (lines 144..159)
    *w4.drawColors = 0x03;
    w4.hline(0, 144, 160);

    *w4.drawColors = 0x31;
    char[16] status = "PC:0000 SP:0000\0";
    formatHex16(status.ptr + 3, gameboy.cpu.pc);
    formatHex16(status.ptr + 11, gameboy.cpu.sp);
    w4.text(status.ptr, 4, 148);
}

private void formatHex16(char* dest, u16 val) {
    for (int i = 3; i >= 0; i--) {
        int nib = val & 0xF;
        dest[i] = cast(char)(nib < 10 ? '0' + nib : 'A' + nib - 10);
        val >>= 4;
    }
}
