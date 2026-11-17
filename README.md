# modo-equipo

Skill para Claude Code que organiza el trabajo en **varias sesiones con roles separados**, y solo cuando realmente conviene:

- **Coordinadora**: mantiene la especificación y el estado compartido, reparte las tareas y hace los merges de a una rama por vez. No escribe código del producto.
- **Desarrollo**: es la única sesión que escribe el código.
- **Pruebas (QA)**: solo lee el código. Prueba la aplicación funcionando y entrega un PASS o FAIL por cada requisito. Nunca aprueba su propio trabajo.

Antes de lanzar nada, la skill verifica si el trabajo se puede dividir de verdad. Si no se puede, recomienda seguir con una sola sesión. Si se puede, te muestra cuánto vas a gastar en **% de tu límite semanal y en tokens**, y espera tu OK. Al cerrar, compara lo que pronosticó con lo que se gastó de verdad.

> Idea central: más agentes no es mejor. El paralelismo cuesta entre 3 y 15 veces los tokens de una sola sesión y falla cuando el código está muy acoplado. El respaldo está en [`references/research.md`](skills/modo-equipo/references/research.md).

## Documentación

La carpeta [`docs/`](docs/README.md) explica cada parte de la skill, para personas (en simple) y para IA (contratos exactos): cómo funciona, estado compartido, costos, pruebas sin usar tu mouse ni teclado, Gentle AI, cada script y cómo mantenerla.

## Requisitos

| Requisito | ¿Obligatorio? | Si falta |
|---|---|---|
| Claude Code | Sí | — |
| App de escritorio de Claude (pestaña Code) | No | El modo `full` pasa a modo manual: la skill te da los comandos para abrir cada sesión en su propia terminal. El % semanal se lo dices tú, leyéndolo con `/usage`. |
| Python 3 | No | No se miden los tokens por sesión y no se revisan los cambios de Gentle AI. |
| Windows + segunda pantalla (física o virtual) | No | Las pruebas corren de la forma normal. Si no hay segunda pantalla, la skill pregunta una vez si quieres una guía para crear una virtual ([`references/second-screen.md`](skills/modo-equipo/references/second-screen.md)); nunca descarga ni instala nada por su cuenta. Con segunda pantalla, todas las pruebas corren ahí. Con `scripts/second-screen/screen-viewer.ps1` la ves en vivo y la usas como pantalla táctil: haces clic, arrastras o usas la rueda sobre la imagen y la acción ocurre en la segunda pantalla. |
| [Engram](https://github.com/Gentleman-Programming/engram) (memoria) | No | El registro queda solo en el documento de la feature. |
| [Gentle AI](https://github.com/Gentleman-Programming/gentle-ai) | No | Si lo tienes, la skill lo apaga mientras está activa y te avisa cuando Gentle AI cambia. |

## Pruebas sin ocupar tu teclado ni tu mouse

La skill prohíbe que las pruebas usen tu mouse o teclado reales, o que te quiten el foco de la ventana. Para emuladores (Dolphin y otros compatibles con DSU) incluye un control virtual sin drivers, [`scripts/virtual-pad/dsu_server.py`](skills/modo-equipo/scripts/virtual-pad/dsu_server.py), con su receta en [`references/virtual-pad.md`](skills/modo-equipo/references/virtual-pad.md). Así el juego recibe los controles aunque su ventana no esté activa, y tú sigues trabajando.

Si quieres, la skill también puede aplicar estas reglas en **todas** tus sesiones de Claude: te pregunta una sola vez y, si dices que sí, agrega un bloque corto y marcado a tu `~/.claude/CLAUDE.md`. Para casos que de verdad necesitan un cursor, [`references/own-cursor.md`](skills/modo-equipo/references/own-cursor.md) compara opciones para darle a Claude su propio cursor sin usar el tuyo. La skill nunca las instala sola.

## Instalación

### Opción A: como plugin (recomendada)

Dentro de Claude Code:

```
/plugin marketplace add TreyesD/modo-equipo
/plugin install modo-equipo@modo-equipo-marketplace
```

O desde la terminal:

```bash
claude plugin marketplace add TreyesD/modo-equipo
```

```bash
claude plugin install modo-equipo@modo-equipo-marketplace
```

Se invoca con `/modo-equipo:modo-equipo`, o pidiéndolo con palabras: "usar el modo equipo".

### Opción B: copia manual

Copia la carpeta `skills/modo-equipo` a `~/.claude/skills/modo-equipo`. Se invoca con `/modo-equipo`.

No uses las dos opciones a la vez: la skill quedaría duplicada.

## Cómo se usa

1. Escribe `/modo-equipo:modo-equipo` (o `/modo-equipo` si la instalaste a mano) y describe la tarea.
2. La skill revisa si tiene sentido armar un equipo y te propone una intensidad:
   - `lite`: una sesión, más ayudantes de solo lectura;
   - `full`: coordinadora, desarrollo y pruebas;
   - `off`: no proponer el equipo.
3. Te muestra el costo estimado y espera tu OK.
4. El estado compartido queda en `odd/tasks/<feature>.md`, dentro de tu proyecto.
5. Al cerrar, te muestra lo que costó de verdad y lo agrega a `~/.claude/modo-equipo/cost-history.md`. Con ese historial, los pronósticos siguientes salen más precisos.

## Pruebas automáticas

Cada cambio se prueba solo en GitHub en **macOS (Apple Silicon), Linux y Windows**: los scripts de la skill y una instalación limpia del plugin en Claude Code. Para correr las pruebas en tu equipo:

```bash
python -m unittest discover -s tests -v
```

## Licencia

MIT
