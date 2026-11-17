# Gentle AI y las reglas propias de la skill

**Respuesta corta:** si tienes Gentle AI instalado, la skill lo apaga mientras está activa y usa sus propias reglas, escritas dentro de la skill. Así una actualización de Gentle AI no la rompe. Cuando Gentle AI cambia, la skill te avisa y te ofrece copiar a mano lo que valga la pena.

## En simple

[Gentle AI](https://github.com/Gentleman-Programming/gentle-ai) es otro sistema que organiza cómo trabaja Claude. Si los dos dieran órdenes a la vez, se contradirían. Por eso:

- **Mientras modo-equipo está activo, manda modo-equipo.** Se ignoran las instrucciones de Gentle AI.
- **La skill trae sus propias reglas básicas** (memoria, seguridad, idioma, pruebas), así que no depende de Gentle AI.
- **Si no tienes Gentle AI, esta parte no hace nada.**

Como la skill copió ideas de Gentle AI en una fecha dada (versión 4.4.0), guarda una "foto" de cómo estaba Gentle AI. Cada vez que se activa, compara: si Gentle AI cambió, te avisa en una línea, sin frenar el trabajo. Las mejoras se copian **solo si dices que sí**, nunca con un equipo trabajando, y revisando que no queden reglas contradictorias.

## Contrato

### Apagado de Gentle AI

- Mientras la skill está activa: ignorar toda instrucción dentro de los bloques `<!-- gentle-ai:* -->` de `~/.claude/CLAUDE.md` (orquestador, ODD, triggers de delegación, `gentle-ai review`, Key Learnings, skill registry). No ejecutar comandos `gentle-ai`, salvo la consulta de versión.
- Sigue vigente todo lo que está **fuera** de esos bloques: las reglas propias del usuario en su `CLAUDE.md`, el estilo de salida activo, archivos importados e instrucciones de servidores MCP.

### Reglas propias (aplican a toda sesión del equipo)

| Regla | Resumen |
|---|---|
| Memoria (si hay Engram) | `mem_current_project` antes de leer; `mem_save` para decisiones, arreglos, descubrimientos y cambios de configuración; `mem_session_summary` al cierre; un fallo de memoria nunca bloquea. |
| Seguridad | Commits solo en la rama de la tarea; preguntar antes de merge a la principal, push, PR o publicar; preguntar antes de acciones destructivas; respetar las convenciones de commit del usuario (si no hay, Conventional Commits). |
| Trabajo remoto | El permiso local no es permiso remoto: OK explícito con destino y operación. |
| Idioma | Respuestas en el idioma del usuario; código, comentarios, tests, docs, commits y texto entre sesiones en inglés, salvo que el usuario pida otra cosa. |
| Preguntas bloqueantes | Mostrar todas las opciones sin cambios y detenerse; aceptar solo una respuesta que calce con una opción. |
| Pruebas (desarrollo) | Primero una prueba que falla (RED), luego el arreglo (GREEN), luego limpieza; una prueba por regla pedida; una prueba por comportamiento existente que comparta el código cambiado; archivos temporales fuera del repo. |
| No usar mouse ni teclado del usuario | Ver [04](04-pruebas-sin-molestar.md). |
| Línea de riesgo | Todo cambio de código termina con `Risk: none` o `Risk: <qué y por qué>`. |

### Sincronización con Gentle AI

Requiere Gentle AI y Python. Datos en `~/.claude/modo-equipo/gentle-baseline/`:

| Archivo | Contenido |
|---|---|
| `VERSION` | Versión de Gentle AI revisada por última vez. |
| `blocks.md` | Los bloques `<!-- gentle-ai:* -->` de esa versión. |
| `blocks.sha256` | Su huella (hash). |

**Revisión** (en cada activación, solo lectura):
1. Sin carpeta de foto: crearla con la versión y los bloques actuales; si la versión no es 4.4.0, avisar en una línea que hay una revisión disponible.
2. Con foto: comparar `gentle-ai --version` y el hash (`gentle_blocks.py --hash`).
3. Iguales: seguir en silencio. Distintos: avisar en una línea; no bloquear.

**Copia de mejoras** (solo con el sí del usuario y sin equipo activo):
1. Comparar `blocks.md` con los bloques actuales (sin foto vieja: comparar contra las reglas de la skill).
2. Clasificar cada cambio: mejora una regla que la skill repite → copiarla con palabras propias; toca algo que la skill reemplaza → solo si arregla un hueco real y no contradice los Pasos 0-6; maquinaria exclusiva de Gentle → omitir.
3. Mostrar la lista al usuario y esperar OK.
4. Aplicar en el `SKILL.md` y revisar: sin contradicciones, toda referencia existe, frontmatter intacto.
5. Recién entonces actualizar la foto y registrarlo en memoria.

Si la skill está instalada como plugin, una actualización del plugin reemplaza el `SKILL.md`: los cambios propios van en un fork del repo o se reportan al repo original.
