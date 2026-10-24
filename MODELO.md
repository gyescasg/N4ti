# Modelo de recuperacion

N4ti conserva la compatibilidad con GY. Las referencias a `GY/` en proyectos
existentes siguen siendo validas; los proyectos nuevos usan `N4ti/`. Los
checkpoints de `save` se recuperan explicitamente con `resume`, no se agregan
automaticamente a todos los paquetes de contexto.

## Objetivo

Construir el paquete de contexto mas pequeno que conserve las restricciones y
evidencia necesarias para resolver una solicitud.

Para cada documento `d` y consulta `q`, N4ti calcula:

```text
relevancia(u,q) = suma por termino t de idf(t) * (50 * en_metadatos
                                                 + 35 * en_titulo
                                                 + 10 * en_contenido)
idf(t)          = ln(1 + (N - n(t) + 0.5) / (n(t) + 0.5))
score(u,q)      = relevancia + prioridad + estado_activo - 3 * nivel - costo_por_tokens
```

`u` es una unidad recuperable (documento entero o seccion), `N` el total de
unidades y `n(t)` las unidades que contienen el termino. Un termino presente en
casi todas las unidades pesa poco; uno especifico pesa mucho. Es el IDF de BM25,
sin frecuencia de termino: cada termino cuenta una vez por campo.

Los metadatos incluyen ID, tipo, ruta, etiquetas y `affects`; el titulo es el
primer encabezado Markdown o el titulo del catalogo (y el de la seccion). El
titulo puede aportar tambien una coincidencia de contenido. Son ponderaciones
deterministas, no una medida de calidad semantica ni un modelo entrenado.

Una unidad opcional entra al paquete solo si su relevancia alcanza el 25% de la
mejor unidad opcional; las demas coincidencias pasan al indice `Not included`.

La comparacion normaliza Unicode, mayusculas y tildes: `configuracion` puede
recuperar `configuración`.

El catalogo puede declarar `aliases`: grupos de terminos equivalentes, por
ejemplo `["architecture", "arquitectura"]`. Cada termino de la consulta se busca
tambien con sus equivalentes, y un termino junto a su equivalente cuenta una sola
vez. La plantilla trae grupos espanol/ingles para sus etiquetas; los proyectos
existentes pueden agregarlos a mano en `catalog.json`. Un `aliases` mal formado
hace fallar la recuperacion y `validate` sin escribir nada. Es una tabla
determinista, no un modelo de sinonimos. El texto original se lee como UTF-8 y se conserva en
el paquete; no se reescriben los documentos.

Cada documento del catalogo puede declarar `supersedes` (lista de ids que
reemplaza) y `expires` (fecha local `yyyy-MM-dd`; sigue vigente ese dia y vence
al dia siguiente). Un documento reemplazado por otro vigente, o vencido, se trata
como historial: no entra en `search`, `context`, `bench` ni `task-packet`, ni
aparece en el indice `Not included`; `-IncludeArchive` lo recupera y `get` lo
sigue mostrando con una linea `> Warning:` bajo el encabezado (reemplazado por,
vencido el, o catalogo con valores invalidos). Un documento obligatorio
reemplazado o vencido es un error.
`validate` informa destinos inexistentes, autorreferencias, ciclos y fechas mal
formadas. Un ciclo de `supersedes` (A reemplaza a B y B a A) ocultaria a todos sus
documentos, asi que tambien hace fallar la recuperacion sin escribir nada. Los catalogos sin estos campos funcionan igual que antes.

Los valores de prioridad son `critical=40`, `high=20`, `normal=8` y `low=0`.
`alwaysLoad` agrega 1000 puntos. Un documento `critical` o `alwaysLoad` es
obligatorio. Si no cabe, la generacion falla antes de escribir la salida:
no se sacrifican reglas ni se excede silenciosamente el presupuesto.

## Invariantes

- L0 y L1 representan el estado minimo recuperable.
- Los paquetes generados incluyen los documentos `critical` y `alwaysLoad`.
- Los paquetes de subagentes incluyen el contenido completo de la tarea asignada.
- Un resultado de subagente no supera `resultTokenCap` (`policies/orchestration.json`,
  800 por defecto): `record-result` lo rechaza sin escribir y `validate` solo advierte
  sobre resultados previos que lo superan.
- El catalogo solo puede apuntar a archivos dentro de la memoria seleccionada.
- L4 no puede usar `alwaysLoad` ni prioridad `critical`; una contradiccion falla explicitamente.
- Los IDs del catalogo son unicos.
- Ningun documento se elimina al compactar; solo cambia de nivel y ruta.

## Presupuesto

N4ti estima un token por cada cuatro caracteres y usa 5.000 tokens por defecto.
Primero reserva las reglas obligatorias y, en `task-packet`, la tarea asignada.
Despues evalua documentos relevantes en orden de puntuacion. La estimacion cubre
la salida completa, incluyendo consulta, encabezados, contrato y el propio contador.
Si el contenido obligatorio no cabe, el comando indica el minimo estimado y falla
sin reemplazar un paquete previo. El limite sigue siendo una estimacion, no un
conteo exacto con el tokenizador del modelo.

El paquete se ordena de lo estable a lo variable: titulo, documentos obligatorios
en orden fijo (nivel e ID), la tarea asignada, los documentos opcionales y al
final la consulta, el contador y la lista de documentos. No lleva fecha de
generacion. Asi, paquetes de solicitudes distintas comparten un prefijo identico
que los hosts con cache de prompt pueden reutilizar. El protocolo instalado ya no
pide leer `core.md`, el estado ni las politicas por separado: vienen en el paquete.

Los documentos opcionales con contenido identico al ya seleccionado se omiten.
La comparacion distingue mayusculas y saltos de linea internos; solo ignora los
espacios exteriores que la salida ya elimina. No se resumen ni fusionan documentos
parecidos. Los documentos obligatorios conservan todas sus identidades, incluso
si repiten contenido. `search` sigue mostrando todas las fuentes coincidentes.

## Secciones e indice

Los documentos opcionales de mas de 200 tokens estimados se recuperan por
seccion: cada titulo `## ` (fuera de bloques de codigo) es una unidad `ID#slug`
que se puntua con los metadatos del documento, su titulo y el texto de la
seccion. El texto previo al primer `## ` es `ID#intro` cuando tiene algo mas que
el titulo. Si entran todas las secciones de un documento, se emite entero como
un solo bloque. Los documentos obligatorios y la tarea asignada nunca se parten.

Las coincidencias que no caben se listan en `## Not included` con su ID, tokens y
titulo, mientras el indice entre en el presupuesto. Es un unico nivel: el agente
pide lo que necesita con `get`, que es de solo lectura.

```powershell
.\n4ti.cmd get -Id ARCHITECTURE
.\n4ti.cmd get -Id ARCHITECTURE#datos
```

## Paquetes delta

Cada `context` guarda `.runtime/packs/<id>.json` con un SHA-256 por unidad
entregada (documento o seccion, incluidos los obligatorios) e imprime el id al
final del paquete, en la zona variable, sin tocar el prefijo estable. El id se
deriva solo de los IDs y hashes de las unidades: la misma entrada da el mismo id,
sin reloj ni Git. Se conservan los ultimos 20 manifiestos (la fecha del archivo
solo decide cuales se borran); si otra ejecucion ya borro o tiene abierto uno, la
limpieza lo omite sin fallar.

`context -Since <id>` hace la misma seleccion y presupuesto que un `context`
normal, pero solo emite unidades nuevas o modificadas; las demas se listan por ID
en `- Already delivered`; si nada cambio, el paquete dice `- Documents: none`. Una seccion cuenta como entregada si antes se entrego su
documento entero sin cambios. El manifiesto del delta acumula lo anterior y lo
nuevo, asi que los deltas se encadenan. Un id desconocido falla sin escribir
nada. `bench` calcula el mismo id y la misma linea final, pero no guarda
manifiestos. La linea del id cuenta en el estimado y en el presupuesto (unos 7
tokens estimados), como el resto de la salida.

## Archivo historico explicito

`search`, `context` y `task-packet` excluyen L4 antes de leer sus archivos, salvo
que se indique `-IncludeArchive`. Un `task-packet -Id TASK-001` que asigna
explicitamente una tarea archivada conserva esa tarea, pero no admite por ello
todo el historial relacionado. El archivo permanece intacto en disco.

```powershell
.\n4ti.cmd search -Query "decision anterior" -IncludeArchive
.\n4ti.cmd context -Query "evidencia historica" -IncludeArchive -Budget 5000
```

## Por que no usa embeddings todavia

En codigo, rutas, IDs, nombres de funciones y mensajes de error, la coincidencia
lexical suele ser mas precisa y es gratuita. Los embeddings locales son una mejora
posterior para sinonimos y lenguaje de negocio; deben complementar etiquetas y
relaciones, no sustituirlas.

## Medidas para evitar olvidos

La recuperacion probabilistica no garantiza recordar todo. El sistema combina:

- carga determinista de restricciones criticas;
- relaciones `tags` y `affects`;
- IDs estables de tareas y decisiones;
- estado actual explicitamente actualizado;
- pruebas y validacion como evidencia final.
