# MEC-AI Launcher

Single-file Windows GUI that replaces needing a terminal.

## What it does
- **Auto-detects** the MECAI folder — **Desktop is preferred, Downloads is ignored**. It walks up from where the exe lives and scans `Desktop/MECAI` first, then other places. If you have `MECAI` both in `Downloads` and on the Desktop, the Desktop copy is always chosen (Downloads is stale from the zip). So put the folder on the Desktop and double-click.
- **Update** button runs `git pull --ff-only origin main` hidden and streams output to the Log panel (needs `git` installed; bundle releases without `.git` show a friendly message instead).
- **Start API / Start Web / Start Both** spawn `uvicorn` and `next dev` (repo) or `api/MEC-AI-API.exe` + `web/node.exe web/server.js` (bundle) with `CREATE_NO_WINDOW` — no terminal window.
- **Stop All** terminates both and also kills stale `:8000`/`:3000` listeners by PID.
- **Network** shows every LAN IPv4 (`UDP 8.8.8.8` trick + `Get-NetIPAddress` fallback) with copyable URLs: `http://<LAN_IP>:8000` for API and `http://<LAN_IP>:3000/dashboard` for the Flutter app.

## Two modes
| Folder contents | Mode | API command | Web command |
|---|---|---|---|
| `pnpm-workspace.yaml` + `services/api/pyproject.toml` + `.git` | repo/dev | `services/api/.venv/Scripts/python.exe -m uvicorn ...` (creates venv on first run) | `pnpm --dir apps/web dev` or `npm --prefix apps/web run dev` hidden |
| `api/MEC-AI-API.exe` + `web/server.js` + `web/node.exe` + `.env` | bundle (MEC-AI-Windows.zip) | `api/MEC-AI-API.exe` | `web/node.exe web/server.js` |

## Build
Double-click `build.bat` on Windows (needs `py` launcher 3.12+). Output: `dist/MECAI-Launcher.exe` and a copy at repo root. The workflow `.github/workflows/windows-package.yml` builds it automatically and puts it at the top of `MEC-AI-Windows.zip`.

```
py -3 -m pip install pyinstaller
py -3 -m PyInstaller --noconsole --onefile --name MECAI-Launcher mecai_launcher.py
```

## For the client
1. Put the whole `MECAI` folder on the **Desktop** (Downloads copy is ignored by auto-detect, so move it out of Downloads).
2. Double-click `MECAI-Launcher.exe` inside it — or click **★ Create Desktop Shortcut** in the launcher.
3. Click **Auto-detect** if needed (it will pick `Desktop/MECAI`), then **Start Both**.
4. Read the LAN URLs in the Network card, enter the API one into the Flutter app's server setting (e.g. `http://192.168.1.42:8000`).
5. **Update (git pull)** when you push a new version — no need to re-send the zip if the client has git.

No terminal window is needed; the launcher stays as the only window. Logs are in the bottom panel. If something fails, Copy log and send it back.
