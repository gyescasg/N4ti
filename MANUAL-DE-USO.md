# Manual de uso de N4ti

## Nombre nuevo y compatibilidad

Use `Install-N4ti.cmd`, `n4ti.cmd` y `Test-N4ti.cmd`. Las instalaciones nuevas
guardan memoria en `N4ti/`; las existentes conservan `GY/`. Los ejemplos heredados
de este manual con `gy.cmd` siguen funcionando como alias. Donde aparezca una ruta
`GY/`, use `N4ti/` si su proyecto es nuevo. No cree ambas carpetas ni use
`-ForceTemplates` para una actualizacion normal.

## Guardado manual y reanudacion

```powershell
.\n4ti.cmd save -Summary "Avance del proyecto" -Next "Siguiente paso"
.\n4ti.cmd save -Id TASK-001 -Summary "Avance de la tarea" -Next "Verificar pruebas" -Risks "Revision pendiente"
.\n4ti.cmd resume
.\n4ti.cmd resume -Id TASK-001 -Budget 3000
```

El guardado es opcional: conserva solamente el texto y los metadatos indicados,
sin capturar conversaciones ni leer los archivos mencionados. No incluya secretos
ni datos personales. Los checkpoints son evidencia informada, no verificada, y no
cambian `current-state.md`. `resume` es de solo lectura; si el contenido no cabe,
solicita aumentar el presupuesto sin truncar el avance. Consulte el
[README](README.md#guardar-y-retomar-el-avance) para los limites y compatibilidad.

## Que es

GY es una memoria operativa versionada dentro de cada proyecto. Su objetivo
no es darle conciencia al agente, sino permitir que Codex y Claude Code recuperen
el estado, las reglas y las decisiones importantes sin cargar conversaciones
completas ni depender de que tu recuerdes explicar todo nuevamente.

La memoria pertenece al proyecto, no a una aplicacion. Por eso puede ser utilizada
por Codex desde la PC, Claude Code Remote desde el celular u otro agente que tenga
acceso al mismo repositorio.

## Que problema resuelve

Sin GY suele ocurrir este ciclo:

1. Explicas nuevamente el estado del proyecto.
2. El agente investiga cosas que ya se habian decidido.
3. Trabaja, pero la conversacion termina sin registrar el resultado.
4. La siguiente sesion comienza con informacion incompleta.

Con GY, el estado importante queda en archivos pequenos y estructurados. El
agente recibe instrucciones permanentes para leerlos al comenzar y actualizarlos
al terminar.

## Es solo instalar y listo

No completamente. Hay dos etapas:

### Etapa 1: instalacion unica

```bat
"C:\ruta\a\GY\Install-GY.cmd" "C:\ruta\a\tu\proyecto"
```

Esto crea:

- `GY/`: memoria del proyecto;
- `gy.cmd`: comandos de administracion;
- un protocolo dentro de `AGENTS.md` para Codex;
- el mismo protocolo dentro de `CLAUDE.md` para Claude Code;
- una exclusion de `GY/.runtime/` en `.gitignore`.

La instalacion es idempotente: puedes ejecutarla nuevamente para actualizar las
herramientas sin duplicar el protocolo ni reemplazar tu memoria.

### Etapa 2: inicializacion unica del proyecto

```bat
gy.cmd init -Idea "Que quieres construir, para quien y con que resultado" -InitMode guided -ModelMode uniform
```

El comando detecta stack, checkpoints y OpenSpec y crea
`GY/.runtime/initialization-request.md`. El agente principal debe ejecutar esa
solicitud para completar el analisis semantico y terminar con
`gy.cmd complete-init`.

El agente debe inspeccionar el repositorio y completar:

- `GY/core.md`: proposito, stack, reglas y limites permanentes;
- `GY/current-state.md`: estado actual, riesgos y siguiente accion;
- `GY/commands.md`: comandos reales de instalacion, pruebas y compilacion;
- `GY/knowledge/architecture.md`: mapa inicial de componentes.

Pedido recomendado:

```text
Inicializa GY para este proyecto. Lee el repositorio, AGENTS.md y el checkpoint existente. Completa GY/core.md, GY/current-state.md, GY/commands.md y GY/knowledge/architecture.md. Conserva la informacion util del checkpoint, no cambies codigo y ejecuta gy.cmd validate al terminar.
```

Despues revisa el resultado una vez. A partir de ahi comienza el flujo normal.

## Como migrar un checkpoint.md existente

No copies todo el checkpoint dentro de `current-state.md`. Primero clasificalo:

| Contenido del checkpoint | Destino en GY |
|---|---|
| Proposito y restricciones permanentes | `GY/core.md` |
| Situacion y siguiente paso | `GY/current-state.md` |
| Comandos comprobados | `GY/commands.md` |
| Trabajo pendiente | `GY/tasks/TASK-xxx.md` |
| Decisiones que no deben revertirse | `GY/decisions/DEC-xxx.md` |
| Detalle historico | `GY/archive/` |

Una vez verificada la migracion, el checkpoint puede conservarse como evidencia
historica o dejar de usarse. No conviene mantener dos estados activos porque
terminaran contradiciendose.

## Como funciona la memoria durante el trabajo

La memoria no crece sola por observar conversaciones. Se actualiza cuando el
agente ejecuta el protocolo instalado en `AGENTS.md` o `CLAUDE.md`:

1. Lee el nucleo y el estado actual.
2. Ejecuta `gy.cmd context` con tu solicitud.
3. Recupera tareas y decisiones relacionadas.
4. Modifica el proyecto y ejecuta comprobaciones.
5. Actualiza la tarea y `current-state.md`.
6. Registra una decision si se creo una regla duradera.
7. Ejecuta `gy.cmd validate`.

Esto significa que normalmente no tendras que decir "graba el checkpoint". La
orden ya vive en los archivos de instrucciones del repositorio.

Sin embargo, no existe garantia absoluta: una sesion interrumpida, un agente que
ignore instrucciones o un fallo de energia puede impedir el cierre. Por eso el
estado debe considerarse confirmado cuando el agente informa que ejecuto
`gy.cmd validate` y el cambio aparece en Git.

## Flujo diario recomendado

### Crear una tarea

```bat
gy.cmd new-task -Title "Agregar recuperacion de contrasena" -Tags "auth,email,backend"
```

Tambien puedes pedirselo al agente:

```text
Crea una tarea GY para agregar recuperacion de contrasena. Analiza el alcance y completa resultado y criterios de aceptacion. No implementes todavia.
```

### Continuar trabajando

```text
Continua la tarea activa. Sigue el protocolo GY, implementa, prueba y actualiza el estado al terminar.
```

Si hay varias tareas, utiliza el identificador:

```text
Continua TASK-004. Carga solamente el contexto relacionado, ejecuta las pruebas y actualiza GY.
```

### Terminar una tarea

El agente puede actualizar el archivo directamente o ejecutar:

```bat
gy.cmd close-task -Id TASK-004 -Summary "Recuperacion implementada y probada" -Next "Configurar proveedor de correo en produccion"
gy.cmd validate
```

### Registrar una decision

```bat
gy.cmd new-decision -Title "Usar enlaces de un solo uso" -Summary "Los enlaces expiran en quince minutos y se invalidan al utilizarlos" -Tags "auth,security" -Affects "TASK-004,src/auth"
```

Si la nueva decision reemplaza otra, agrega `-Supersedes "DEC-001"` (varios ids
separados por coma). La anterior queda en el catalogo con su reemplazo registrado
en `supersedes`, sale del contexto y solo se recupera con `-IncludeArchive` o `get`
(que lo muestra con un aviso `> Warning: superseded by ...`). Un ciclo de
reemplazos hace fallar `search` y `context` hasta corregirlo; `validate` lo senala.
Un documento tambien puede vencer con `"expires": "yyyy-MM-dd"` en `catalog.json`.

## Como se despliega el contexto

No se carga todo `GY/` en cada mensaje. El proceso es progresivo:

- L0 y L1: reglas criticas y estado actual; entran siempre.
- L2: tarea y comandos; entran cuando estan relacionados.
- L3: arquitectura y decisiones; se recuperan por etiquetas o relaciones.
- L4: historial; se consulta solamente para obtener evidencia antigua.

`gy.cmd context` genera `GY/.runtime/context-pack.md`. Ese archivo es temporal: se
reconstruye para cada solicitud y no se guarda en Git.

Al final del paquete aparece `- Pack id: <id>`. Si el agente ya recibio ese
paquete en la conversacion, `gy.cmd context -Query "..." -Since <id>` entrega solo
los documentos o secciones nuevos o modificados; los que no cambiaron se listan en
`- Already delivered` y las reglas obligatorias no se repiten. Si no cambio nada,
el paquete indica `- Documents: none`.

Puedes observar la seleccion:

```bat
gy.cmd context -Query "corregir expiracion jwt"
gy.cmd search -Query "jwt expiracion"
```

## Como evita crecer indefinidamente

Al terminar una etapa ejecuta:

```bat
gy.cmd compact -KeepCompleted 5
```

Las cinco tareas terminadas mas recientes permanecen en L2. Las anteriores pasan
a L4. No se borran, pero dejan de competir normalmente por espacio en el contexto.

Limites recomendados:

- `core.md`: menos de 700 tokens;
- `current-state.md`: menos de 900 tokens;
- una tarea: menos de 1.800 tokens;
- una decision: menos de 2.500 tokens, normalmente mucho menos;
- paquete generado: 5.000 tokens por defecto;
- resultado de subagente: hasta `resultTokenCap` en `policies/orchestration.json`
  (800 por defecto). `record-result` rechaza uno mayor sin guardarlo.

## Uso desde el celular y por voz

En Claude Code Remote o Codex Remote puedes dictar:

```text
Continua TASK-004. Lee AGENTS.md, compila el contexto GY necesario, implementa y prueba. Actualiza la memoria al terminar. No hagas merge ni publiques.
```

Para dejar una idea sin implementarla:

```text
Crea una nueva tarea GY con mi idea, relaciona los componentes afectados y deja criterios de aceptacion. No modifiques codigo.
```

La orden de voz no contiene toda la historia. Solo identifica la accion; el agente
recupera el resto desde el repositorio.

## Comandos disponibles

```text
gy.cmd status
gy.cmd init -Idea "idea principal" -InitMode quick -ModelMode uniform
gy.cmd complete-init
gy.cmd search -Query "terminos"
gy.cmd context -Query "solicitud" -Budget 5000
gy.cmd context -Query "solicitud" -Since <pack id>
gy.cmd bench -Query "solicitud uno;solicitud dos" -Budget 5000
gy.cmd route -Agent implementer
gy.cmd task-packet -Id TASK-001 -Agent implementer -Budget 3000
gy.cmd record-result -Id TASK-001 -Agent implementer -Summary "resultado"
gy.cmd new-task -Title "titulo" -Tags "tag1,tag2"
gy.cmd close-task -Id TASK-001 -Summary "resultado" -Next "siguiente paso"
gy.cmd new-decision -Title "titulo" -Summary "decision" -Tags "tags" -Affects "rutas,tareas" -Supersedes "DEC-001"
gy.cmd compact -KeepCompleted 5
gy.cmd validate
```

## Que debes comprobar tu

- Las reglas criticas describen realmente tu proyecto.
- El agente no guardo secretos ni informacion personal en `GY/`.
- `current-state.md` contiene una siguiente accion concreta.
- Las pruebas indicadas por el agente realmente pasaron.
- Los cambios de memoria se incluyen en el mismo commit que el codigo relacionado.

## Mejoras futuras

GY V2 esta preparado para crecer sin cambiar su estructura fundamental. Las
mejoras con mayor valor probable son:

- cierre automatico mediante hooks despues de pruebas o commits;
- deteccion de cambios sin registrar en el estado;
- migracion semantica automatizada de checkpoints antiguos;
- busqueda semantica local para sinonimos del negocio, mas alla de los `aliases`
  del catalogo;
- panel movil con tareas, estado y aprobaciones.

Las metricas de tokens y documentos omitidos ya existen en el comando `bench`.

Conviene incorporar estas mejoras despues de usar GY V2 en un proyecto real y
observar donde aparece friccion. El repositorio piloto dira que automatizacion
produce valor y cual solamente agrega complejidad.
