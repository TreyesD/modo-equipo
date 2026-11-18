# Referencia de scripts

**Respuesta corta:** la skill trae 12 scripts. Los de Python funcionan en Windows, macOS y Linux, salvo `launch_offscreen.py`; los de segunda pantalla son solo para Windows. Ninguno se conecta a internet ni instala nada.

Todas las rutas son relativas a la carpeta de la skill (`skills/modo-equipo/`). En la skill se escriben como `${CLAUDE_SKILL_DIR}/...`. `PY` significa el comando de Python que funcione: `py -3` o `python` en Windows, `python3` o `python` en macOS/Linux.

| Script | Sistema | Para qué |
|---|---|---|
| [`scripts/session_tokens.py`](#session_tokenspy) | Todos | Contar los tokens de una sesión |
| [`scripts/global_rule.py`](#global_rulepy) | Todos | Agregar, revisar o quitar la regla global en `CLAUDE.md` |
| [`scripts/gentle_blocks.py`](#gentle_blockspy) | Todos | Extraer los bloques de Gentle AI y su huella |
| [`scripts/virtual-pad/dsu_server.py`](#virtual-paddsu_serverpy) | Todos | Control de juego virtual para emuladores |
| [`scripts/second-screen/detect.ps1`](#second-screendetectps1) | Windows | ¿Hay segunda pantalla? |
| [`scripts/second-screen/launch-on-second-screen.ps1`](#second-screenlaunch-on-second-screenps1) | Windows | Abrir el corredor de pruebas en la segunda pantalla |
| [`scripts/second-screen/launch_offscreen.py`](#second-screenlaunch_offscreenpy) | Windows | Abrir cualquier programa directo en la segunda pantalla, sin destello en la principal |
| [`scripts/second-screen/run-tests.ps1`](#second-screenrun-testsps1) | Windows | Detectar y ejecutar las suites de prueba |
| [`scripts/second-screen/screen-viewer.ps1`](#second-screenscreen-viewerps1) | Windows | Visor táctil de la segunda pantalla |
| [`scripts/second-screen/open-viewer.ps1`](#second-screenopen-viewerps1) | Windows | Crear la pantalla virtual si falta y abrir el visor |
| [`scripts/second-screen/parsec-vdd.ps1`](#second-screenparsec-vddps1) | Windows | Guardián de pantalla: pantalla virtual sin la app ParsecVDisplay y mouse en tu pantalla |
| [`scripts/second-screen/install-desktop-shortcut.ps1`](#second-screenopen-viewerps1) | Windows | Acceso directo en el Escritorio para el visor |

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

**En simple:** responde si Windows ve una segunda pantalla; antes le pide al guardián la pantalla de esta sesión (si el driver de Parsec está instalado).

**Contrato:**
- Uso: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/second-screen/detect.ps1 [-Ensure [-ScreenId <id>]]`: por defecto solo mira y nunca agrega un monitor (agregar o quitar uno hace que Windows reconstruya las pantallas y puede hacer parpadear todas); con `-Ensure` pide al guardián la pantalla de la sesión (sin `-ScreenId` usa `MODO_EQUIPO_SCREEN_ID`, si no la sesión de Claude Code (`cc-` + 8 caracteres de `CLAUDE_CODE_SESSION_ID`), si no `default`).
- Imprime un JSON: `ok`, `secondScreen` (true/false), `screenCount`, `screens` (nombre, primaria, x, y, ancho, alto), `keeper` (lo que respondió `parsec-vdd.ps1 -Ensure`, o null si no se pidió), `screenId` y `screen` (la pantalla de esta sesión; con `-NoEnsure`, la primera segunda pantalla). Siempre termina con código 0; leer el JSON.
- `-NoEnsure`: se acepta y significa lo mismo que el valor por defecto.
- Variable de prueba: `MODO_EQUIPO_NO_SECOND_SCREEN=1` simula que no hay segunda pantalla.

## second-screen/launch-on-second-screen.ps1

**En simple:** abre la ventana de pruebas directamente en la segunda pantalla y vuelve enseguida.

**Contrato:**
- Uso: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/second-screen/launch-on-second-screen.ps1 -Root "<carpeta del proyecto>" [-ScreenId <id>]`
- Código 0 e imprime `LAUNCHED pid=<n> screen=<nombre>`: lanzó `run-tests.ps1` en la pantalla de esta sesión.
- Pide al guardián (`parsec-vdd.ps1 -Ensure`) la pantalla de la sesión (`-ScreenId`, si no `MODO_EQUIPO_SCREEN_ID`, si no la sesión de Claude Code, si no `default`; una sesión nueva recibe un monitor virtual nuevo) y registra al corredor como proceso que la mantiene: la pantalla sigue hasta que terminan las pruebas (más el tiempo de espera del guardián). Sin guardián usa la primera segunda pantalla.
- Código 2 e imprime `NO_SECOND_SCREEN`: no hubo pantalla ni guardián que la diera; no lanzó nada; correr las pruebas de la forma normal.
- Respeta `MODO_EQUIPO_NO_SECOND_SCREEN=1`.

## second-screen/launch_offscreen.py

**En simple:** abre cualquier programa con ventana (emulador, juego, app de escritorio) directo en la segunda pantalla. Ninguna de sus ventanas se ve en tu pantalla principal, ni por un instante. Es la forma por defecto de abrir un programa de prueba con ventana en Windows.

**Contrato:**
- Uso: `PY -I scripts/second-screen/launch_offscreen.py [--screen N|auto] [--timeout S] [--keep-watch S] [--trace] [--no-ensure] [--screen-id ID] -- <exe> [args...]`. Todo lo que va después de `--` es el comando, tal cual.
- Con `--screen auto` pide al guardián (`parsec-vdd.ps1 -Ensure`, sin ventana de consola) la pantalla de esta sesión (`--screen-id`, si no `MODO_EQUIPO_SCREEN_ID`, si no la sesión de Claude Code, si no `default`), pone el programa ahí y lo registra como proceso que la mantiene. `--no-ensure` lo evita y usa la primera segunda pantalla; `MODO_EQUIPO_NO_SECOND_SCREEN=1` también.
- `--list`: imprime las pantallas (`index`, `name`, `primary`, `rect`, `work`) para elegir `--screen N` (debe ser una no primaria). `auto` (por defecto) usa la primera no primaria.
- `--timeout` (15 s): espera máxima a la primera ventana. `--keep-watch` (10 s): sigue vigilando ventanas nuevas (diálogos, ventanas de procesos hijos) ese tiempo después de la primera. `--trace`: agrega cada evento de ventana observado.
- Método: crea el proceso suspendido y minimizado sin activar (`CREATE_SUSPENDED`, `SW_SHOWMINNOACTIVE`), engancha un `SetWinEventHook` fuera de proceso antes de reanudarlo y, en la primera aparición, fija la posición restaurada en la segunda pantalla (`SetWindowPlacement`, `SW_SHOWNOACTIVATE`). Guardia: cualquier ventana visible que toque la principal se vuelve transparente, se mueve y vuelve a ser opaca. Trabaja en píxeles reales (DPI por monitor). Sigue también a los procesos hijos.
- No envía teclas ni clics, no toma el foco, no inyecta código ni cambia la configuración de pantallas. No espera a que el programa termine.
- Salida: una línea JSON con `ok`, `pid`, `pids`, `screen`, `windows` (cada una con `how` = `restored` \| `moved` \| `already-off-primary`), `guardHits`, `openWindows`, `onPrimaryAtEnd`, `timedOut`, `exited`.

| Código | Significado |
|---|---|
| 0 | Lanzado y en la segunda pantalla |
| 1 | No se pudo lanzar (`error`, `winerror`) |
| 2 | Error de uso |
| 3 | No es Windows: `{"ok":false,"reason":"windows-only"}`. En macOS/Linux, correr headless o de la forma normal |
| 4 | No hay segunda pantalla: lo abrió de la forma normal |
| 5 | Una ventana quedó en la pantalla principal al final: detener esa prueba y arreglarla |

- Límites: mientras arranca minimizado aparece un botón en la barra de tareas unos 0,3 s. Apps que restauran su propia geometría guardada pueden necesitar un ajuste propio antes de lanzar (por ejemplo, la geometría de ventana en `Qt.ini` de Dolphin). Apps que delegan en otro proceso que no es hijo (apps empaquetadas, instancia única ya abierta) no se siguen. Un `moved` en `guardHits` significa que la ventana pudo verse un instante: tratarlo como fallo de la regla.

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
- Modo directo: al pasar el mouse sobre la imagen, el cursor real salta a la segunda pantalla y se mueve escalado (sigue a tu mano 1:1 sobre la imagen). Clic, doble clic, arrastre y rueda son input nativo. El cursor lo mueve un hilo propio cada 1 ms, así no se pierde movimiento de la mano y se siente igual de rápido y suave que el mouse normal. Al pasar el borde de la imagen, el cursor vuelve a tu pantalla principal; con un botón apretado el arrastre continúa y no se escapa. Funciona en cualquier borde, también en los bordes exteriores del escritorio, donde Windows frena el cursor: el visor lee el movimiento crudo del mouse (Raw Input) y sale cuando sigues empujando hacia afuera.
- Salida de emergencia: `Ctrl+Alt+Q` saca el cursor del modo directo desde cualquier lugar. Si otra app ya usa esa combinación, el visor lo avisa en su barra y queda solo la salida por los bordes.
- Imagen: la dibuja `screen-gpu.ps1` en la GPU. Duplicación de escritorio (DXGI) a una textura y dos pasadas Lanczos3 de Direct3D 11 (horizontal y vertical, el puntero real encima), sin devolver píxeles a la CPU; se dibuja solo cuando la pantalla cambia o se mueve el puntero (hasta 60 cuadros por segundo). Medido a 0,4x sobre una imagen de texto, contra una referencia Lanczos3: SSIM 0,994 en la GPU, 0,789 con la API de Magnification (idéntica al vecino más cercano de GDI), 0,944 con HALFTONE de GDI y 0,964 con bilineal de GDI+. Si no arranca (sin GPU, pantalla no duplicable, `MODO_EQUIPO_NO_GPU=1`), vuelve a la API de Magnification (cursor real) y de ahí a la copia GDI (20 / 8 cuadros por segundo, punto rojo); el título de la ventana lo dice con `[basic scaling]` y el registro da la razón.
- Ventana sin barra de título: franja superior para mover, bordes para cambiar el tamaño, y una barra flotante con siempre encima (solo en ventana pequeña), puntero, silenciar (interruptor; mientras está encendido, cada segundo silencia las sesiones de audio, en todas las salidas activas, de los procesos con el mismo nombre que las ventanas de la segunda pantalla, sin tocar procesos del sistema; al apagarlo o cerrar el visor les devuelve el sonido; si no puede, lo explica en la barra), candado del mouse, pantalla completa, mantener abierta, minimizar y cerrar.
- La barra es una ventana con transparencia por píxel (`UpdateLayeredWindow`): bordes redondeados y sombra suavizados también en Windows 10, fondo oscuro translúcido, iconos de Segoe Fluent Icons (o Segoe MDL2 Assets si no está) con explicación al pasar el mouse, y el color de acento de Windows en los botones encendidos (azul si el acento es gris). Va en el centro del borde superior de la ventana (o de la pantalla, en pantalla completa), descansa como una rayita, se abre al acercar el mouse y se pliega 0,6 s después de alejarlo. Se desliza por el borde arrastrando su agarre. Nunca toma el foco.
- Trabaja en píxeles reales por pantalla (Per-Monitor DPI v2), necesario con escalas distintas entre pantallas.
- `-SelfTest`: prueba la conversión de coordenadas, el encuadre de la imagen, la ubicación de la barra y el área del candado del mouse sin abrir ventanas (código 0 = pasa).
- `-Smoke [-SmokeSeconds N] [-SmokeOn <pantalla>]`: abre el visor unos segundos en la segunda pantalla (o en la pantalla indicada, por ejemplo `\\.\DISPLAY6`, útil para capturas cuando otra ventana tapa la segunda), sin modo directo; a la mitad abre la barra e imprime qué motor de imagen usó y dónde quedó la barra (chequeo de desarrollo).
- `MODO_EQUIPO_VIEWER_LOG=<archivo>`: registra los eventos para diagnosticar.
- Sin segunda pantalla: muestra un aviso y termina con código 1.
- Mouse en la pantalla principal: lo confina el guardián (`parsec-vdd.ps1`). El visor toma el mutex `Local\ModoEquipo.CursorFree` en modo directo para que el guardián suelte el cursor, y el botón del candado escribe o borra `~/.claude/modo-equipo/screen-keeper-v2/lock-off`.

## second-screen/open-viewer.ps1

**En simple:** un clic que deja todo listo: pide la segunda pantalla al guardián (en silencio, sin abrir la app ParsecVDisplay) y abre el visor.

**Contrato:**
- Uso: `powershell -NoProfile -ExecutionPolicy Bypass -STA -File scripts/second-screen/open-viewer.ps1`. Lo normal es usarlo desde el acceso directo (`install-desktop-shortcut.ps1`).
- Llama a `parsec-vdd.ps1 -Ensure -HolderPid <su pid>` para la sesión `-ScreenId <id>` (si no `MODO_EQUIPO_SCREEN_ID`, si no la sesión de Claude Code; desde el acceso directo, sin ningún nombre, cada apertura crea una pantalla virtual NUEVA, sesión `viewer-<pid>`, para que las pruebas de las sesiones del equipo, que usan su propia pantalla, nunca caigan en la que estás usando; `-NewScreen` lo fuerza) y abre el visor en esa pantalla: el guardián agrega la pantalla si falta (y activa el candado del mouse si es virtual). El visor queda registrado como proceso que la mantiene: la pantalla sigue mientras está abierto y, al cerrarlo, durante el tiempo de espera del guardián (10 min), por si hay pruebas que la usan.
- `-Smoke`: chequeo de desarrollo. Hace el mismo `-Ensure`, imprime su respuesta y abre el visor en su modo `-Smoke` unos segundos.
- Plan de respaldo, solo si el guardián no puede dar una pantalla (no instalado, sin acceso o sin respuesta): localiza `ParsecVDisplay.exe` (variable `PARSECVDISPLAY_EXE`, archivo `~/.claude/modo-equipo/parsecvdisplay-path.txt`, proceso en ejecución o carpetas habituales), pulsa el botón por UI Automation (sin mover el mouse) y espera hasta 20 s a que Windows reporte la pantalla.
- Si el driver falla y no encuentra `ParsecVDisplay.exe`, muestra el motivo del fallo del driver, indica la guía de instalación (`references/second-screen.md`, opción B) y pregunta al dueño: elegir el .exe con un selector de archivos (la ruta queda guardada), abrir el visor igual o no hacer nada. Nunca busca en el disco ni descarga.
- Si algo falla muestra un mensaje de error; nunca falla en silencio.
- No descarga ni instala nada: solo usa el driver o el ParsecVDisplay que el usuario ya tiene, y solo cuando el usuario hace clic.

## second-screen/parsec-vdd.ps1

**En simple:** el control remoto del driver de pantalla virtual de Parsec, y el "guardián de pantalla": un proceso oculto que le da a cada sesión de pruebas su propio monitor virtual mientras lo necesite (el visor, el corredor de pruebas, un emulador) y mantiene tu mouse en tu pantalla mientras exista alguno.

**Contrato:**
- `-Ensure [-ScreenId <id>] [-HolderPid <pid>,...] [-IdleMinutes N] [-TimeoutSeconds S]`: asegura la pantalla de la sesión `<id>` (si no se da, `MODO_EQUIPO_SCREEN_ID`; si tampoco, la sesión de Claude Code (`cc-` + 8 caracteres de `CLAUDE_CODE_SESSION_ID`), así cada sesión de Claude tiene su pantalla sin configurar nada; si tampoco, `default`; letras, números, `.`, `_` y `-`, hasta 40). Arranca el guardián (o usa el que ya corre); una sesión nueva recibe un monitor virtual nuevo y una conocida recibe el mismo de antes. Espera a que Windows lo reporte e imprime una línea JSON (`ok`, `secondScreen`, `keeper` = `started` \| `running` \| `not-needed` \| `no-driver` \| `none`, `id`, `screen`, `x`, `y`, `width`, `height`, `shared`, `error`). Código 0 = la sesión tiene pantalla; 1 = no se pudo (sin driver y sin segunda pantalla, o las 8 pantallas en uso). Los `HolderPid` mantienen viva la pantalla de esa sesión mientras corren; cuando termina el último (o si no se dio ninguno), la sesión dura `IdleMinutes` más (10 por defecto) y su pantalla queda libre como repuesto: NO se quita (agregar o quitar un monitor hace que Windows reconstruya las pantallas y puede hacer parpadear todas); la toma la próxima sesión nueva y solo se quita tras `-SpareMinutes` sin uso (720 = 12 h), con `-Release` o al cerrar el guardián. El guardián se cierra cuando no queda ninguna sesión ni repuesto.
- La sesión `default` usa primero una segunda pantalla que ya exista (un monitor real, o una virtual de otro programa) y nunca la quita; con un monitor real y sin pantalla virtual no arranca nada (`not-needed`). Las demás sesiones siempre reciben un monitor propio. Sin driver todas comparten la segunda pantalla que haya (`shared: true`). Un guardián viejo (de antes de las sesiones, de una sola pantalla) puede seguir vivo con su pantalla: no se comparte con las sesiones nuevas (el guardián nuevo tiene su propia carpeta `screen-keeper-v2` y su propio mutex) y se cierra solo.
- `-Release -ScreenId <id>`: quita ya la pantalla de esa sesión. `-Release` solo: detiene el guardián (quita todas sus pantallas y libera el mouse). `-Status`: JSON con el estado (versión, sesiones con su pantalla, posición y procesos que la mantienen, errores, área del candado, candado encendido, pantallas).
- Guardián: un solo proceso (mutex `Local\ModoEquipo.ScreenKeeper-v2`), sin ventana, con registro en `~/.claude/modo-equipo/screen-keeper-v2/keeper.log` y las peticiones de cada sesión en `screen-keeper-v2/sessions/<id>.txt`. Hasta 8 pantallas virtuales propias (`VDD_MAX_DISPLAYS` de `parsec-vdd.h`). Si la pantalla de una sesión desaparece mientras corre, le pone otra. Al cerrarse quita solo las pantallas que agregó.
- Si el guardián muere de golpe y otro programa mantiene vivas sus pantallas (la app ParsecVDisplay da señal de vida a todas), el siguiente guardián las encuentra en `screen-keeper-v2/owned.json`: devuelve a cada sesión su pantalla de antes y quita a los 15 s las que nadie reclama.
- `MODO_EQUIPO_KEEPER_TAG=<nombre>`: un guardián aparte (otra carpeta de estado y otros nombres), para probar una copia de desarrollo junto al que usan las sesiones.
- Candado del mouse: mientras haya una pantalla virtual (adaptador Parsec u otro "Virtual Display"), confina el cursor con `ClipCursor` al rectángulo de las pantallas reales. Lo libera al instante mientras haya un botón apretado (revisa cada 10 ms; así puedes arrastrar una ventana hacia allá) y mientras el visor tenga el mutex `Local\ModoEquipo.CursorFree` (su modo directo; si el visor muere con él, el guardián lo recupera). Solo lo vuelve a aplicar si nadie más tiene el cursor confinado (no pelea con juegos). No lo aplica si una pantalla virtual queda entre pantallas reales. El archivo `screen-keeper-v2/lock-off` lo apaga (lo escribe el botón del candado del visor).
- El confinamiento sobrevive al proceso que lo puso (comprobado en Windows 10), así que el guardián deja un proceso vigía oculto que lo libera si el guardián muere.
- Se carga con `. .\parsec-vdd.ps1` y define `[ModoEquipo.ParsecVdd]`: `Open()`, `AddDisplay()` (devuelve el índice), `RemoveDisplay(i)`, `Version()`, `MonitorCount()` y `Dispose()` (quita las pantallas que agregó ese objeto, detiene la señal de vida y cierra el driver).
- Busca la interfaz del driver con SetupAPI (GUID `{00b41627-04c4-429e-a26e-0265cf50c8fa}`) y le envía los IOCTL de `parsec-vdd.h` del proyecto nomi-san/parsec-vdd (licencia BSD de 2 cláusulas, ver `NOTICE`). Envía la señal de vida cada 50 ms (el driver la pide al menos cada 100 ms). No necesita administrador.
- Driver caído: si el dispositivo `ROOT\DISPLAY 0` existe pero su interfaz no (el host del driver se cayó; evento 10111 de Windows), `-Ensure` responde `driverOffline: true` con el remedio (`pnputil /restart-device ROOT\DISPLAY 0` en una consola de administrador, o reiniciar) y `open-viewer.ps1` lo muestra sin abrir ParsecVDisplay, que se cuelga contra un driver caído. Medido: 20 ciclos de agregar/quitar una pantalla seguidos tardaron ~3 s cada uno y sin fallos; un ciclo después (a los 21-30) el host del driver se cayó (violación de acceso en `iddcx.dll`) y no volvió solo en 3 horas. Por eso `tests/manual/keeper-stress.ps1` ahora hace 10 ciclos por defecto, espera 1 s entre ciclos y se detiene si la interfaz desaparece. El guardián nunca hace ciclos así: deja las pantallas libres como repuesto.
- `-SelfTest`: comprueba los códigos IOCTL contra `CTL_CODE`, el formato del índice, el intervalo de la señal, el área del candado (también con varias pantallas virtuales), los procesos que la mantienen, la parada por inactividad, los nombres de sesión y qué pantalla recibe cada sesión; si el driver está, informa su versión. Nunca agrega pantallas (código 0 = pasa).

## second-screen/install-desktop-shortcut.ps1

**En simple:** crea el icono "Visor segunda pantalla" en el Escritorio.

**Contrato:**
- Ejecutarlo a mano, una vez. Copia `open-viewer.ps1`, `screen-viewer.ps1` y `parsec-vdd.ps1` a `~/.claude/modo-equipo/viewer/` para que el acceso directo siga funcionando tras actualizar el plugin; volver a ejecutarlo actualiza esas copias.
