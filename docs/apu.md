# Game Boy APU Architecture & WASM-4 Sound Engine Mapping

This document details the design and implementation of MetaBoy's **Audio Processing Unit (APU)** module ([`source/gb/apu.d`](../source/gb/apu.d)), explaining how the original Game Boy's 4-channel sound synthesizer is mapped onto the **WASM-4 fantasy console sound API** (`w4.tone()`).

---

## 1. Overview & Architectural Contrast

| Feature | Original Game Boy (DMG-01) | WASM-4 Fantasy Console |
| :--- | :--- | :--- |
| **Channels** | 4 channels: Pulse 1, Pulse 2, Wave, Noise | 4 channels: Pulse 1, Pulse 2, Triangle, Noise |
| **Audio Paradigm** | Continuous register writes (cycle-by-cycle) | Event-driven audio queue (`w4.tone()`) |
| **Synthesis Driver** | Hardware analog mixer & DACs | WebAudio `AudioWorkletProcessor` (44.1 kHz) |
| **Frequency Model** | 11-bit period divider ($f = \frac{131072}{2048 - x}$) | Direct frequency in Hz ($1\text{ Hz} .. 65535\text{ Hz}$) |
| **Envelopes** | Hardware step envelope (1/64s timer steps) | 32-bit packed ADSR (Attack, Decay, Sustain, Release) |
| **Stereo** | Discrete Left/Right routing via `NR51` | Panning flags (`tonePanLeft`, `tonePanRight`, Center) |

Because WASM-4 does not expose a raw PCM audio sample buffer to WebAssembly cartridges, a software emulator cannot stream a raw 44.1 kHz audio buffer directly. Instead, MetaBoy implements a **register-to-event translator**: it intercepts the Game Boy CPU's writes to I/O registers `0xFF10..0xFF3F` and converts note triggers, frequency sweeps, volume envelopes, and pitch bends into high-level `w4.tone()` commands.

---

## 2. Channel-by-Channel Mapping

```
Game Boy APU Registers (0xFF10..0xFF3F)
  ├── Ch 1 (NR10-NR14) ──► Frequency Sweep & Envelope ──► WASM-4 tonePulse1 (Ch 0)
  ├── Ch 2 (NR21-NR24) ──► Duty & Volume Envelope    ──► WASM-4 tonePulse2 (Ch 1)
  ├── Ch 3 (NR30-NR34) ──► Wave RAM & Output Level   ──► WASM-4 toneTriangle (Ch 2)
  ├── Ch 4 (NR41-NR44) ──► LFSR Polynomial Noise     ──► WASM-4 toneNoise (Ch 3)
  └── Master (NR50-NR52)─► Stereo Pan & Power Gate   ──► w4.tone(freq, dur, vol, flags)
```

### Channel 1: Pulse 1 (Sweep + Envelope)
*Game Boy Registers: `NR10` (0xFF10), `NR11` (0xFF11), `NR12` (0xFF12), `NR13` (0xFF13), `NR14` (0xFF14)*

1. **Frequency Formula**:
   The Game Boy uses an 11-bit divider value ($x = \text{NR13} \mid ((\text{NR14} \& 0x07) \ll 8)$):
   $$f_{\text{Hz}} = \frac{131072}{2048 - x}$$
2. **Duty Cycle**:
   Bits 6–7 of `NR11` select one of four wave duty cycles:
   - `00` (12.5%) $\rightarrow$ `w4.toneMode1`
   - `01` (25.0%) $\rightarrow$ `w4.toneMode2`
   - `10` (50.0%) $\rightarrow$ `w4.toneMode3`
   - `11` (75.0%) $\rightarrow$ `w4.toneMode4` (acoustically identical to 25%)
3. **Hardware Frequency Sweep (`NR10`)**:
   - `sweepShift = NR10 & 0x07`
   - `sweepDir = (NR10 >> 3) & 0x01` (1 = decrease, 0 = increase)
   - `sweepTime = (NR10 >> 4) & 0x07`
   When active, MetaBoy computes the sweep destination:
   $$\Delta = x \gg \text{sweepShift}$$
   $$x_{\text{target}} = \text{sweepDir} \;?\; (x - \Delta) : (x + \Delta)$$
   WASM-4 natively supports continuous frequency sliding in a single `tone()` call by encoding start and end frequencies:
   $$\text{frequency} = (f_{\text{target}} \ll 16) \mid f_{\text{start}}$$
   This perfectly reproduces jump sounds (e.g., in *Super Mario Land*) and pitch bend sound effects.

---

### Channel 2: Pulse 2 (Envelope)
*Game Boy Registers: `NR21` (0xFF16), `NR22` (0xFF17), `NR23` (0xFF18), `NR24` (0xFF19)*

Channel 2 functions identically to Channel 1, but without the frequency sweep unit. It is typically used for melody harmonies, counterpoint, and coin/beep sound effects. It maps directly to `w4.tonePulse2` (channel 1).

---

### Channel 3: Wave (Custom Waveform)
*Game Boy Registers: `NR30` (0xFF1A), `NR31` (0xFF1B), `NR32` (0xFF1C), `NR33` (0xFF1D), `NR34` (0xFF1E), Wave RAM `0xFF30..0xFF3F`*

1. **Hardware Overview**:
   Channel 3 reads 32 4-bit audio samples from internal Wave RAM (`0xFF30..0xFF3F`).
2. **Frequency Formula**:
   Because the wave channel cycles through 32 samples with a 2-cycle step (64 clock cycles per wave period), its frequency is half that of the pulse channels:
   $$f_{\text{Hz}} = \frac{65536}{2048 - x}$$
3. **WASM-4 Mapping (`toneTriangle`)**:
   In over 95% of Game Boy games (such as *Pokémon Red/Blue*, *Super Mario Land*, *The Legend of Zelda: Link's Awakening*, and *Tobu Tobu Girl*), Wave RAM is loaded with stepped triangle/sine wave patterns to generate smooth **basslines**.
   MetaBoy maps Channel 3 directly to WASM-4's `toneTriangle` (channel 2).
4. **Volume Scaling (`NR32`)**:
   Bits 5–6 of `NR32` specify output volume attenuation:
   - `00`: Mute ($0\%$)
   - `01`: $100\%$ volume
   - `10`: $50\%$ volume
   - `11`: $25\%$ volume

---

### Channel 4: Noise (Percussion & Sound Effects)
*Game Boy Registers: `NR41` (0xFF20), `NR42` (0xFF21), `NR43` (0xFF22), `NR44` (0xFF23)*

1. **Hardware Overview**:
   Channel 4 utilizes a Linear Feedback Shift Register (LFSR) with selectable 7-bit (metallic/buzzing) or 15-bit (white noise) modes.
2. **Frequency Formula**:
   Controlled by shift clock $s$ (`NR43` bits 4–7) and dividing ratio $r$ (`NR43` bits 0–2):
   $$\text{divisor} = (r == 0 \;?\; 8 : (r \times 16)) \ll s$$
   $$f_{\text{Hz}} = \frac{4194304}{\text{divisor}}$$
   MetaBoy clamps the resulting pitch to $[30\text{ Hz}, 16000\text{ Hz}]$, mapping it to WASM-4's `toneNoise` (channel 3) to accurately reproduce snare drums, hi-hats, and explosion effects.

---

## 3. Volume Envelope & ADSR Translation

The Game Boy volume envelope register (`NRx2`) specifies:
- `initialVol`: 4 bits ($0..15$)
- `envDir`: 1 bit ($0 = \text{decrease/decay}, 1 = \text{increase/attack}$)
- `envPeriod`: 3 bits ($0 = \text{steady}, 1..7 = \text{step period in 64 Hz units}$)

WASM-4's `duration` and `volume` parameters encode an ADSR curve:

```
WASM-4 Duration (32-bit):
[ Attack (8b) | Decay (8b) | Release (8b) | Sustain (8b) ]

WASM-4 Volume (16-bit):
[ Peak Volume (8b) | Sustain Volume (8b) ]
```

MetaBoy translates the Game Boy envelope as follows:

```d
void calcEnvelope(u8 nrX2, u8 nrX1, u8 nrX4, out uint duration, out uint volume) const {
    uint initialVol = (nrX2 >> 4) & 0x0F;
    uint envDir     = (nrX2 >> 3) & 0x01;
    uint envPeriod  = nrX2 & 0x07;
    uint vol        = (initialVol * 100) / 15; // Scale 0..15 -> 0..100%

    // Length counter: (64 - length) / 4 frames
    uint lengthFrames = 0;
    if (nrX4 & 0x40) {
        uint len = 64 - (nrX1 & 0x3F);
        lengthFrames = (len * 60) / 256;
        if (lengthFrames == 0) lengthFrames = 1;
        if (lengthFrames > 255) lengthFrames = 255;
    }

    if (envPeriod == 0 || initialVol == 0) {
        // Steady note: constant sustain volume
        uint sustain = (lengthFrames > 0) ? lengthFrames : 20;
        duration = sustain;
        volume   = (vol << 8) | vol;
    } else if (envDir == 0) {
        // Standard decay (fade out)
        uint decay = initialVol * envPeriod;
        if (lengthFrames > 0 && decay > lengthFrames) decay = lengthFrames;
        if (decay > 255) decay = 255;
        if (decay == 0) decay = 1;

        duration = (decay << 16); // Bits 16..23: Decay
        volume   = (vol << 8);    // Peak: vol, Sustain: 0
    } else {
        // Attack (fade in)
        uint attack = (15 - initialVol) * envPeriod;
        if (attack > 255) attack = 255;
        if (attack == 0) attack = 1;
        uint sustain = (lengthFrames > attack) ? (lengthFrames - attack) : 10;
        if (sustain > 255) sustain = 255;

        duration = (attack << 24) | sustain;
        volume   = (100 << 8) | vol;
    }
}
```

---

## 4. Master Control & Stereo Panning

### Stereo Routing (`NR51` at 0xFF25)
Game Boy `NR51` independently assigns each channel to Left (SO2) and/or Right (SO1) output terminals:

| Channel | Left Bit (SO2) | Right Bit (SO1) | WASM-4 Flag |
| :--- | :--- | :--- | :--- |
| **Channel 1** | Bit 4 | Bit 0 | `tonePanLeft` (16) / `tonePanRight` (32) / Center (0) |
| **Channel 2** | Bit 5 | Bit 1 | `tonePanLeft` (16) / `tonePanRight` (32) / Center (0) |
| **Channel 3** | Bit 6 | Bit 2 | `tonePanLeft` (16) / `tonePanRight` (32) / Center (0) |
| **Channel 4** | Bit 7 | Bit 3 | `tonePanLeft` (16) / `tonePanRight` (32) / Center (0) |

```d
u8 getPan(u8 leftBit, u8 rightBit) const {
    bool left  = (nr51 & (1 << leftBit)) != 0;
    bool right = (nr51 & (1 << rightBit)) != 0;
    if (left && !right) return w4.tonePanLeft;
    if (!left && right) return w4.tonePanRight;
    return 0; // Center (both channels)
}
```

### Power Control (`NR52` at 0xFF26)
- **Bit 7 = 0**: Disables all sound hardware. In accordance with Game Boy hardware specifications, MetaBoy's `powerOff()` zeroes all registers (`0xFF10..0xFF25`), resets internal channel state, and ignores subsequent register writes until power is re-enabled.
- **Bits 0–3 (Read-only)**: Reports whether channels 1–4 are actively playing audio.

### Register Read Masks
Unused register bits on the DMG-01 hardware float high and read back as `1`. MetaBoy strictly adheres to the Pan Docs read mask specification:

```d
case 0xFF10: return nr10 | 0x80;
case 0xFF11: return nr11 | 0x3F;
case 0xFF13: return 0xFF; // Write-only
case 0xFF14: return nr14 | 0xBF;
case 0xFF15: return 0xFF; // Unused
case 0xFF26: return (nr52 & 0x80) | 0x70 | activeChannelBits;
```

---

## 5. Dual Trigger & Frame-Rate Modulation Strategy

Many Game Boy music engines (including the Game Freak Pokémon sound driver and Hirokazu Tanaka's driver in *Super Mario Land*) modulate audio in two distinct ways:

1. **Note Triggers**: Bit 7 of `NR14`, `NR24`, `NR34`, or `NR44` is written with `1`. The APU immediately evaluates parameters and dispatches a full `w4.tone()` note.
2. **Continuous Modulation (Vibrato & Pitch Bends)**: During active sustain, the sound driver updates frequency registers (`NR13` / `NR23` / `NR33`) at 60 Hz (inside the VBlank interrupt) without retriggering the note.

If an emulator only responds to triggers, vibrato and pitch slides are lost. Conversely, if an emulator fires `w4.tone()` on every register write, it floods WASM-4's WebAudio message queue with dozens of redundant calls per frame.

MetaBoy solves this with **dirty tracking and frame-rate modulation**:
- On note trigger (`val & 0x80`): The note plays immediately.
- On frequency/volume modification during sustain: The channel is marked `dirty`.
- At frame boundary ([`GameBoy.stepFrame()`](../source/gb/gameboy.d)): [`apu.updateFrame()`](../source/gb/apu.d) executes once per frame (60 Hz), dispatching a smooth 3-frame continuation tone with the updated pitch only if the channel was modified.

---

## 6. Binary Size & Performance Impact

- **Code Size**: The entire APU implementation compiles to approximately **3.1 KB** of WebAssembly binary code.
- **Cartridge Footprint**: `cart.wasm` increased from ~34.8 KB to **38.0 KB**, remaining well under WASM-4's **64 KB** ceiling with **over 26 KB of headroom remaining**.
- **Execution Overhead**: Because audio updates are event-driven and register-based rather than sample-by-sample DSP calculations, APU emulation consumes less than **0.2%** of available frame CPU time.
