module gb.gameboy;

import gb.types;
import gb.cpu;
import gb.mmu;
import gb.rom;
import w4 = wasm4;

struct GameBoy {
    CPU cpu;
    MMU mmu;

    uint totalFrames = 0;

    void init() {
        cpu.reset();
        mmu.reset();
        mmu.setRom(DEBUG_ROM);
        totalFrames = 0;
    }

    void loadCustomRom(const(u8)[] rom) {
        cpu.reset();
        mmu.reset();
        mmu.setRom(rom);
        totalFrames = 0;
    }

    void stepFrame(ubyte gamepad) {
        // Map WASM-4 gamepad to Game Boy buttons
        bool right  = (gamepad & w4.buttonRight) != 0;
        bool left   = (gamepad & w4.buttonLeft) != 0;
        bool up     = (gamepad & w4.buttonUp) != 0;
        bool down   = (gamepad & w4.buttonDown) != 0;
        bool btnA   = (gamepad & w4.button1) != 0;
        bool btnB   = (gamepad & w4.button2) != 0;
        bool select = false;
        bool start  = false;

        mmu.updateInput(right, left, up, down, btnA, btnB, select, start);

        // Run 1 frame = 70,224 T-cycles
        uint cyclesThisFrame = 0;
        while (cyclesThisFrame < GB_CYCLES_PER_FRAME) {
            uint cycles = cpu.step(mmu);
            cyclesThisFrame += cycles;

            // Step Timer
            if (mmu.timer.step(cycles)) {
                mmu.iflag |= INT_TIMER;
            }

            // Step PPU
            u8 ppuInts = mmu.ppu.step(cycles);
            if (ppuInts != 0) {
                mmu.iflag |= ppuInts;
            }
        }

        totalFrames++;
    }
}
