# Guia paso a paso de N4ti

El nombre actual es N4ti. `gy.cmd` sigue siendo un alias compatible en los
ejemplos heredados de esta guia. Las rutas `GY/` corresponden a proyectos existentes;
en una instalacion nueva use `N4ti/`. No renombre una memoria existente manualmente
ni mantenga ambas carpetas: se rechazara esa ambiguedad.

Para dejar un punto de continuacion y retomarlo en otra sesion:

```powershell
.\n4ti.cmd save -Summary "Trabajo realizado; evidencia pendiente" -Next "Siguiente paso"
.\n4ti.cmd resume
```

Use `-Id TASK-001` en ambos comandos para limitar el checkpoint a una tarea.
El guardado es manual y no verifica pruebas ni captura conversaciones. No incluya
credenciales o datos personales. Los checkpoints se conservan dentro del proyecto.

## 1. Instalar en un proyecto existente

Abra una terminal en la carpeta del paquete N4ti y ejecute:

```bat
Install-N4ti.cmd "C:\ruta\completa\a\tu\proyecto"
```

La instalacion no reemplaza `AGENTS.md`, `CLAUDE.md` ni `.gitignore`. Agrega un
bloque administrado y puede ejecutarse nuevamente cuando el kit se actualice.

## 2. Completar la memoria inicial

En el proyecto instalado, edita solamente estos tres archivos al comenzar:

1. `GY/core.md`: proposito, stack, limites y reglas que nunca deben olvidarse.
2. `GY/current-state.md`: tarea actual, ultimo resultado y siguiente accion.
3. `GY/commands.md`: comandos reales para instalar, ejecutar, probar y compilar.

Luego valida:

```bat
gy.cmd validate
```

No intentes documentar todo el proyecto el primer dia. Completa
`GY/knowledge/architecture.md` a medida que aparezcan decisiones relevantes.

## 3. Empezar una tarea

```bat
gy.cmd new-task -Title "Agregar recuperacion de contrasena" -Tags "auth,email,backend"
```

Abre el archivo generado en `GY/tasks/` y sustituye el resultado esperado y las
comprobaciones de aceptacion. Esto evita que el agente confunda actividad con
resultado terminado.

## 4. Trabajar con Codex o Claude Code

Usa este pedido corto:

```text
Lee AGENTS.md. Continua la tarea activa siguiendo el protocolo GY. Ejecuta las pruebas y actualiza GY al terminar.
```

Para una solicitud distinta:

```text
Lee AGENTS.md. Ejecuta gy.cmd context para esta solicitud: "corregir expiracion JWT". Usa el paquete generado, implementa, valida y actualiza GY.
```

El agente solo recibe L0, L1 y los documentos relevantes. L3 y L4 permanecen
fuera del contexto salvo que las etiquetas, relaciones o palabras de la consulta
los hagan necesarios.

## 5. Registrar una decision

Una decision es algo que otro agente podria cambiar por desconocimiento:

```bat
gy.cmd new-decision -Title "Usar PostgreSQL para auditoria" -Summary "La auditoria requiere consultas relacionales y retencion de cinco anos" -Tags "database,audit" -Affects "src/audit,TASK-003"
```

Completa consecuencias y evidencia en el archivo creado. No registres como
decision detalles temporales ni pasos de depuracion.

## 6. Terminar y compactar

```bat
gy.cmd close-task -Id TASK-003 -Summary "Auditoria implementada; pruebas verdes" -Next "Preparar migracion de produccion"
gy.cmd compact -KeepCompleted 5
gy.cmd validate
```

`compact` conserva las cinco tareas terminadas mas recientes en L2 y mueve las
anteriores a L4. No borra conocimiento.

## 7. Crear un proyecto nuevo

Primero crea el repositorio con el framework elegido. Inmediatamente despues,
instala el kit y completa los tres archivos iniciales:

```bat
Install-GY.cmd "C:\proyectos\nuevo-proyecto"
```

Haz el primer commit de `GY/`, `AGENTS.md`, `CLAUDE.md`, `gy.ps1` y `gy.cmd` junto
con la estructura inicial del proyecto.

## 8. Trabajar desde el celular y por voz

En Claude Code Remote o Codex Remote puedes dictar:

```text
Continua TASK-003. Lee el protocolo GY, compila solo el contexto necesario, implementa, ejecuta las pruebas y deja el siguiente paso actualizado. No publiques ni hagas merge.
```

Para una idea que aun no debe modificar codigo:

```text
Crea una tarea GY titulada mejorar el flujo de pagos, con etiquetas pagos, backend y seguridad. Analiza el repositorio y completa resultado y criterios, pero no implementes todavia.
```

La voz transmite la orden; la memoria vive versionada en el repositorio. Por eso
puedes cambiar entre celular, Codex y Claude sin depender de la conversacion
anterior.

## 9. Reglas de mantenimiento

- Mantener `current-state.md` por debajo de unas 900 tokens.
- Convertir restricciones permanentes en decisiones, no en notas sueltas.
- Usar identificadores en commits y pedidos: `TASK-003`, `DEC-002`.
- No guardar secretos, tokens, contrasenas ni datos personales en `GY/`.
- Marcar `critical` solamente aquello que debe entrar en todas las interacciones.
- Ejecutar `compact` semanalmente o al terminar una etapa del proyecto.
