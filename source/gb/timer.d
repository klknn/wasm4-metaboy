module gb.timer;

import gb.types;

struct Timer {
    u16 internalCounter = 0xABCC; // Initial DMG value; upper byte is DIV (0xFF04)
    u8 tima = 0;                  // 0xFF05
    u8 tma  = 0;                  // 0xFF06
    u8 tac  = 0xF8;               // 0xFF07

    void reset() {
        internalCounter = 0xABCC;
        tima = 0;
        tma  = 0;
        tac  = 0xF8;
    }

    bool step(uint cycles) {
        if (cycles == 0) return false;

        uint start = internalCounter;
        internalCounter += cast(u16)cycles;

        if (!(tac & 0x04)) return false; // Timer disabled

        // TAC clock bits: 00: bit 9 (1024T), 01: bit 3 (16T), 10: bit 5 (64T), 11: bit 7 (256T)
        immutable uint[4] bitIndex = [9, 3, 5, 7];
        uint bit = bitIndex[tac & 0x03];

        uint edges = ((start + cycles) >> (bit + 1)) - (start >> (bit + 1));
        if (edges == 0) return false;

        bool interrupt = false;
        while (edges-- > 0) {
            if (tima == 0xFF) {
                tima = tma;
                interrupt = true;
            } else {
                tima++;
            }
        }
        return interrupt;
    }

    u8 read(u16 addr) const {
        switch (addr) {
            case 0xFF04: return cast(u8)(internalCounter >> 8);
            case 0xFF05: return tima;
            case 0xFF06: return tma;
            case 0xFF07: return tac | 0xF8;
            default:     return 0xFF;
        }
    }

    void write(u16 addr, u8 val) {
        switch (addr) {
            case 0xFF04: internalCounter = 0; break; // Any write resets DIV
            case 0xFF05: tima = val; break;
            case 0xFF06: tma  = val; break;
            case 0xFF07: tac  = val & 0x07; break;
            default: break;
        }
    }
}

unittest {
    Timer timer;
    timer.reset();

    // DIV read and reset
    assert(timer.read(0xFF04) == 0xAB);
    timer.write(0xFF04, 0x12);
    assert(timer.read(0xFF04) == 0x00);

    // Enable timer at 262,144 Hz (bit 3, every 16 T-cycles)
    timer.write(0xFF07, 0x05); // TAC: enabled, clock 01 (bit 3)
    timer.write(0xFF06, 0xA0); // TMA modulo
    timer.write(0xFF05, 0xFE); // TIMA

    // Step 8 cycles: counter bit 3 goes high
    assert(!timer.step(8));
    assert(timer.tima == 0xFE);

    // Step 8 cycles: counter bit 3 falls -> TIMA increments to 0xFF
    assert(!timer.step(8));
    assert(timer.tima == 0xFF);

    // Step 16 cycles: falling edge -> TIMA overflows to TMA (0xA0) and triggers interrupt
    assert(timer.step(16));
    assert(timer.tima == 0xA0);

    import core.stdc.stdio : printf;
    printf("✔ [Timer] Unittests passed.\n");
}
