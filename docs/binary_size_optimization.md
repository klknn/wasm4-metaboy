# Binary Size Optimization: Fitting a Game Boy Emulator in Under 64 KB

WASM-4 imposes a strict **64 KB** limit on cartridge binaries (`cart.wasm`). Building a full Game Boy (DMG) emulator—including a complete Sharp SM83 CPU (500+ instructions), memory banking controller (MBC1), scanline-accurate PPU, and programmable timer—typically yields binaries between 100 KB and several megabytes when using standard runtimes and naive architectures.

MetaBoy compiles down to **34,858 bytes (~34 KB)** in release mode, leaving **almost half of the 64 KB limit free**.

This document details the architectural decisions, compiler configurations, and D language features that made this possible.

---

## 1. Stripping the D Runtime with `-betterC`

The D standard runtime (`druntime`) includes:
- A tracing Garbage Collector (GC)
- Runtime reflection and `TypeInfo` tables
- Dynamic exception handling and stack unwinding
- Threading and synchronization primitives
- Module constructors and destructors

Linking `druntime` would instantly inflate the WebAssembly binary past 500 KB–1 MB.

In [`dub.json`](../dub.json), MetaBoy enables the **`-betterC`** compiler flag:
```json
"dflags": [
  "-betterC"
]
```
With `-betterC`, the D compiler emits clean, C-equivalent LLVM IR without linking any part of `druntime`. Memory is allocated statically or on the stack, and language features compile directly to raw WebAssembly instructions with zero runtime baggage.

---

## 2. LLVM WebAssembly Linker Flags (`wasm-ld`)

MetaBoy configures `wasm-ld` via `dub.json` with aggressive size-reducing flags:

```json
"lflags": [
  "--strip-all",
  "--allow-undefined",
  "--stack-first",
  "--import-memory",
  "--initial-memory=65536",
  "--max-memory=2097152",
  "--no-entry",
  "--export=start",
  "--export=update",
  "--export=getRomBuffer",
  "--export=loadRom",
  "-zstack-size=14752"
]
```

### Key Optimizations:
- **`--strip-all`**: Strips all symbol tables, DWARF debug information, and custom metadata sections.
- **`--import-memory`**: Instead of embedding a WebAssembly memory declaration and initialization table in `cart.wasm`, the module imports its linear memory directly from the WASM-4 runtime environment (`env.memory`).
- **`--no-entry` & explicit `--export`**: Disables the default CRT startup routine (`_start` / `main`) and exports only the four functions called by WASM-4 (`start`, `update`, `getRomBuffer`, `loadRom`).
- **`--stack-first` & `-zstack-size=14752`**: Places the stack in the memory region below the WASM-4 framebuffer (`0x00A0..0x1A00`), avoiding fragmentation and extra memory section overhead.

---

## 3. Opcode Factorization vs. Giant Switch Tables

A common pitfall in Game Boy emulator implementations is defining all 256 standard opcodes and 256 CB-prefix opcodes as 512 separate functions or massive, repetitive switch blocks:

```c
// ❌ Naive approach: repeating ALU logic 8 times per operation
case 0x80: a = add(a, b); break;
case 0x81: a = add(a, c); break;
case 0x82: a = add(a, d); break;
// ... hundreds of repetitive cases ...
```

This pattern generates tens of thousands of redundant WebAssembly instructions and large jump tables.

### MetaBoy's Bitfield Pattern Decoding

The Game Boy's Sharp SM83 CPU instruction set is structurally patterned on octal bitfields (Pan Docs [CPU Instruction Set](https://gbdev.io/pandocs/CPU_Instruction_Set.html)):

```
Opcode: [ 7 6 | 5 4 3 | 2 1 0 ]
        [  y  |   p   |   q   ]
```

MetaBoy leverages this pattern across [`source/gb/cpu.d`](../source/gb/cpu.d):

1. **8-bit Register Moves (`0x40..0x7F`)**:
   All 64 register-to-register `LD r, r'` instructions share a single handler:
   ```d
   case 0x40: .. case 0x7F:
       if (opcode == 0x76) { halt = true; return 4; } // HALT exception
       setReg8(mmu, (opcode >> 3) & 7, getReg8(mmu, opcode & 7));
       return (opcode & 7) == 6 || ((opcode >> 3) & 7) == 6 ? 8 : 4;
   ```

2. **ALU Operations (`0x80..0xBF` and `0xC6..0xFE`)**:
   All 8 ALU operations (`ADD`, `ADC`, `SUB`, `SBC`, `AND`, `XOR`, `OR`, `CP`) are unified in `aluOp(op, val)`. Both register-based and immediate variants route through this single helper.

3. **16-bit Register Instructions**:
   16-bit loads (`LD rr, nn`), increments (`INC rr`), decrements (`DEC rr`), additions (`ADD HL, rr`), stack pushes (`PUSH rr`), and pops (`POP rr`) all route through unified `getReg16((opcode >> 4) & 3)` and `setReg16((opcode >> 4) & 3)`.

4. **All 256 CB-Prefix Instructions in 35 Lines**:
   ```d
   case 0xCB: {
       u8 cb = fetch8(mmu);
       u8 reg = cb & 7;
       u8 bit = (cb >> 3) & 7;
       u8 group = cb >> 6;
       uint cycles = (reg == 6) ? 16 : 8;

       if (group == 1) { // BIT b, r
           flagZ = (getReg8(mmu, reg) & (1 << bit)) == 0;
           flagN = false; flagH = true;
           return (reg == 6) ? 12 : 8;
       } else if (group == 2) { // RES b, r
           setReg8(mmu, reg, cast(u8)(getReg8(mmu, reg) & ~(1 << bit)));
           return cycles;
       } else if (group == 3) { // SET b, r
           setReg8(mmu, reg, cast(u8)(getReg8(mmu, reg) | (1 << bit)));
           return cycles;
       } else { // Rotates & Shifts (group 0)
           ...
       }
   }
   ```
   This compact factorization shrinks the CB table from ~15 KB of machine code to under 1 KB.

---

## 4. Zero-Cost Compile-Time Metaprogramming (`std.bitmanip.bitfields`)

Game Boy hardware relies heavily on bit-packed registers:
- CPU Flag register `F` (bits for `Z`, `N`, `H`, `C`)
- Timer `TAC` (clock select, timer enable)
- PPU `LCDC` (8 independent display control bits)
- PPU `STAT` (mode bits, coincidence flag, interrupt enables)
- OAM Sprite Attributes (palette, flip flags, priority)

Instead of hand-writing getter/setter functions (which add call overhead and code bloat) or scattered manual bitmasks (`val & 0x04`), MetaBoy uses D's `std.bitmanip.bitfields`:

```d
union {
    u8 lcdc = 0x91;
    mixin(bitfields!(
        bool, "bgEnable",         1,
        bool, "objEnable",        1,
        bool, "objSize16",        1,
        bool, "bgTilemapHigh",    1,
        bool, "tileDataUnsigned", 1,
        bool, "winEnable",        1,
        bool, "winTilemapHigh",   1,
        bool, "lcdEnable",        1
    ));
}
```

### Why It's Zero-Cost:
- `bitfields` executes entirely during compilation.
- LLVM inlines the bit operations directly into call sites and merges adjacent bit tests into single bitmask operations.
- Generates **zero heap allocations**, **zero runtime metadata**, and **zero function call overhead**.

---

## 5. Linear Memory Partitioning (ROMs Are Not Baked into the WASM Binary)

Commercial Game Boy ROMs range from 64 KB (Super Mario Land) to 512 KB (Pokémon Red) or more. Baking a commercial ROM into `cart.wasm` would immediately exceed the 64 KB limit.

MetaBoy solves this by partitioning WebAssembly linear memory:

```
0x00000 ┌──────────────────────────────────────────────┐
        │ WASM-4 System (I/O, Framebuffer, Stack)     │ (64 KB)
0x10000 ├──────────────────────────────────────────────┤
        │ Game Boy ROM Buffer (Dynamically Loaded)     │ (up to 512 KB)
0x90000 ├──────────────────────────────────────────────┤
        │ Game Boy Cartridge SRAM (Save Data)          │ (32 KB, 4 banks)
0x98000 └──────────────────────────────────────────────┘
```

- In `cart.wasm`, the MMU simply reads from `const(u8)* romData = cast(const(u8)*)0x10000`.
- The bundled HTML loader (`scripts/patch_html.py`) fetches or accepts dropped `.gb` files and writes them directly into the WebAssembly instance's linear memory.
- `cart.wasm` only embeds a tiny 786-byte homebrew debug ROM (`DEBUG_ROM`) for out-of-the-box standalone play.

---

## 6. Direct 2bpp Framebuffer Blitting

Standard Game Boy emulators typically render to an internal 32-bit RGBA buffer:
- $160 \times 144 \times 4 \text{ bytes} \approx 92 \text{ KB}$ of extra RAM.
- Requires color conversion loops (`RGB -> palette index -> WASM-4 2bpp`).

MetaBoy renders directly into WASM-4's native 2bpp framebuffer:
```d
ubyte* fb = w4.framebuffer + (line * 40);
for (int col = 0; col < 40; col++) {
    int p = col * 4;
    fb[col] = cast(ubyte)(
        (scanlineColors[p]     & 3)      |
        ((scanlineColors[p + 1] & 3) << 2) |
        ((scanlineColors[p + 2] & 3) << 4) |
        ((scanlineColors[p + 3] & 3) << 6)
    );
}
```
- **0 bytes** of intermediate image buffers.
- Eliminates color conversion math and redundant copying passes.
- Runs at a full 60 FPS while keeping binary size minimal.

---

## Summary of Size Optimizations

| Technique | Typical Naive Approach | MetaBoy Implementation | Approximate Savings |
|---|---|---|---|
| **Runtime** | Standard `druntime` / `libc` | `-betterC` (pure LLVM IR) | ~300–800 KB |
| **Linker** | Default WASM build | `--strip-all`, `--import-memory`, `--no-entry` | ~40–80 KB |
| **CPU Dispatch** | 512 separate functions / switch branches | Octal bitfield factorization | ~30–50 KB |
| **CB Prefix** | 256 individual handlers | 3-way bitgroup decoder (35 lines) | ~15 KB |
| **Register Access** | Getter/setter boilerplate | `std.bitmanip.bitfields` (inlined) | ~5–10 KB |
| **ROM Storage** | Embedded `.gb` binary | Dynamic linear memory placement | 64 KB – 512 KB |
| **Framebuffer** | 32-bit RGBA intermediary | Direct 2bpp blitter | ~8 KB code + 92 KB RAM |
| **Final Binary Size** | **> 500 KB** | **34.8 KB** | **< 64 KB WASM-4 Cartridge** |
