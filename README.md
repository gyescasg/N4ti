# N4ti

Sistema ligero de memoria, planificacion y orquestacion para proyectos de
software. Funciona con Codex, Claude Code y cualquier agente que pueda leer el
repositorio. No requiere API ni servicios externos.

Para entender el flujo diario y que partes son automaticas, consulta
[`MANUAL-DE-USO.md`](MANUAL-DE-USO.md).

Para verificar el paquete completo sin tocar un proyecto real:

```bat
Test-N4ti.cmd
```

## Instalacion

Guia paso a paso para instalar, actualizar y usar: `INSTALACION.md`.

Desde PowerShell, situado en este directorio:

```bat
Install-N4ti.cmd "C:\ruta\al\proyecto"
```

El instalador:

- crea `N4ti/` con el estado y el catalogo inicial en proyectos nuevos;
- conserva `GY/` si el proyecto ya lo utiliza, sin mover ni duplicar su memoria;
- instala `n4ti.cmd` y `n4ti.ps1`, con `gy.cmd` y `gy.ps1` como acceso compatible;
- agrega instrucciones breves a `AGENTS.md` y `CLAUDE.md` sin reemplazarlos;
- excluye `.runtime/` de la carpeta de memoria seleccionada en `.gitignore`;
- es idempotente: se puede volver a ejecutar para actualizar herramientas.

Inicializa el proyecto con su idea principal:

```powershell
.\n4ti.cmd init -Idea "Que quieres construir, para quien y con que resultado" -InitMode guided -ModelMode uniform
```

Luego pide al agente principal que ejecute
`N4ti/.runtime/initialization-request.md`. El agente completa la interpretacion del
producto, migra checkpoints y propone tecnologia y staff sin cambiar codigo. Al
terminar ejecuta `n4ti.cmd complete-init`; el comando rechaza campos pendientes.

En proyectos existentes, sustituya `N4ti/` por `GY/` en los ejemplos de rutas.
Si ambas carpetas existen, el instalador y el CLI se detienen antes de escribir;
no intentan fusionar memorias. Un catalogo ausente o invalido tambien exige
reparacion explicita. `Install-GY.cmd` y `Test-GY.cmd` siguen siendo compatibles.
Una reinstalacion normal preserva la memoria; `-ForceTemplates` es una opcion
destructiva heredada que reemplaza plantillas y no debe usarse para actualizar datos.

## Flujo diario

```powershell
# Ver el estado corto
.\n4ti.cmd status

# Consultar la asignacion sugerida para un rol
.\n4ti.cmd route -Agent architect

# Crear una tarea
.\n4ti.cmd new-task -Title "Corregir expiracion del login" -Tags "auth,jwt,backend"

# Construir el contexto selectivo para una peticion
.\n4ti.cmd context -Query "continuar login y corregir expiracion jwt"

# Buscar conocimiento sin construir el paquete
.\n4ti.cmd search -Query "jwt expiracion"

# Incluir historia archivada solo cuando se necesita
.\n4ti.cmd search -Query "jwt expiracion anterior" -IncludeArchive

# Medir el costo de los paquetes sin escribir nada (varias consultas con ;)
.\n4ti.cmd bench -Query "login jwt;arquitectura" -Budget 5000

# Comprobar estructura, enlaces y limites
.\n4ti.cmd validate

# Cerrar una tarea y dejar el siguiente paso
.\n4ti.cmd close-task -Id TASK-001 -Summary "Expiracion corregida y pruebas verdes" -Next "Revisar refresh token"

# Registrar una decision que debe sobrevivir a las conversaciones
.\n4ti.cmd new-decision -Title "Usar refresh tokens rotativos" -Summary "Rotar en cada uso" -Tags "auth,security" -Affects "src/auth,TASK-001"

# Reemplazar una decision anterior: DEC-001 deja de entrar en el contexto
.\n4ti.cmd new-decision -Title "Usar sesiones cortas" -Summary "Sin refresh tokens" -Supersedes "DEC-001"

# Mover tareas antiguas terminadas a L4
.\n4ti.cmd compact -KeepCompleted 5

# Preparar trabajo aislado para un subagente
.\n4ti.cmd task-packet -Id TASK-001 -Agent implementer -Budget 3000

# Registrar la evidencia devuelta por el subagente
.\n4ti.cmd record-result -Id TASK-001 -Agent implementer -Summary "Cambio terminado" -Files "src/app.ts" -Tests "app.test.ts"
```

El contexto compilado queda en `N4ti/.runtime/context-pack.md`. Esa carpeta es
temporal y no se versiona.

Cada paquete termina con `- Pack id: <id>`. En los siguientes turnos de la misma
conversacion, `-Since` entrega solo lo nuevo o modificado; lo demas aparece en
`- Already delivered` por ID (`- Documents: none` si no cambio nada):

```powershell
.\n4ti.cmd context -Query "continuar login" -Since 8bce57c84aca
```

## Guardar y retomar el avance

```powershell
.\n4ti.cmd save -Summary "Login implementado; revision pendiente" -Next "Probar expiracion" -Id TASK-001 -Files "src/auth.ts" -Tests "Pruebas locales informadas"
.\n4ti.cmd resume -Id TASK-001 -Budget 3000
```

Sin `-Id`, `save` guarda un checkpoint general del proyecto. `resume` sin filtro
muestra el ultimo checkpoint de ese proyecto; con `-Id` muestra el ultimo de esa
tarea. `-Summary` y `-Next` son obligatorios. Tambien se acepta `-Risks`.
Archivos, pruebas y riesgos son listas separadas por comas; no se leen archivos ni
se ejecutan pruebas. No guarde credenciales ni datos personales: no existe un
detector automatico de secretos.

Cada guardado crea un JSON unico en `N4ti/checkpoints/` mediante publicacion
atomica. Conserva el texto literal y marca la evidencia como `reported`, no
verificada. No cambia la tarea activa ni el estado canonico. `resume` no escribe
archivos y falla si el checkpoint completo no cabe en el presupuesto estimado.
Los checkpoints no se cargan automaticamente en cada consulta y no capturan
conversaciones. Un checkpoint corrupto requiere reparacion antes de reanudar.

## Uso con Codex o Claude Code

Pedido corto recomendado desde PC o celular:

```text
Lee AGENTS.md y sigue el protocolo N4ti. Trabaja en TASK-001. Valida y actualiza la memoria al terminar.
```

Si el agente no ejecuta automaticamente el compilador:

```text
Ejecuta .\n4ti.cmd context -Query "mi solicitud" y usa N4ti/.runtime/context-pack.md.
```

## Niveles

| Nivel | Contenido | Carga |
|---|---|---|
| L0 | reglas y mapa | siempre |
| L1 | estado actual | siempre |
| L2 | tarea activa y comandos | por tarea |
| L3 | decisiones y conocimiento | por relevancia |
| L4 | archivo y evidencia | solo para comprobar |

El presupuesto predeterminado es 5.000 tokens estimados. El contador incluye
todo el paquete generado: consulta, encabezados, contrato y documentos.
Los documentos `critical` o `alwaysLoad` son obligatorios; `task-packet` tambien
reserva el contenido completo de la tarea. Si estos elementos no caben, el comando
falla sin crear ni reemplazar la salida. Aumente `-Budget` o reduzca los documentos
obligatorios; las reglas no se eliminan silenciosamente para ahorrar tokens.

### Recuperacion selectiva

- La busqueda admite tildes y Unicode sin modificar el texto guardado.
- Titulos, etiquetas y rutas pesan mas que menciones aisladas en el contenido.
- Los documentos opcionales identicos se incluyen una sola vez; las reglas
  obligatorias nunca se eliminan por deduplicacion. `search` conserva las fuentes.
- El archivo L4 solo se consulta con `-IncludeArchive` en `search`, `context` o
  `task-packet`. Asignar una tarea archivada por ID incluye esa tarea, no todo L4.

El ahorro depende de los documentos y la consulta. No se afirma un porcentaje
general ni se usan embeddings o servicios adicionales. `bench` mide cada caso:
construye los mismos paquetes que `context`, sin escribirlos, y reporta tokens
estimados, documentos omitidos, el costo obligatorio por paquete y el prefijo
comun entre paquetes. La estimacion (caracteres / 4) no depende de ningun modelo.

### Integridad del avance

`record-result` exige una tarea existente y un agente habilitado. Cada resultado
tiene un identificador de archivo unico, incluso cuando varios se guardan en el
mismo segundo, y conserva el estado `reported`: guardarlo no demuestra que las
pruebas hayan pasado. Un resultado que supera `resultTokenCap` (en
`policies/orchestration.json`, 800 tokens estimados por defecto) se rechaza sin
escribir nada; `validate` solo advierte sobre resultados previos mas grandes.
`close-task` rechaza documentos que no sean tareas y solo
actualiza el estado actual cuando cierra la tarea activa.

`Test-N4ti.cmd` ejecuta el recorrido heredado y las regresiones de presupuesto,
instalacion compatible, checkpoints y recuperacion selectiva, en proyectos temporales.

## Limites actuales

La estimacion de tokens usa aproximadamente cuatro caracteres por token. Es
suficiente para controlar el tamano, pero no sustituye al tokenizador del modelo.
La busqueda es lexical con metadatos ponderados y pesos IDF; no recorre un grafo
de relaciones. Solo reconoce como equivalentes los terminos declarados en los
`aliases` del catalogo; no entiende sinonimos por si sola. Los documentos
opcionales grandes se entregan por secciones `##` completas, nunca como
fragmentos resumidos. En un paquete delta, un documento entregado completo se
reenvia entero aunque solo cambie una de sus secciones.
Las escrituras de tarea, catalogo y estado aun no forman una transaccion unica;
no hay recuperacion automatica de esas operaciones frente a interrupciones.
La publicacion atomica de `save` protege solo su checkpoint individual.

## Licencia

N4ti se distribuye bajo **MIT con la condicion Commons Clause** (ver `LICENSE`).
Es codigo disponible, no open source en el sentido de la OSI:

- puede usarse, copiarse y modificarse, tambien dentro de trabajo profesional;
- no puede venderse, ni el original ni versiones modificadas, como producto o
  servicio cuyo valor dependa total o sustancialmente de N4ti;
- toda copia o derivado debe conservar `LICENSE` y mencionar el proyecto de
  origen: N4ti, https://github.com/gyescasg/N4ti.
