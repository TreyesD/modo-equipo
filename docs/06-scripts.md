# Referencia de scripts

**Respuesta corta:** la skill trae 8 scripts. Los de Python funcionan en Windows, macOS y Linux; los de PowerShell son solo para Windows (segunda pantalla). Ninguno se conecta a internet ni instala nada.

Todas las rutas son relativas a la carpeta de la skill (`skills/modo-equipo/`). En la skill se escriben como `${CLAUDE_SKILL_DIR}/...`. `PY` significa el comando de Python que funcione: `py -3` o `python` en Windows, `python3` o `python` en macOS/Linux.

| Script | Sistema | Para qué |
|---|---|---|
| [`scripts/session_tokens.py`](#session_tokenspy) | Todos | Contar los tokens de una sesión |
| [`scripts/global_rule.py`](#global_rulepy) | Todos | Agregar, revisar o quitar la regla global en `CLAUDE.md` |
| [`scripts/gentle_blocks.py`](#gentle_blockspy) | Todos | Extraer los bloques de Gentle AI y su huella |
| [`scripts/virtual-pad/dsu_server.py`](#virtual-paddsu_serverpy) | Todos | Control de juego virtual para emuladores |
| [`scripts/second-screen/detect.ps1`](#second-screendetectps1) | Windows | ¿Hay segunda pantalla? |
| [`scripts/second-screen/launch-on-second-screen.ps1`](#second-screenlaunch-on-second-screenps1) | Windows | Abrir el corredor de pruebas en la segunda pantalla |
| [`scripts/second-screen/run-tests.ps1`](#second-screenrun-testsps1) | Windows | Detectar y ejecutar las suites de prueba |
| [`scripts/second-screen/screen-viewer.ps1`](#second-screenscreen-viewerps1) | Windows | Visor táctil de la segunda pantalla |

---

## session_tokens.py

**En simple:** lee el registro de una sesión de Claude y suma cuántos tokens usó, sin contar dos veces las respuestas repetidas.

**Contrato:**
- Uso: `PY -I scripts/session_tokens.py <ruta-al-transcript.jsonl>`
- Lee solo líneas con `"type":"assistant"`; deduplica por `message.id` (gana la última línea); ignora líneas inválidas.
- Salida (una línea JSON): `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `total`, `responses`.
- Sin argumento: termina con error de uso.

## global_rule.py

**En simple:** agrega a tu `CLAUDE.md` el bloque con las reglas de pruebas, lo actualiza o lo quita, sin tocar nada más del archivo. Solo se usa después de que dijiste que sí.

**Contrato:**
- Uso: `PY -I scripts/global_rule.py status|install|remove [--file RUTA]` (por defecto `~/.claude/CLAUDE.md`).
- El texto del bloque sale de `references/global-rule.md` (entre `<!-- modo-equipo:global-rule vN -->` y `<!-- /modo-equipo:global-rule -->`).

| Acción | Efecto | Imprime |
|---|---|---|
| `status` | Solo lee. | `missing` \| `current vN` \| `outdated vN (latest vM)` \| `broken: ...` |
| `install` | Agrega el bloque al final con una línea en blanco antes, o reemplaza una versión vieja en su lugar. Repetirlo no duplica. | El estado final (`current vN`). |
| `remove` | Quita el bloque y la línea en blanco que agregó `install`. | `missing` |

- **Garantías:** el resto del archivo queda byte a byte; respeta finales de línea CRLF o LF; escritura atómica (archivo temporal + reemplazo, nunca deja el archivo a medias); si `CLAUDE.md` es un enlace simbólico, escribe en el archivo real y conserva el enlace; conserva los permisos del archivo; crea el archivo y la carpeta si no existen.
- **Código de salida 2:** marcadores dañados (apertura sin cierre o bloques repetidos). No cambia nada; el usuario debe arreglarlo a mano.

## gentle_blocks.py

**En simple:** saca de tu `CLAUDE.md` solo las partes que administra Gentle AI, para comparar si cambiaron.

**Contrato:**
- Uso: `PY -I scripts/gentle_blocks.py <ruta-CLAUDE.md> [--hash]`
- Sin `--hash`: imprime los bloques `<!-- gentle-ai:* -->` (incluidos los anidados), en UTF-8.
- Con `--hash`: imprime el SHA-256 de ese texto (64 caracteres hexadecimales). Mismo archivo = mismo hash.

## virtual-pad/dsu_server.py

**En simple:** hace de control de juego virtual. El emulador lo recibe aunque su ventana no esté activa, así que las pruebas no usan tu teclado.

**Contrato:**
- Uso: `PY -I scripts/virtual-pad/dsu_server.py [log] [--port 26760] [--ctrl-port 26761]`
- Protocolo DSU (cemuhook, versión 1001) en `127.0.0.1:<port>`: un control en la ranura 0. Paquetes con CRC32 válido (`PortInfo` de 32 bytes, datos del control de 100 bytes).
- Comandos de texto por UDP a `127.0.0.1:<ctrl-port>`: `press <Input> <ms>`, `hold <Input>`, `release <Input>`, `stick <lx> <ly>` (0-255, centro 128), `quit`.
- Inputs: `Cross Circle Square Triangle L1 R1 L2 R2 PadN PadS PadE PadW Options Share`.
- Registra eventos en el archivo `log` (por defecto `dsu_log.txt`).
- Dos pruebas a la vez necesitan puertos distintos. Configuración del emulador: [`references/virtual-pad.md`](../skills/modo-equipo/references/virtual-pad.md).

## second-screen/detect.ps1

**En simple:** responde si Windows ve una segunda pantalla.

**Contrato:**
- Uso: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/second-screen/detect.ps1`
- Imprime un JSON: `ok`, `secondScreen` (true/false), `screenCount`, `screens` (nombre, primaria, x, y, ancho, alto). Siempre termina con código 0; leer el JSON.
- Variable de prueba: `MODO_EQUIPO_NO_SECOND_SCREEN=1` simula que no hay segunda pantalla.

## second-screen/launch-on-second-screen.ps1

**En simple:** abre la ventana de pruebas directamente en la segunda pantalla y vuelve enseguida.

**Contrato:**
- Uso: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/second-screen/launch-on-second-screen.ps1 -Root "<carpeta del proyecto>"`
- Código 0 e imprime `LAUNCHED pid=<n> screen=<nombre>`: lanzó `run-tests.ps1` en la segunda pantalla.
- Código 2 e imprime `NO_SECOND_SCREEN`: no lanzó nada; correr las pruebas de la forma normal.
- Respeta `MODO_EQUIPO_NO_SECOND_SCREEN=1`.

## second-screen/run-tests.ps1

**En simple:** busca solo las pruebas de tu proyecto, las corre una tras otra y deja el resultado en un archivo que Claude puede leer.

**Contrato:**
- Uso: `run-tests.ps1 [-Root <carpeta>] [-StateDir <carpeta>] [-NoPause]`. `StateDir` por defecto: `~/.claude/modo-equipo`. `-NoPause` evita esperar un Enter al final.
- Detección automática (hasta 2 niveles de carpetas, ignorando `node_modules`, `.git`, `.venv`, `venv`, `dist`, `build`, `downloads`, `__pycache__`):

| Encuentra | Ejecuta |
|---|---|
| `package.json` con script `test` | `npm test` (o `bun run test` si es un proyecto bun) |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test` |
| carpeta `tests/` con `test_*.py` | `python -m pytest -q tests` |
| `pytest.ini` | `python -m pytest -q` |

- Definición manual: `<proyecto>/.modo-equipo-tests.json` con `[{"name": "...", "dir": "...", "cmd": "..."}]` reemplaza la detección.
- Salidas (UTF-8 **sin BOM**): `tests-last.json` con `status` (`running` → `done`), `root`, `updated` y `suites` (cada una con `name`, `cmd`, `result` = `passed` \| `failed` \| `missing-tool`, `exitCode`); y `tests-last.log` con la salida completa.
- `missing-tool` significa que falta la herramienta (bun, pytest, go…). **No es un PASS.**

## second-screen/screen-viewer.ps1

**En simple:** la ventanita que muestra la segunda pantalla en vivo y te deja hacer clic en ella como si fuera táctil.

**Contrato:**
- Uso: `powershell -NoProfile -ExecutionPolicy Bypass -STA -File scripts/second-screen/screen-viewer.ps1`
- Clic izquierdo, derecho y central, arrastre y rueda sobre la imagen se reproducen en el punto equivalente de la segunda pantalla; el cursor vuelve a su posición. Los clics sobre las franjas negras se ignoran.
- Trabaja en píxeles reales por pantalla (Per-Monitor DPI v2), necesario con escalas distintas entre pantallas.
- `-SelfTest`: prueba la conversión de coordenadas sin abrir ventanas (código 0 = pasa).
- `MODO_EQUIPO_VIEWER_LOG=<archivo>`: registra los eventos para diagnosticar.
- Sin segunda pantalla: muestra un aviso y termina con código 1.
