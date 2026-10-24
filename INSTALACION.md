# Instalar o actualizar N4ti

Guia corta para instalar N4ti en un proyecto nuevo, actualizar un proyecto que ya
lo usa y aprovechar el ahorro de tokens en el trabajo diario. Requiere Windows
PowerShell 5.1; no necesita modelos, APIs ni dependencias adicionales.

## Requisitos

- Windows con PowerShell 5.1.
- Una copia de este repositorio:

```powershell
git clone https://github.com/gyescasg/N4ti.git
cd N4ti
```

Si ya lo tiene clonado, actualicelo antes de instalar:

```powershell
git pull
```

## A. Proyecto nuevo

```powershell
.\Install-N4ti.cmd "C:\ruta\al\proyecto"

cd "C:\ruta\al\proyecto"
.\n4ti.cmd init -Idea "Que se construye, para quien y con que resultado" -InitMode guided -ModelMode uniform
```

Luego pida al agente principal (Claude Code, Codex u otro) que ejecute
`N4ti/.runtime/initialization-request.md`. Al terminar, el agente ejecuta
`.\n4ti.cmd complete-init`. Compruebe la instalacion con:

```powershell
.\n4ti.cmd validate
```

## B. Proyecto que ya usa N4ti

```powershell
cd C:\ruta\a\N4ti
git pull
.\Install-N4ti.cmd "C:\ruta\al\proyecto"

cd "C:\ruta\al\proyecto"
.\n4ti.cmd validate
```

Se actualiza:

- el CLI (`n4ti.ps1`, `gy.ps1` y sus `.cmd`);
- el bloque N4ti dentro de `AGENTS.md` y `CLAUDE.md`; el resto de esos archivos
  no se modifica.

Se conserva toda la memoria: catalogo, tareas, decisiones y politicas.

Precauciones:

- **No use `-ForceTemplates`.** Reemplaza las plantillas y puede perder datos.
- Si el proyecto usa `GY/` en lugar de `N4ti/`, el instalador la respeta. Si
  existen ambas carpetas, se detiene antes de escribir.
- Un catalogo existente no recibe los alias espanol/ingles de la plantilla. Para
  usarlos, copie el bloque `"aliases"` de `template/GY/catalog.json` a su
  `catalog.json` y ejecute `validate`.
- `resultTokenCap` es opcional: si falta, vale 800. Para otro tope agregue, por
  ejemplo, `"resultTokenCap": 600` en `policies/orchestration.json`.

## C. Uso diario

```powershell
.\n4ti.cmd context -Query "continuar login y corregir expiracion jwt"
```

La ultima linea del paquete muestra su identificador, por ejemplo
`- Pack id: 8bce57c84aca`. En los turnos siguientes de la misma conversacion use
`-Since` para recibir solo lo nuevo o modificado:

```powershell
.\n4ti.cmd context -Query "siguiente paso del login" -Since 8bce57c84aca
```

En una conversacion nueva ejecute `context` sin `-Since`.

Para medir el costo de un paquete sin escribir nada:

```powershell
.\n4ti.cmd bench -Query "login jwt;arquitectura" -Budget 5000
```

## Problemas frecuentes

| Mensaje | Que hacer |
|---|---|
| `Unknown pack id` | El manifiesto ya no existe (se guardan los ultimos 20). Ejecute `context` sin `-Since`. |
| `Supersedes cycle: ...` | Dos o mas documentos se reemplazan entre si. Corrija `supersedes` en el catalogo y ejecute `validate`. |
| `... exceeds resultTokenCap ...` | El resultado del subagente es demasiado largo. Resumalo; no se escribio nada. |
| `> Warning: superseded by ...` en `get` | El documento fue reemplazado; use el documento indicado. |

Mas detalle en `README.md`, `MANUAL-DE-USO.md` y `MODELO.md`.
