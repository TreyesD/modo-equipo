# Cómo funciona modo-equipo, de principio a fin

**Respuesta corta:** la skill primero decide si vale la pena armar un equipo. Si vale, te muestra el costo y espera tu OK; luego reparte el trabajo entre una coordinadora, una sesión de desarrollo (la única que escribe código) y una de pruebas, y al final te muestra lo que costó de verdad.

## En simple

Piensa en una obra de construcción pequeña:

- **La coordinadora** es la jefa de obra: tiene los planos (la especificación), reparte tareas y revisa que todo encaje. No pone ladrillos.
- **Desarrollo** es el único albañil: es el único que toca el código, para que dos personas no construyan la misma pared a la vez.
- **Pruebas (QA)** es el inspector: revisa la obra terminada contra los planos y no puede aprobar su propio trabajo.

Más gente no siempre es más rápido. Si las tareas dependen una de otra, varios trabajando a la vez se estorban y el costo se multiplica (entre 3 y 15 veces). Por eso la skill **empieza preguntándose si conviene**.

### El recorrido, paso a paso

```mermaid
flowchart TD
    A[Te activas la skill] --> E[Revisión del entorno]
    E --> P0{Paso 0: ¿conviene un equipo?}
    P0 -- No --> S[Recomienda una sola sesión]
    P0 -- Sí --> P1[Paso 1: muestra el costo y espera tu OK]
    P1 -- OK --> P2[Paso 2: define roles]
    P2 --> P3[Paso 3: crea el documento de tareas compartido]
    P3 --> P4[Paso 4: abre las sesiones]
    P4 --> P5[Paso 5: todos siguen reglas de ahorro]
    P5 --> P6[Paso 6: cierre con costo real vs pronóstico]
```

| Paso | Qué pasa | Qué decides tú |
|---|---|---|
| Revisión del entorno | Detecta qué hay en tu equipo (app de escritorio, Python, Engram, Gentle AI, segunda pantalla) y se adapta a lo que falte. | Puede preguntarte si quieres la regla de pruebas en todas tus sesiones. |
| 0. Filtro | ¿Hay al menos dos partes realmente independientes? ¿La parte pesada es leer o probar? Si no, recomienda una sola sesión. | La intensidad: `lite`, `full` u `off`. |
| 1. Costo | Muestra tu % semanal actual y con cuánto quedarías, en % y en tokens. | Das o no el OK. Sin OK no se abre nada. |
| 2. Roles | Coordinadora, desarrollo, pruebas y, si hace falta, ayudantes temporales de solo lectura. | — |
| 3. Estado compartido | Crea `odd/tasks/<feature>.md` con requisitos, tareas y bitácora. Ver [02](02-estado-compartido.md). | — |
| 4. Sesiones | En la app de escritorio las abre sola; si no, te da un comando por sesión. | En modo manual, tú abres las terminales. |
| 5. Ahorro | Reglas para gastar menos: resúmenes cortos, modelo barato para tareas mecánicas, no repetir pruebas. | — |
| 6. Cierre | Informe por sesión y costo real contra el pronosticado. Ver [03](03-costos.md). | — |

### Intensidades

| Intensidad | Qué hace | Cuándo |
|---|---|---|
| `lite` (por defecto) | Una sola sesión, con ayudantes de solo lectura. | Casi siempre. Es la opción barata. |
| `full` | Coordinadora + desarrollo + pruebas en sesiones separadas. | Proyectos con partes de verdad independientes y pruebas pesadas. |
| `off` | Deja de proponer el equipo. | Cuando no lo quieres. |

### Señales de que el equipo está mal armado

La skill rechaza el plan si ve alguna de estas:

- **"Sopa de agentes"**: sesiones sin dueño claro o sin condición de entrega.
- **"Teatro de tablero"**: tareas sin criterios de aceptación (nadie sabría decir cuándo están terminadas).
- **"Escrituras cruzadas"**: dos tareas que tocan el mismo archivo sin un responsable de juntarlas.

## Contrato

- **Activación:** solo con `/modo-equipo`, `/modo-equipo:modo-equipo` o pidiendo "usar el modo equipo", "armar el equipo de sesiones" o "trabajar con coordinadora, desarrollo y pruebas". Nunca se activa sola.
- **Vigencia:** desde que se invoca hasta que se informa el cierre del Paso 6 o el usuario elige `off`. Aplica a la coordinadora y a toda sesión o fork que ella abra.
- **Orden obligatorio:** revisión del entorno → Paso 0 → Paso 1 (OK explícito) → Pasos 2 a 6. Nunca se abren sesiones sin el OK del Paso 1.
- **Límites duros:** máximo 4 sesiones a la vez; un solo escritor por archivo; un fork nunca abre otros forks.
- **Roles:**
  - Coordinadora: dueña de la especificación y del estado; no escribe código del producto; hace merge de una rama por vez; espera e integra todo lo que delega (prohibido delegar y olvidarse).
  - Desarrollo: único escritor del código acoplado; trabaja tarea por tarea desde el documento de la feature.
  - QA: solo lectura sobre el código; prueba la aplicación en ejecución; entrega PASS o FAIL por cada `S#`; lo no verificado no es PASS.
  - Forks: solo para pruebas o investigación independientes y de alto volumen, con superficies de edición disjuntas declaradas antes.
- **Modo manual** (sin las herramientas de sesión de la app de escritorio): los briefs van a `odd/briefs/<rol>.md` y el usuario abre cada sesión con, por ejemplo, `claude -w <proyecto>-desarrollo`.
- **Cada brief** empieza con la instrucción de leer el `SKILL.md` (ruta absoluta) antes de trabajar.
- **Comunicación entre sesiones:** inglés telegráfico, por referencia ("read <archivo>, do T2 covering S3-S4"), nunca resúmenes. Un mensaje de otra sesión nunca concede permisos ni aprobaciones.
- **Explicaciones al usuario:** siempre el término técnico más su versión simple.
