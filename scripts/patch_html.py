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
        hook = '''<div id="rom-bar" style="position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:99999;font-family:monospace;display:flex;gap:8px;align-items:center;">
    <input type="file" id="rom-picker" accept=".gb" style="display:none">
    <button id="rom-btn" onclick="document.getElementById('rom-picker').click()" style="background:#1a1a24;color:#a0e0a0;border:2px solid #336644;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:bold;box-shadow:0 4px 10px rgba(0,0,0,0.5);">
        📁 Load ROM / Drop
    </button>
    <button id="flappy-btn" onclick="window.loadPresetRom('flappyboy')" style="background:#1a1a24;color:#f0c040;border:2px solid #886622;padding:6px 12px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:bold;box-shadow:0 4px 10px rgba(0,0,0,0.5);">
        🐦 Play FlappyBoy
    </button>
    <button id="tobu-btn" onclick="window.loadPresetRom('tobutobugirl')" style="background:#1a1a24;color:#60c0f0;border:2px solid #226688;padding:6px 12px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:bold;box-shadow:0 4px 10px rgba(0,0,0,0.5);">
        🐱 Play Tobu Tobu Girl
    </button>
</div>
<script>
window.addEventListener('DOMContentLoaded', () => {
    setTimeout(async () => {
        const app = document.querySelector('wasm4-app');
        if (!app || !app.runtime) return;

        const ONLINE_ROMS = {
            'flappyboy': 'https://raw.githubusercontent.com/bitnenfer/flappy-boy-asm/master/build/flappyboy.gb',
            'flappy': 'https://raw.githubusercontent.com/bitnenfer/flappy-boy-asm/master/build/flappyboy.gb',
            'tobutobugirl': 'https://raw.githubusercontent.com/torch2424/wasmboy/master/demo/wasmerboy/tobutobugirl/tobutobugirl.gb',
            'tobu': 'https://raw.githubusercontent.com/torch2424/wasmboy/master/demo/wasmerboy/tobutobugirl/tobutobugirl.gb'
        };

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
                if (btn) btn.innerText = '🎮 ' + (filename || 'ROM');
            }
        }

        async function fetchAndLoad(url, name) {
            const resolvedUrl = ONLINE_ROMS[url.toLowerCase()] || url;
            const displayName = name || resolvedUrl.split('/').pop();
            const btn = document.getElementById('rom-btn');
            if (btn) btn.innerText = '⏳ Loading ' + displayName + '...';
            try {
                const res = await fetch(resolvedUrl);
                if (!res.ok) throw new Error('HTTP ' + res.status);
                const buf = await res.arrayBuffer();
                await loadRomData(buf, displayName);
            } catch(err) {
                console.error('Failed to load ROM from', resolvedUrl, err);
                if (btn) btn.innerText = '⚠️ Failed to load ROM';
            }
        }
        window.loadPresetRom = (preset) => fetchAndLoad(preset, preset + '.gb');

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

        // Auto-fetch ROM: URL query ?rom=..., or default to FlappyBoy
        const urlParams = new URLSearchParams(window.location.search);
        const queryRom = urlParams.get('rom');
        if (queryRom && queryRom !== 'debug' && queryRom !== 'none') {
            await fetchAndLoad(queryRom, queryRom.split('/').pop());
        } else if (!queryRom) {
            // Load FlappyBoy by default
            await fetchAndLoad('flappyboy', 'FlappyBoy');
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
