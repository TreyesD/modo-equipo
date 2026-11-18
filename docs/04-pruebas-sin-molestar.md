# Pruebas que no usan tu pantalla, tu mouse ni tu teclado

**Respuesta corta:** las pruebas nunca deben mover tu cursor, escribir con tu teclado ni quitarte la ventana activa. Para eso la skill elige, según la prueba, un método que no toca tus dispositivos; manda a una segunda pantalla lo que abriría ventanas, y te da un visor para mirar y tocar esa pantalla desde la principal.

## En simple

Sin esto, Claude a veces te pide "no muevas el mouse" mientras prueba algo, y tienes que dejar de trabajar. La skill lo evita en cuatro capas:

| Capa | Qué resuelve |
|---|---|
| 1. Método de entrada correcto | La prueba maneja la app "por dentro" en vez de usar tu mouse y teclado. |
| 2. Segunda pantalla | Las ventanas que abre la prueba van a otra pantalla (real o virtual), no a la tuya. |
| 3. Visor táctil | Ves esa segunda pantalla en una ventanita y puedes hacer clic en ella como si fuera táctil. |
| 4. Regla en todas las sesiones | Si quieres, todo esto aplica también fuera del modo equipo. |

### 1. Método de entrada según la prueba

| La prueba maneja… | Se usa | En vez de |
|---|---|---|
| Código, comandos, APIs | El propio corredor de tests | — |
| Páginas web | Playwright o el navegador integrado de Claude | Hacer clic en tu navegador |
| Apps normales de Windows | UI Automation (manejar los botones "por dentro") | Mover tu cursor |
| Emuladores o juegos | Un **control virtual** que el juego recibe aunque su ventana no esté activa | Tu teclado + quitarte el foco |
| Algo que solo funciona con un cursor de verdad | Un **cursor aislado** (ver más abajo) | Tu cursor |

Si nada de eso sirve, Claude tiene que avisarte antes, decirte cuánto va a tardar y esperar tu OK.

### 2. Segunda pantalla (Windows)

- Sirve un monitor físico o uno **virtual**. Para crear uno virtual hay una guía paso a paso: [`references/second-screen.md`](../skills/modo-equipo/references/second-screen.md). **Las descargas e instalaciones las haces tú; la skill nunca instala nada sola.**
- Solo se mueve a la segunda pantalla **lo que molestaría**: ventanas de pruebas, emuladores, apps. Lo que no molesta (pruebas sin ventana, el navegador integrado) corre donde sea.
- Si no hay segunda pantalla, las pruebas corren normal y la skill te pregunta **una vez** si quieres la guía (sí / no / no preguntar más).

### 3. Visor táctil

`scripts/second-screen/screen-viewer.ps1` abre una ventanita en tu pantalla principal que muestra la segunda en vivo.

- **Clic, clic derecho, arrastrar y rueda** sobre la imagen ocurren en el mismo punto de la segunda pantalla. Tu cursor salta allí unas milésimas de segundo y vuelve solo: verás un parpadeo mínimo (Windows tiene un solo cursor).
- **Doble clic** funciona: dos clics seguidos llegan como doble clic.
- **Teclado**: al hacer clic en una ventana de la segunda pantalla, esa ventana queda activa y lo que escribes va a ella. Para volver, haz clic en tu pantalla.
- **Para salir**: empuja el mouse más allá de cualquier borde de la imagen, o aprieta **Ctrl+Alt+Q**.
- **El mouse no se escapa a la pantalla virtual**: mientras exista la pantalla virtual (con o sin el visor abierto), tu cursor se queda en tu pantalla aunque lo lleves al borde. Solo cruza si mantienes un botón apretado (por ejemplo, para arrastrar una ventana hacia allá) o a través de la imagen del visor. Al soltar el botón, el cursor vuelve a tu pantalla. El botón del candado en la barra del visor lo apaga, y se libera solo cuando la pantalla virtual se quita (también si algo se cierra por un error).
- La imagen la dibuja la tarjeta gráfica: se duplica la pantalla y se reduce con un filtro Lanczos3 en Direct3D 11, así el texto pequeño se lee aunque la ventana sea chica (la API de Magnification que se usaba antes reduce por vecino más cercano y lo rompe). Hasta **60 cuadros por segundo** y el puntero real de la segunda pantalla dibujado encima. Si una app dibuja su propio puntero (por ejemplo un juego), apaga el botón de puntero para no ver dos.
- La ventana **no tiene barra de título de Windows**: arrastra la franja de arriba para moverla y sus bordes para cambiar el tamaño.
- **Barra de opciones**: una píldora oscura y redondeada en el centro del borde de arriba. En reposo es solo una rayita; al acercar el mouse se abre con un movimiento suave y se vuelve a plegar sola al alejarte. Tiene iconos con su explicación al dejar el mouse encima: mantener encima de todo, puntero, silenciar, candado del mouse, pantalla completa, mantener la barra abierta (chinche), minimizar y cerrar. Los botones encendidos se ven resaltados. Arrastrando los puntitos de su izquierda la deslizas a lo largo del borde de arriba. Apretar y arrastrar la píldora fuera de sus botones mueve la ventana del visor (la barra no tapa el arrastre). "Siempre encima" solo vale para la ventana pequeña: en pantalla completa el visor nunca queda encima, así que Alt+Tab y Win+Tab funcionan normal. La barra solo reacciona dentro de la ventana del visor: no se despierta ni toma clics sobre el borde de arriba de la pantalla (por ejemplo las pestañas de Chrome); fuera de la píldora es transparente a los clics. Se oculta siempre que el visor está minimizado u oculto, aunque la hayas fijado abierta, y vuelve al restaurarlo.
- **Silenciar** es un interruptor: encendido (icono resaltado y tachado) apaga el sonido de las apps que están en la pantalla que ese visor muestra (la 2, la 3, una virtual: la suya), también las que empiecen a sonar después (lo revisa cada segundo). Solo se silencia una app si TODAS sus ventanas visibles están en esa pantalla; si además tiene una ventana en otra pantalla (por ejemplo un navegador en dos pantallas), no se toca y la barra lo avisa. Nunca se toca el volumen general ni el sonido de apps que solo están en otras pantallas. Apagado, al cerrar el visor, o al abrir uno nuevo después de que el anterior se cerró a la fuerza, cada app recupera exactamente el estado de sonido que tenía antes.
- **Pantalla completa**: el visor ocupa toda tu pantalla y la rayita de la barra queda arriba al centro; al salir del modo directo (borde o **Ctrl+Alt+Q**) el cursor cae sobre la barra abierta. "Siempre encima" solo existe en la ventana pequeña.
- Funciona con pantallas de **escalas distintas** (por ejemplo 125% y 100%).
- La pantalla virtual la pone un **guardián de pantalla** oculto (`parsec-vdd.ps1`), **sin abrir ninguna ventana de ParsecVDisplay**: habla directo con el driver de Parsec ya instalado. La piden el acceso directo del visor y los lanzadores de pruebas (`detect.ps1`, `launch-on-second-screen.ps1`, `launch_offscreen.py`); **cada sesión tiene su propia pantalla**: cada sesión de Claude Code se reconoce sola (o se nombra con la variable `MODO_EQUIPO_SCREEN_ID` o `-ScreenId`; fuera de Claude, sin nombre, es `default`), y una sesión nueva recibe un monitor virtual nuevo, así dos sesiones que prueban a la vez no se pisan las ventanas. Cada pantalla se mantiene mientras alguno de sus programas siga abierto y, pasados 10 minutos sin ningún programa, queda **libre para la próxima sesión**: no se quita (agregar o quitar un monitor hace que Windows reconstruya las pantallas y puede hacer parpadear todas), solo se quita si pasan 12 horas sin uso, con `-Release` o al cerrar el guardián. Así el parpadeo solo ocurre cuando de verdad hace falta un monitor nuevo; hasta 8 a la vez. `parsec-vdd.ps1 -Release -ScreenId <id>` quita una ya; `-Release` solo, todas. El candado del mouse cubre todas las pantallas virtuales, y en el visor un botón cambia de una a otra. Si el driver no está, el visor avisa y ofrece usar la app ParsecVDisplay como antes.

### 4. Control virtual para emuladores

Un pequeño servidor sin drivers (`scripts/virtual-pad/dsu_server.py`) hace de control de juego. El emulador (Dolphin y otros compatibles con DSU) lo recibe aunque su ventana no esté activa. Probado con Dolphin: 20 de 20 pulsaciones registradas sin foco. Receta completa: [`references/virtual-pad.md`](../skills/modo-equipo/references/virtual-pad.md).

### 5. Cursor propio para Claude

En una sesión de Windows hay **un solo cursor**; una segunda pantalla no agrega otro. Las opciones reales, de más liviana a más pesada, están en [`references/own-cursor.md`](../skills/modo-equipo/references/own-cursor.md): manejar apps sin cursor (UI Automation), una sesión hija de Windows (por ejemplo, el proyecto Anode), Windows Sandbox o una máquina virtual. La skill solo las explica; **nunca las instala**.

### 6. La regla en todas tus sesiones

La skill te pregunta una vez si quieres estas reglas en **todas** tus sesiones de Claude. Si dices que sí, agrega un bloque corto y marcado al final de tu `~/.claude/CLAUDE.md`. Se puede quitar cuando quieras. Ver el contrato abajo y [06-scripts.md](06-scripts.md#global_rulepy).

## Contrato

- **Regla base:** nunca mover el cursor real, enviar teclas reales ni tomar el foco para pruebas o automatización; nunca pedir al usuario que deje de usar mouse o teclado. Elegir método por la tabla de arriba (primera coincidencia gana). Si ninguno sirve: avisar antes, dar duración estimada y esperar OK.
- **Segunda pantalla:** solo Windows; se omite en otros sistemas.
  1. Si `~/.claude/modo-equipo/preferences.md` contiene `second-screen: declined`, correr normal.
  2. Detectar con `detect.ps1` (JSON con `secondScreen`). Si falta pantalla y el driver de Parsec está instalado, `detect.ps1` la pide al guardián de pantalla antes de responder.
  3. Si hay: lanzar con `launch-on-second-screen.ps1 -Root <proyecto>`; esperar con un solo comando en segundo plano hasta que `status` sea `done` en `~/.claude/modo-equipo/tests-last.json`; leer `result` por suite y el detalle en `tests-last.log`. `missing-tool` no es PASS. Código de salida 2 del lanzador = la pantalla desapareció → correr normal.
  4. Si no hay: correr normal y hacer UNA pregunta por equipo (sí / no / no preguntar más → `second-screen: declined`).
- **Regla global (opt-in):** una vez por activación. `global-rule: declined` en `preferences.md` → omitir. Si no: `global_rule.py status` → `current vN` (omitir) | `outdated vN` (ofrecer actualizar; con sí, `install`) | `missing` (UNA pregunta; con sí, `install`, que debe imprimir `current vN`) | `broken` (no tocar; pedir al usuario que lo arregle a mano).
- **Nunca** descargar, instalar drivers ni ejecutar programas de terceros por cuenta propia.
