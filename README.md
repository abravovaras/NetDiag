# NetDiag: Gestión y diagnóstico de red

Herramienta gráfica en PowerShell 7 para consultar, diagnosticar y reparar la conexión de red en Windows. Agrupa en una sola ventana los comandos habituales de red (`ipconfig`, `netsh`, `ping`, `tracert`, etc.) y guarda un registro de cada acción.

## Requisitos

- Windows 10 u 11.
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`). No funciona con Windows PowerShell 5.1.
- Permisos de administrador. El script se eleva solo al abrirse y muestra el aviso UAC.

## Uso

Desde una terminal de PowerShell 7:

```powershell
pwsh -ExecutionPolicy Bypass -File ".\NetDiag.ps1"
```

Reemplaza la ruta por la carpeta donde guardaste el archivo.

## Opciones

**Configuración de red**

1. Consultar adaptadores de red
2. Habilitar DHCP (IPv4 y DNS)
3. Liberar dirección IP *(pide confirmación)*
4. Renovar dirección IP
5. Limpiar caché DNS
6. Reseteo básico de red: reinicia el adaptador principal *(pide confirmación)*

**Diagnóstico de red**

7. Ver dirección IP privada
8. Ver dirección IP pública (consulta `api.ipify.org`, o `ifconfig.me` si falla)
9. Probar gateway
10. Probar resolución DNS
11. Probar conexión a Internet
12. Ejecutar traceroute (pide el destino)
13. Mostrar tabla ARP
14. Mostrar tabla de rutas
15. Diagnóstico automático de red

**Reparación avanzada**

16. Reset de Winsock y TCP/IP *(pide confirmación y requiere reiniciar el equipo)*

**Herramientas adicionales**

17. Probar puerto TCP (pide host y puerto)
18. Conexiones TCP establecidas, con el nombre del proceso
19. Información de la red Wi-Fi activa
20. Servidores DNS configurados

## Registro (log)

Cada acción se guarda en:

```
%LOCALAPPDATA%\NetDiag\Logs\netdiag_AAAAMMDD.log
```

El botón **Abrir carpeta de logs** abre esa carpeta.

## Licencia

Distribuido bajo la licencia MIT. Consulta el archivo [LICENSE](LICENSE).
