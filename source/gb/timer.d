module gb.timer;

import gb.types;

struct Timer {
    u16 internalCounter = 0; // Increments every T-cycle; upper byte is DIV
    u8 tima = 0;             // 0xFF05
    u8 tma = 0;              // 0xFF06
    u8 tac = 0;              // 0xFF07

    void reset() {
        internalCounter = 0xABCC; // Initial DMG value
        tima = 0;
        tma = 0;
        tac = 0xF8;
    }

    // Step the timer by `cycles` T-cycles.
    // Returns true if a timer interrupt should be requested.
    bool step(uint cycles) {
        bool interrupt = false;
        
        while (cycles > 0) {
            uint stepCycles = cycles > 16 ? 16 : cycles;
            cycles -= stepCycles;

            u16 prevCounter = internalCounter;
            internalCounter += cast(u16)stepCycles;

            // Check if timer is enabled (bit 2 of TAC)
            if (tac & 0x04) {
                // Determine which bit of internalCounter triggers TIMA increment:
                // TAC 00: bit 9  (1024 cycles)
                // TAC 01: bit 3  (16 cycles)
                // TAC 10: bit 5  (64 cycles)
                // TAC 11: bit 7  (256 cycles)
                uint bitIndex;
                switch (tac & 0x03) {
                    case 0: bitIndex = 9; break;
                    case 1: bitIndex = 3; break;
                    case 2: bitIndex = 5; break;
                    default: bitIndex = 7; break;
                }

                // Falling edge detector on the counter bit
                bool prevBit = (prevCounter & (1 << bitIndex)) != 0;
                bool currBit = (internalCounter & (1 << bitIndex)) != 0;
                if (prevBit && !currBit) {
                    if (tima == 0xFF) {
                        tima = tma;
                        interrupt = true;
                    } else {
                        tima++;
                    }
                }
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
            default: return 0xFF;
        }
    }

    void write(u16 addr, u8 val) {
        switch (addr) {
            case 0xFF04: internalCounter = 0; break; // Writing any value resets DIV
            case 0xFF05: tima = val; break;
            case 0xFF06: tma = val; break;
            case 0xFF07: tac = val & 0x07; break;
            default: break;
        }
    }
}
