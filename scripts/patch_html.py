#!/usr/bin/env python3
"""
Post-process the bundled WASM-4 index.html to:
1. Expand WebAssembly.Memory to 32 pages (2MB) so Game Boy ROMs up to 1MB + 32KB cart RAM fit.
2. Add drag-and-drop and auto-fetch support for .gb ROMs (such as pokemon_red.gb).
"""
import sys

def patch(html_path):
    with open(html_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Expand WebAssembly memory from 1 page to 32 pages
    old_mem = 'this.memory=new WebAssembly.Memory({initial:1,maximum:1})'
    new_mem = 'this.memory=new WebAssembly.Memory({initial:32,maximum:32})'
    if old_mem in content:
        content = content.replace(old_mem, new_mem, 1)

    # 2. Add ROM loader & drag-and-drop hook if not already added
    if 'loadRomData' not in content:
        hook = '''<div id="rom-bar" style="position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:99999;font-family:monospace;">
    <input type="file" id="rom-picker" accept=".gb" style="display:none">
    <button id="rom-btn" onclick="document.getElementById('rom-picker').click()" style="background:#1a1a24;color:#a0e0a0;border:2px solid #336644;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:bold;box-shadow:0 4px 10px rgba(0,0,0,0.5);">
        📁 Load ROM (.gb) / Drag & Drop
    </button>
</div>
<script>
window.addEventListener('DOMContentLoaded', () => {
    setTimeout(async () => {
        const app = document.querySelector('wasm4-app');
        if (!app || !app.runtime) return;

        async function loadRomData(buffer, filename) {
            const romBytes = new Uint8Array(buffer);
            console.log('Loading ROM:', filename, 'size:', romBytes.length);
            const wasmMem = new Uint8Array(app.runtime.memory.buffer);
            wasmMem.set(romBytes, 0x10000);
            if (app.runtime.wasm && app.runtime.wasm.exports.loadRom) {
                app.runtime.wasm.exports.loadRom(romBytes.length);
                if (app.notifications) {
                    app.notifications.show('Loaded ' + (filename || 'ROM'));
                }
                const btn = document.getElementById('rom-btn');
                if (btn) btn.innerText = '🎮 Playing: ' + (filename || 'ROM');
            }
        }

        // File picker change event
        const picker = document.getElementById('rom-picker');
        if (picker) {
            picker.addEventListener('change', async (e) => {
                if (picker.files && picker.files.length > 0) {
                    const file = picker.files[0];
                    const buf = await file.arrayBuffer();
                    await loadRomData(buf, file.name);
                }
            });
        }

        // Auto-fetch pokemon_red.gb if served locally
        try {
            const res = await fetch('pokemon_red.gb');
            if (res.ok) {
                const buf = await res.arrayBuffer();
                await loadRomData(buf, 'pokemon_red.gb');
            }
        } catch(e) {
            // pokemon_red.gb not hosted, keep default ROM
        }

        // Drag-and-drop any .gb file onto the page
        window.addEventListener('dragover', (e) => e.preventDefault());
        window.addEventListener('drop', async (e) => {
            e.preventDefault();
            if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
                const file = e.dataTransfer.files[0];
                const buf = await file.arrayBuffer();
                await loadRomData(buf, file.name);
            }
        });
    }, 300);
});
</script>
</body>'''
        content = content.replace('</body>', hook, 1)

    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"✔ Patched {html_path} for extended Game Boy ROM support")

if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else 'index.html'
    patch(target)
