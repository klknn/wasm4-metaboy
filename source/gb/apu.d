/**
 * Game Boy Audio Processing Unit (APU)
 *
 * Emulates the 4 Game Boy sound channels and translates hardware audio
 * registers (0xFF10 - 0xFF3F) into WASM-4 `w4.tone()` sound output:
 *
 * - Channel 1 (Pulse 1): Square wave with frequency sweep and volume envelope
 * - Channel 2 (Pulse 2): Square wave with volume envelope
 * - Channel 3 (Wave): 32-sample custom wave, mapped to WASM-4 Triangle wave
 * - Channel 4 (Noise): LFSR noise generator with volume envelope
 * - Master Control (NR50, NR51, NR52): Stereo panning, volume, and power
 */
module gb.apu;

import gb.types;
import w4 = wasm4;

struct APU {
    // Channel 1: Pulse 1 (Sweep + Envelope)
    u8 nr10 = 0x80;
    u8 nr11 = 0xBF;
    u8 nr12 = 0xF3;
    u8 nr13 = 0xFF;
    u8 nr14 = 0xBF;

    // Channel 2: Pulse 2 (Envelope)
    u8 nr21 = 0x3F;
    u8 nr22 = 0x00;
    u8 nr23 = 0xFF;
    u8 nr24 = 0xBF;

    // Channel 3: Wave (Custom Waveform)
    u8 nr30 = 0x7F;
    u8 nr31 = 0xFF;
    u8 nr32 = 0x9F;
    u8 nr33 = 0xFF;
    u8 nr34 = 0xBF;
    u8[16] waveRam;

    // Channel 4: Noise
    u8 nr41 = 0xFF;
    u8 nr42 = 0x00;
    u8 nr43 = 0x00;
    u8 nr44 = 0xBF;

    // Master controls
    u8 nr50 = 0x77;
    u8 nr51 = 0xF3;
    u8 nr52 = 0xF1; // Bit 7: Power, Bits 0-3: Ch active

    // Channel active flags
    bool ch1Active = false;
    bool ch2Active = false;
    bool ch3Active = false;
    bool ch4Active = false;

    // Dirty flags for frequency changes between triggers (vibrato/pitch bends)
    bool ch1Dirty = false;
    bool ch2Dirty = false;
    bool ch3Dirty = false;

    void reset() {
        nr10 = 0x80;
        nr11 = 0xBF;
        nr12 = 0xF3;
        nr13 = 0xFF;
        nr14 = 0xBF;

        nr21 = 0x3F;
        nr22 = 0x00;
        nr23 = 0xFF;
        nr24 = 0xBF;

        nr30 = 0x7F;
        nr31 = 0xFF;
        nr32 = 0x9F;
        nr33 = 0xFF;
        nr34 = 0xBF;
        waveRam[] = 0;

        nr41 = 0xFF;
        nr42 = 0x00;
        nr43 = 0x00;
        nr44 = 0xBF;

        nr50 = 0x77;
        nr51 = 0xF3;
        nr52 = 0xF1;

        ch1Active = false;
        ch2Active = false;
        ch3Active = false;
        ch4Active = false;

        ch1Dirty = false;
        ch2Dirty = false;
        ch3Dirty = false;
    }

    u8 read(u16 addr) const {
        switch (addr) {
            // Channel 1
            case 0xFF10: return nr10 | 0x80;
            case 0xFF11: return nr11 | 0x3F;
            case 0xFF12: return nr12;
            case 0xFF13: return 0xFF;
            case 0xFF14: return nr14 | 0xBF;

            // Channel 2
            case 0xFF15: return 0xFF;
            case 0xFF16: return nr21 | 0x3F;
            case 0xFF17: return nr22;
            case 0xFF18: return 0xFF;
            case 0xFF19: return nr24 | 0xBF;

            // Channel 3
            case 0xFF1A: return nr30 | 0x7F;
            case 0xFF1B: return 0xFF;
            case 0xFF1C: return nr32 | 0x9F;
            case 0xFF1D: return 0xFF;
            case 0xFF1E: return nr34 | 0xBF;

            // Channel 4
            case 0xFF20: return 0xFF;
            case 0xFF21: return nr42;
            case 0xFF22: return nr43;
            case 0xFF23: return nr44 | 0xBF;

            // Master controls
            case 0xFF24: return nr50;
            case 0xFF25: return nr51;
            case 0xFF26: {
                u8 res = (nr52 & 0x80) | 0x70;
                if (ch1Active) res |= 0x01;
                if (ch2Active) res |= 0x02;
                if (ch3Active) res |= 0x04;
                if (ch4Active) res |= 0x08;
                return res;
            }

            // Wave RAM
            case 0xFF30: .. case 0xFF3F:
                return waveRam[addr - 0xFF30];

            default:
                return 0xFF;
        }
    }

    void powerOff() {
        nr10 = 0; nr11 = 0; nr12 = 0; nr13 = 0; nr14 = 0;
        nr21 = 0; nr22 = 0; nr23 = 0; nr24 = 0;
        nr30 = 0; nr31 = 0; nr32 = 0; nr33 = 0; nr34 = 0;
        nr41 = 0; nr42 = 0; nr43 = 0; nr44 = 0;
        nr50 = 0; nr51 = 0; nr52 = 0;
        ch1Active = false;
        ch2Active = false;
        ch3Active = false;
        ch4Active = false;
        ch1Dirty = false;
        ch2Dirty = false;
        ch3Dirty = false;
    }

    void write(u16 addr, u8 val) {
        // If master sound is powered off, writes are ignored (except NR52 power switch and wave RAM)
        if (!(nr52 & 0x80) && addr != 0xFF26 && (addr < 0xFF30 || addr > 0xFF3F)) {
            return;
        }

        switch (addr) {
            // Channel 1
            case 0xFF10: nr10 = val; break;
            case 0xFF11: nr11 = val; break;
            case 0xFF12: {
                nr12 = val;
                if ((val & 0xF8) == 0) ch1Active = false; // DAC off
                break;
            }
            case 0xFF13: {
                nr13 = val;
                if (ch1Active) ch1Dirty = true;
                break;
            }
            case 0xFF14: {
                nr14 = val;
                if (val & 0x80) {
                    triggerPulse1();
                } else if (ch1Active) {
                    ch1Dirty = true;
                }
                break;
            }

            // Channel 2
            case 0xFF16: nr21 = val; break;
            case 0xFF17: {
                nr22 = val;
                if ((val & 0xF8) == 0) ch2Active = false; // DAC off
                break;
            }
            case 0xFF18: {
                nr23 = val;
                if (ch2Active) ch2Dirty = true;
                break;
            }
            case 0xFF19: {
                nr24 = val;
                if (val & 0x80) {
                    triggerPulse2();
                } else if (ch2Active) {
                    ch2Dirty = true;
                }
                break;
            }

            // Channel 3
            case 0xFF1A: {
                nr30 = val;
                if (!(val & 0x80)) ch3Active = false; // DAC off
                break;
            }
            case 0xFF1B: nr31 = val; break;
            case 0xFF1C: nr32 = val; break;
            case 0xFF1D: {
                nr33 = val;
                if (ch3Active) ch3Dirty = true;
                break;
            }
            case 0xFF1E: {
                nr34 = val;
                if (val & 0x80) {
                    triggerWave();
                } else if (ch3Active) {
                    ch3Dirty = true;
                }
                break;
            }

            // Channel 4
            case 0xFF20: nr41 = val; break;
            case 0xFF21: {
                nr42 = val;
                if ((val & 0xF8) == 0) ch4Active = false; // DAC off
                break;
            }
            case 0xFF22: nr43 = val; break;
            case 0xFF23: {
                nr44 = val;
                if (val & 0x80) {
                    triggerNoise();
                }
                break;
            }

            // Master controls
            case 0xFF24: nr50 = val; break;
            case 0xFF25: nr51 = val; break;
            case 0xFF26: {
                if (!(val & 0x80)) {
                    powerOff();
                } else {
                    nr52 |= 0x80; // Power on
                }
                break;
            }

            // Wave RAM
            case 0xFF30: .. case 0xFF3F:
                waveRam[addr - 0xFF30] = val;
                break;

            default: break;
        }
    }

    /**
     * Called once per frame (60 Hz) to apply continuous vibrato or pitch bends.
     */
    void updateFrame() {
        if (!(nr52 & 0x80)) return;

        if (ch1Active && ch1Dirty) {
            ch1Dirty = false;
            u16 rawFreq = nr13 | ((nr14 & 0x07) << 8);
            uint hz = rawToHzPulse(rawFreq);
            uint vol = ((nr12 >> 4) & 0x0F) * 100 / 15;
            u8 duty = (nr11 >> 6) & 0x03;
            u8 pan = getPan(4, 0);
            if (vol > 0) {
                w4.tone(hz, 3, (vol << 8) | vol, w4.tonePulse1 | (duty << 2) | pan);
            }
        }

        if (ch2Active && ch2Dirty) {
            ch2Dirty = false;
            u16 rawFreq = nr23 | ((nr24 & 0x07) << 8);
            uint hz = rawToHzPulse(rawFreq);
            uint vol = ((nr22 >> 4) & 0x0F) * 100 / 15;
            u8 duty = (nr21 >> 6) & 0x03;
            u8 pan = getPan(5, 1);
            if (vol > 0) {
                w4.tone(hz, 3, (vol << 8) | vol, w4.tonePulse2 | (duty << 2) | pan);
            }
        }

        if (ch3Active && ch3Dirty) {
            ch3Dirty = false;
            if (nr30 & 0x80) {
                u16 rawFreq = nr33 | ((nr34 & 0x07) << 8);
                uint hz = rawToHzWave(rawFreq);
                uint vol = getWaveVol();
                u8 pan = getPan(6, 2);
                if (vol > 0) {
                    w4.tone(hz, 3, (vol << 8) | vol, w4.toneTriangle | pan);
                }
            }
        }
    }

private:
    uint rawToHzPulse(u16 rawFreq) const {
        if (rawFreq >= 2048) rawFreq = 2047;
        uint denom = 2048 - rawFreq;
        if (denom == 0) denom = 1;
        uint hz = 131072 / denom;
        if (hz < 10) hz = 10;
        if (hz > 22000) hz = 22000;
        return hz;
    }

    uint rawToHzWave(u16 rawFreq) const {
        if (rawFreq >= 2048) rawFreq = 2047;
        uint denom = 2048 - rawFreq;
        if (denom == 0) denom = 1;
        uint hz = 65536 / denom;
        if (hz < 10) hz = 10;
        if (hz > 22000) hz = 22000;
        return hz;
    }

    u8 getPan(u8 leftBit, u8 rightBit) const {
        bool left = (nr51 & (1 << leftBit)) != 0;
        bool right = (nr51 & (1 << rightBit)) != 0;
        if (left && !right) return w4.tonePanLeft;
        if (!left && right) return w4.tonePanRight;
        return 0; // Center (both) or none
    }

    uint getWaveVol() const {
        u8 level = (nr32 >> 5) & 0x03;
        switch (level) {
            case 1:  return 100; // 100%
            case 2:  return 50;  // 50%
            case 3:  return 25;  // 25%
            default: return 0;   // Mute
        }
    }

    void calcEnvelope(u8 nrX2, u8 nrX1, u8 nrX4, out uint duration, out uint volume) const {
        uint initialVol = (nrX2 >> 4) & 0x0F;
        uint envDir = (nrX2 >> 3) & 0x01;
        uint envPeriod = nrX2 & 0x07;
        uint vol = (initialVol * 100) / 15;

        // Length counter: (64 - length) / 4 frames
        uint lengthFrames = 0;
        if (nrX4 & 0x40) {
            uint len = 64 - (nrX1 & 0x3F);
            lengthFrames = (len * 60) / 256;
            if (lengthFrames == 0) lengthFrames = 1;
            if (lengthFrames > 255) lengthFrames = 255;
        }

        if (envPeriod == 0 || initialVol == 0) {
            // Constant volume
            uint sustain = (lengthFrames > 0) ? lengthFrames : 20;
            duration = sustain;
            volume = (vol << 8) | vol;
        } else if (envDir == 0) {
            // Decay to 0
            uint decay = initialVol * envPeriod;
            if (lengthFrames > 0 && decay > lengthFrames) decay = lengthFrames;
            if (decay > 255) decay = 255;
            if (decay == 0) decay = 1;

            duration = (decay << 16); // Bits 16-23: Decay
            volume = (vol << 8);      // Peak: vol, Sustain: 0
        } else {
            // Fade in (Attack)
            uint attack = (15 - initialVol) * envPeriod;
            if (attack > 255) attack = 255;
            if (attack == 0) attack = 1;
            uint sustain = (lengthFrames > attack) ? (lengthFrames - attack) : 10;
            if (sustain > 255) sustain = 255;

            duration = (attack << 24) | sustain;
            volume = (100 << 8) | vol;
        }
    }

    void triggerPulse1() {
        if ((nr12 & 0xF8) == 0) {
            ch1Active = false;
            return;
        }
        ch1Active = true;
        ch1Dirty = false;

        u16 rawFreq = nr13 | ((nr14 & 0x07) << 8);
        uint startHz = rawToHzPulse(rawFreq);
        uint freq = startHz;

        // Sweep (NR10)
        u8 sweepTime = (nr10 >> 4) & 0x07;
        u8 sweepDir = (nr10 >> 3) & 0x01;
        u8 sweepShift = nr10 & 0x07;

        if (sweepShift > 0 && sweepTime > 0) {
            u16 delta = rawFreq >> sweepShift;
            int targetRaw = sweepDir ? (cast(int)rawFreq - delta) : (cast(int)rawFreq + delta);
            if (targetRaw > 0 && targetRaw < 2048) {
                uint endHz = rawToHzPulse(cast(u16)targetRaw);
                freq = (endHz << 16) | startHz;
            } else if (targetRaw >= 2048) {
                ch1Active = false;
                return; // Sweep overflow silences channel
            }
        }

        uint duration, volume;
        calcEnvelope(nr12, nr11, nr14, duration, volume);

        u8 duty = (nr11 >> 6) & 0x03;
        u8 pan = getPan(4, 0);

        w4.tone(freq, duration, volume, w4.tonePulse1 | (duty << 2) | pan);
    }

    void triggerPulse2() {
        if ((nr22 & 0xF8) == 0) {
            ch2Active = false;
            return;
        }
        ch2Active = true;
        ch2Dirty = false;

        u16 rawFreq = nr23 | ((nr24 & 0x07) << 8);
        uint hz = rawToHzPulse(rawFreq);

        uint duration, volume;
        calcEnvelope(nr22, nr21, nr24, duration, volume);

        u8 duty = (nr21 >> 6) & 0x03;
        u8 pan = getPan(5, 1);

        w4.tone(hz, duration, volume, w4.tonePulse2 | (duty << 2) | pan);
    }

    void triggerWave() {
        if (!(nr30 & 0x80)) {
            ch3Active = false;
            return;
        }
        ch3Active = true;
        ch3Dirty = false;

        u16 rawFreq = nr33 | ((nr34 & 0x07) << 8);
        uint hz = rawToHzWave(rawFreq);
        uint vol = getWaveVol();
        if (vol == 0) {
            ch3Active = false;
            return;
        }

        uint duration = 20;
        if (nr34 & 0x40) {
            uint len = 256 - nr31;
            duration = (len * 60) / 256;
            if (duration == 0) duration = 1;
            if (duration > 255) duration = 255;
        }

        u8 pan = getPan(6, 2);
        w4.tone(hz, duration, (vol << 8) | vol, w4.toneTriangle | pan);
    }

    void triggerNoise() {
        if ((nr42 & 0xF8) == 0) {
            ch4Active = false;
            return;
        }
        ch4Active = true;

        u8 s = (nr43 >> 4) & 0x0F;
        u8 r = nr43 & 0x07;

        // Approximate noise frequency in Hz:
        uint divisor = (r == 0 ? 8 : (r * 16)) << s;
        uint hz = (divisor > 0) ? (4194304 / divisor) : 400;
        if (hz < 30) hz = 30;
        if (hz > 16000) hz = 16000;

        uint duration, volume;
        calcEnvelope(nr42, nr41, nr44, duration, volume);

        u8 pan = getPan(7, 3);
        w4.tone(hz, duration, volume, w4.toneNoise | pan);
    }
}

unittest {
    APU apu;
    apu.reset();

    // 1. Verify Pan Docs unused bit masks on read
    assert((apu.read(0xFF10) & 0x80) == 0x80);
    assert((apu.read(0xFF11) & 0x3F) == 0x3F);
    assert(apu.read(0xFF13) == 0xFF);
    assert((apu.read(0xFF14) & 0xBF) == 0xBF);
    assert(apu.read(0xFF15) == 0xFF);
    assert((apu.read(0xFF26) & 0x70) == 0x70);

    // 2. Test master power off/on
    apu.write(0xFF26, 0x00); // Power off
    assert((apu.read(0xFF26) & 0x80) == 0);
    apu.write(0xFF12, 0xF3); // Should be ignored when powered off
    assert(apu.read(0xFF12) == 0x00);

    apu.write(0xFF26, 0x80); // Power on
    assert((apu.read(0xFF26) & 0x80) == 0x80);

    // 3. Test Channel 1 Pulse trigger
    apu.write(0xFF11, 0x80); // 50% duty
    apu.write(0xFF12, 0xF0); // Max volume 15, no decay
    apu.write(0xFF13, 0xD7); // Frequency low
    apu.write(0xFF14, 0x86); // Trigger + Freq high 0x06 -> raw = 0x6D7 (1751) -> ~441 Hz (A4)
    assert(apu.ch1Active);
    assert(apu.read(0xFF26) & 0x01);

    // 4. Test Channel 3 Wave RAM
    apu.write(0xFF1A, 0x80); // DAC on
    apu.write(0xFF30, 0x01);
    apu.write(0xFF3F, 0xFE);
    assert(apu.read(0xFF30) == 0x01);
    assert(apu.read(0xFF3F) == 0xFE);
    apu.write(0xFF1C, 0x20); // 100% volume
    apu.write(0xFF1E, 0x87); // Trigger Wave
    assert(apu.ch3Active);
    assert(apu.read(0xFF26) & 0x04);

    // 5. Test Channel 4 Noise trigger
    apu.write(0xFF21, 0xA2); // Vol 10, decay
    apu.write(0xFF22, 0x53);
    apu.write(0xFF23, 0x80); // Trigger Noise
    assert(apu.ch4Active);
    assert(apu.read(0xFF26) & 0x08);

    import std.stdio : writeln;
    writeln("✔ [APU] Unittests passed.");
}

