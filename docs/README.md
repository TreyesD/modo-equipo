# Documentación de modo-equipo

Esta carpeta explica cada parte de la skill **modo-equipo**. Está escrita para dos lectores a la vez:

- **Personas**: cada documento empieza con una sección **"En simple"**, sin conocimientos previos. Cada término técnico va con su explicación cotidiana.
- **IA (Claude u otro agente)**: cada documento tiene una sección **"Contrato"** con rutas, comandos, formatos y reglas exactas, sin ambigüedad. La fuente de verdad para el comportamiento sigue siendo [`skills/modo-equipo/SKILL.md`](../skills/modo-equipo/SKILL.md); si algo de aquí contradice al `SKILL.md`, manda el `SKILL.md`.

## Qué es, en una frase

Una skill de Claude Code que, **solo cuando conviene**, organiza el trabajo en varias sesiones con roles separados (coordinadora, desarrollo y pruebas), te dice antes cuánto va a costar y hace que las pruebas no usen tu pantalla, tu mouse ni tu teclado.

## Mapa de documentos

| Si quieres saber… | Lee |
|---|---|
| Cómo funciona de principio a fin (pasos 0 a 6, roles, límites) | [01-como-funciona.md](01-como-funciona.md) |
| Cómo se comparten tareas y estado entre sesiones | [02-estado-compartido.md](02-estado-compartido.md) |
| Cómo calcula y mide el costo (% semanal y tokens) | [03-costos.md](03-costos.md) |
| Cómo hace pruebas sin ocupar tu pantalla, mouse ni teclado | [04-pruebas-sin-molestar.md](04-pruebas-sin-molestar.md) |
| Qué pasa si usas Gentle AI y qué reglas trae la skill | [05-gentle-ai-y-reglas.md](05-gentle-ai-y-reglas.md) |
| Qué hace cada script, cómo se ejecuta y qué devuelve | [06-scripts.md](06-scripts.md) |
| Estructura del repo, pruebas automáticas y cómo publicar una versión | [07-mantenimiento.md](07-mantenimiento.md) |

## Orden de lectura sugerido

1. **Si solo vas a usarla**: [01](01-como-funciona.md), luego [03](03-costos.md) y [04](04-pruebas-sin-molestar.md).
2. **Si la vas a modificar**: todo, en orden, y después el `SKILL.md`.
3. **Si eres una IA que va a ejecutarla**: el `SKILL.md` primero; estos documentos solo como contexto y para los contratos de los scripts ([06](06-scripts.md)).

## Glosario mínimo

| Término | En simple |
|---|---|
| Skill | Un paquete de instrucciones que Claude carga cuando lo pides. Como un manual de procedimiento. |
| Plugin | La forma de instalar una skill (u otras piezas) en Claude Code con un comando. |
| Sesión | Una conversación de Claude independiente, con su propia memoria de trabajo. |
| Subagente / fork | Un ayudante temporal que hace una tarea y devuelve el resultado a quien lo lanzó. |
| Token | La unidad con la que se mide cuánto texto procesa Claude. Más tokens = más costo. |
| % semanal | Cuánto de tu límite semanal del plan de Claude llevas usado. |
| Rama (branch) | Una copia paralela del código en git, para trabajar sin tocar la versión principal. |
| Merge | Juntar el trabajo de una rama con la versión principal. |
| QA | Pruebas: verificar que algo funciona como se pidió. |
| Hook | Un script que Claude Code ejecuta solo en un momento fijo (por ejemplo, al iniciar sesión). |
