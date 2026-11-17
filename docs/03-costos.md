# Costos: pronóstico antes, medición después

**Respuesta corta:** antes de abrir sesiones, la skill te dice cuánto llevas de tu límite semanal y con cuánto quedarías aproximadamente, en % y en tokens. Al cerrar, mide lo que costó de verdad y guarda una línea en un historial para que los próximos pronósticos sean más precisos.

## En simple

Tu plan de Claude tiene un límite semanal. Un equipo de sesiones gasta varias veces más que una sesión sola, así que antes de empezar te muestra algo así:

> **Ahora:** 80% semanal usado, se reinicia en 2 días; 5 horas: 49%.
> **Pronóstico:** 3 sesiones ≈ 400.000 tokens ≈ +5-9% semanal, así que quedarías aprox. en **85-89%**.
> **A cambio de:** revisión independiente y pruebas en paralelo.

Si el pronóstico llega a 90% o más, te lo advierte y te recomienda la opción barata (`lite`). Sin tu OK no se abre ninguna sesión.

- **Lo medido es exacto. Lo pronosticado siempre dice "aprox."**, y se calcula con datos registrados, nunca inventados.
- **El historial mejora el pronóstico:** cada cierre guarda cuántos tokens equivalieron a 1% semanal. La primera vez no hay historial, así que la coordinadora se mide a sí misma; si todavía no movió el %, te lo dice en vez de inventar.
- **El % semanal es de toda tu cuenta.** Si tenías otras sesiones trabajando al mismo tiempo, también suman, y el informe lo avisa.

## Contrato

### Fuentes de datos

| Dato | Fuente | Si no está |
|---|---|---|
| % semanal y de 5 horas | `mcp__ccd_session_mgmt__get_usage` (app de escritorio) | Pedir al usuario que ejecute `/usage` y diga el % semanal. |
| Tokens de una sesión | `scripts/session_tokens.py` sobre `~/.claude/projects/<carpeta-codificada>/<session-id>.jsonl` | Registrar `unavailable`. |
| Historial | `~/.claude/modo-equipo/cost-history.md` | Usar la medición de la propia coordinadora. |

- `<carpeta-codificada>` es la carpeta de trabajo con cada carácter no alfanumérico cambiado por `-` (por ejemplo `E:\Claude` → `E--Claude`). Si hay duda: `ls ~/.claude/projects/*/<session-id>.jsonl`.
- El transcript repite la misma respuesta en varias líneas con igual `message.id`. **No sumar a mano**: el script deduplica.

### Cálculo del pronóstico (Paso 1)

1. **Tokens por 1% semanal** = mediana de `ratio` en las últimas 3 filas del historial.
2. **Tokens de una sesión** = mediana de `tokens/session` en esas filas.
3. `T` = tokens de una sesión × multiplicador (3-15×; ~7× para agent teams).
4. Rango de % = `T` ÷ tokens por 1%.
5. Sin historial: (tokens de la coordinadora) ÷ (diferencia de % semanal desde el Paso 0). Si la diferencia es 0, no se da el %; solo el multiplicador y los tokens.
6. Si el extremo alto llega a 90% o más: advertir y recomendar `lite`.

### Línea del historial (Paso 6)

Se escribe en el `## Log` del documento de la feature y se agrega a `cost-history.md`:

```
<fecha> intensity <lite|full> sessions <N> weekly <inicio%>-><fin%> delta <D%> tokens <total> tokens/session <total/N> ratio <total/D tokens por 1%> next <keep|lower|raise>
```

- Si `D` es 0 o el límite se reinició durante el trabajo (`reset`), escribir `ratio n/a`.
- Si ninguna fuente da un número: `unavailable` o `not_applicable`.
