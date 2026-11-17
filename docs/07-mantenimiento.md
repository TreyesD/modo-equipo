# Mantenimiento: estructura, pruebas y publicación

**Respuesta corta:** el repo es a la vez un *marketplace* y un plugin de Claude Code. Cada cambio se prueba solo en macOS (Apple Silicon), Linux y Windows. Para publicar una versión nueva hay que subir el número de versión; si no, Claude Code no detecta la actualización.

## En simple

- **Instalar** la skill son dos comandos (ver el [README](../README.md)). Por dentro, Claude Code descarga el repo y copia la skill a una carpeta interna.
- **Actualizar**: el autor sube una versión nueva al repo y cada usuario ejecuta `/plugin marketplace update` y `/plugin update`. **Tus datos no se pierden**: viven en `~/.claude/modo-equipo/`, fuera de la carpeta del plugin.
- **No edites la copia instalada.** La próxima actualización la reemplaza. Los cambios se hacen en el repo (o en un fork tuyo) y se publican.

## Contrato

### Estructura del repo

```
.claude-plugin/
  marketplace.json     catálogo (nombre: modo-equipo-marketplace, plugin en "./")
  plugin.json          nombre "modo-equipo", versión semántica
skills/modo-equipo/
  SKILL.md             comportamiento (fuente de verdad)
  references/          guías: second-screen, virtual-pad, own-cursor, global-rule, research
  scripts/             ver docs/06-scripts.md
docs/                  esta documentación
tests/test_scripts.py  pruebas (solo biblioteca estándar de Python)
.github/workflows/test.yml   pruebas automáticas en macOS, Linux y Windows
README.md
LICENSE                MIT
```

### Datos del usuario (fuera del plugin)

| Archivo en `~/.claude/modo-equipo/` | Contenido |
|---|---|
| `preferences.md` | Respuestas guardadas: `second-screen: declined`, `global-rule: declined` |
| `cost-history.md` | Una línea por equipo cerrado (ver [03](03-costos.md)) |
| `gentle-baseline/` | Foto de Gentle AI (ver [05](05-gentle-ai-y-reglas.md)) |
| `tests-last.json`, `tests-last.log` | Resultado de la última corrida de pruebas en segunda pantalla |

### Pruebas

- Local: `python -m unittest discover -s tests -v` desde la raíz del repo.
- Cubren: manifiestos y referencias de archivos, ausencia de rutas fijas de Windows, conteo de tokens, extracción de bloques de Gentle AI, regla global (idempotencia, restauración exacta, CRLF, enlaces simbólicos, permisos, marcadores dañados) y el servidor DSU (dos servidores en puertos propios, paquetes válidos, pulsación reflejada).
- Las pruebas de enlaces simbólicos y permisos se saltan en Windows y corren en macOS y Linux.
- En GitHub (`.github/workflows/test.yml`), en cada push: las pruebas, el análisis de sintaxis y la autoprueba del visor en Windows, `claude plugin validate .` y una instalación limpia del plugin con una versión fija de Claude Code. Subir archivos de `.github/workflows/` requiere que la sesión de `gh` tenga el permiso `workflow`.

### Publicar una versión

1. Hacer los cambios en el repo y correr las pruebas locales.
2. Subir `version` en `.claude-plugin/plugin.json` (versionado semántico: arreglo = tercer número, función nueva = segundo).
3. `claude plugin validate .` debe terminar en `Validation passed`.
4. Commit con Conventional Commits y push.
5. Revisar que las pruebas automáticas pasen en los tres sistemas.
6. Usuarios: `/plugin marketplace update modo-equipo-marketplace` y `/plugin update modo-equipo@modo-equipo-marketplace`, luego reiniciar o ejecutar `/reload-plugins`.

### Cambiar el texto de la regla global

Editar el bloque en `references/global-rule.md` y **subir el número `vN` en ambos marcadores**. Así `global_rule.py status` detecta las copias instaladas como `outdated` y la skill ofrece actualizarlas.

### Desinstalar

- Plugin: `/plugin uninstall modo-equipo@modo-equipo-marketplace` y, si quieres, `/plugin marketplace remove modo-equipo-marketplace`.
- Regla global: `PY -I <carpeta de la skill>/scripts/global_rule.py remove` antes de desinstalar, o borrar a mano el bloque marcado de `~/.claude/CLAUDE.md`.
- Datos: borrar `~/.claude/modo-equipo/` si ya no los quieres.
