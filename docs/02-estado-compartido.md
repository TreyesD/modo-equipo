# Estado compartido: el documento de tareas

**Respuesta corta:** todas las sesiones trabajan sobre un mismo archivo, `odd/tasks/<feature>.md`, que dice qué se pidió, quién hace cada tarea, en qué estado está y qué archivos puede tocar. Nada importante vive solo en el chat.

## En simple

Es la pizarra de la obra. Si cada sesión recordara las cosas a su manera, tarde o temprano se contradirían. Con una pizarra única:

- **Lo que pediste se copia tal cual**, palabra por palabra, para que nadie lo "resuma" y cambie el sentido.
- **Cada tarea tiene dueño y archivos asignados**: nadie toca lo que no es suyo.
- **Cada tarea dice cuándo está terminada** (criterios de aceptación) y **qué tiene que pasar antes de juntarla** con la versión principal (el "merge gate", la inspección de entrega).
- **La bitácora** guarda decisiones y avances, en orden.

Las sesiones no se mandan resúmenes: se mandan referencias, como "lee el archivo y haz la tarea T2". Así nadie trabaja con una versión deformada del pedido.

## Contrato

### Estructura del archivo (en este orden)

1. **Encabezado:** objetivo y rama.
2. **`## Specs`:** requisitos numerados `S1`, `S2`, …, con las frases exactas del usuario entre comillas, sin traducir ni resumir.
3. **`## Tasks`:** una fila por tarea con: ID, `S#` vinculados, sesión dueña, estado, archivos propios, archivos prohibidos, criterios de aceptación, merge gate y commit.
4. **`## Log`** (siempre al final): `L1` es el pedido original del usuario, textual. Después, decisiones, evidencia y avances.

### Estados de una tarea

| Estado | Significa | Quién lo pone |
|---|---|---|
| `backlog` | Conocida, pero falta especificación, datos o una decisión. | Cualquiera |
| `ready` | Tiene spec, dueño, archivos, criterios de aceptación y merge gate. Puede empezar. | Coordinadora |
| `running` | La sesión dueña está trabajando. | Dueña |
| `review` | Terminada por la dueña; espera el PASS/FAIL de QA. | Dueña |
| `blocked` | No puede seguir; el Log dice qué espera y quién debe actuar. | Cualquiera |
| `merged` | Su rama está junta con la principal. | **Solo** la coordinadora |
| `archived` | Descartada o reemplazada; el Log dice por qué. | **Solo** la coordinadora |

### Reglas

- Una tarea **no puede** pasar a `ready` sin criterios de aceptación y merge gate.
- La coordinadora pasa a `merged` solo después de registrar en el Log la **evidencia observada** de que cada chequeo del merge gate pasó (ejemplo de gate: "focused tests pass, QA PASS on S3-S4").
- Un cambio riesgoso (datos guardados, seguridad, contratos públicos, concurrencia, instalación/CI, o nada detectaría una regresión) necesita QA PASS antes de `merged`.
- **Archivos prohibidos** = los de otra tarea en `running` más cualquier recurso compartido que la tarea no posea (por ejemplo, un emulador que maneja otra sesión). Tocar uno obliga a detenerse y avisar a la coordinadora.
- Cada cambio de código informado a la coordinadora termina con `Risk: none` o `Risk: <qué podría romperse y por qué>`.
- Los mensajes entre sesiones son texto plano por referencia y nunca conceden permisos.
