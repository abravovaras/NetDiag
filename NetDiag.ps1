#Requires -Version 7.0
<#
    Gestión y Diagnóstico de Red - interfaz gráfica para PowerShell 7
    - Se eleva a administrador automáticamente (aparece el aviso UAC).
    - Muestra la salida en pantalla y la guarda en un log diario.
    - Log: %LOCALAPPDATA%\NetDiag\Logs\netdiag_AAAAMMDD.log
#>

# ---------------------------------------------------------------
# 1. Elevación automática (y apartamento STA, necesario para WinForms)
# ---------------------------------------------------------------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$esSTA   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

if (-not ($esAdmin -and $esSTA)) {
    if (-not $PSCommandPath) {
        Write-Host 'Guarda este código en un archivo .ps1 y ejecútalo desde ahí.' -ForegroundColor Yellow
        Read-Host 'Pulsa Enter para salir' | Out-Null
        return
    }

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    $exe    = (Get-Process -Id $PID).Path

    try {
        if ($esAdmin) { Start-Process -FilePath $exe -ArgumentList $psArgs }                 # ya es admin, solo cambia a STA
        else          { Start-Process -FilePath $exe -ArgumentList $psArgs -Verb RunAs }     # pide UAC
    }
    catch {
        Write-Host 'No se concedieron permisos de administrador. El programa se cerrará.' -ForegroundColor Red
        Read-Host 'Pulsa Enter para salir' | Out-Null
    }
    return
}

# ---------------------------------------------------------------
# 2. Ensamblados y configuración
# ---------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$LogDir  = Join-Path $env:LOCALAPPDATA 'NetDiag\Logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ('netdiag_{0:yyyyMMdd}.log' -f (Get-Date))

$ColorFondo = [System.Drawing.Color]::FromArgb(12, 12, 12)
$ColorPanel = [System.Drawing.Color]::FromArgb(24, 24, 24)
$ColorVerde = [System.Drawing.Color]::FromArgb(0, 230, 0)
$ColorBoton = [System.Drawing.Color]::FromArgb(35, 35, 35)
$ColorBorde = [System.Drawing.Color]::FromArgb(0, 120, 0)

# ---------------------------------------------------------------
# 3. Catálogo de acciones
#    Bloque    : se ejecuta en un hilo aparte (Start-ThreadJob); recibe $t (parámetro opcional)
#    Confirmar : si tiene texto, pide confirmación antes de ejecutar
#    Entrada   : si existe, pide un dato al usuario y lo valida con Patron
# ---------------------------------------------------------------
$Acciones = @(
    # ---- CONFIGURACIÓN DE RED ----
    [pscustomobject]@{
        Id = 1; Seccion = 'CONFIGURACIÓN DE RED'; Nombre = 'Consultar adaptadores de red'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            Get-NetAdapter |
                Format-Table Name, InterfaceDescription, Status, MacAddress, LinkSpeed -AutoSize |
                Out-String -Width 220
        }
    },
    [pscustomobject]@{
        Id = 2; Seccion = 'CONFIGURACIÓN DE RED'; Nombre = 'Habilitar DHCP'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            $ad = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
            if (-not $ad) { return 'No hay adaptadores físicos activos.' }
            netsh interface ip set address name="$($ad.Name)" source=dhcp | Out-String
            netsh interface ip set dns name="$($ad.Name)" source=dhcp | Out-String
            "DHCP habilitado (IPv4 y DNS) en: $($ad.Name)"
        }
    },
    [pscustomobject]@{
        Id = 3; Seccion = 'CONFIGURACIÓN DE RED'; Nombre = 'Liberar dirección IP'
        Confirmar = 'Liberar la IP puede cortar la conexión hasta que se renueve. ¿Continuar?'
        Entrada = $null
        Bloque = { param($t) ipconfig /release | Out-String }
    },
    [pscustomobject]@{
        Id = 4; Seccion = 'CONFIGURACIÓN DE RED'; Nombre = 'Renovar dirección IP'
        Confirmar = $null; Entrada = $null
        Bloque = { param($t) ipconfig /renew | Out-String }
    },
    [pscustomobject]@{
        Id = 5; Seccion = 'CONFIGURACIÓN DE RED'; Nombre = 'Limpiar caché DNS'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            $r = ipconfig /flushdns | Out-String
            Clear-DnsClientCache
            $r + 'Caché DNS limpiada.'
        }
    },
    [pscustomobject]@{
        Id = 6; Seccion = 'CONFIGURACIÓN DE RED'; Nombre = 'Reseteo básico de red'
        Confirmar = 'Se desactivará y reactivará el adaptador principal (la conexión se corta unos segundos). ¿Continuar?'
        Entrada = $null
        Bloque = {
            param($t)
            $ad = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
            if (-not $ad) { return 'No hay adaptadores físicos activos.' }
            Disable-NetAdapter -Name $ad.Name -Confirm:$false
            Start-Sleep -Seconds 3
            Enable-NetAdapter -Name $ad.Name -Confirm:$false
            Start-Sleep -Seconds 8
            "Adaptador '$($ad.Name)' reiniciado."
            ipconfig /renew | Out-String
        }
    },

    # ---- DIAGNÓSTICO DE RED ----
    [pscustomobject]@{
        Id = 7; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Ver dirección IP privada'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike '127.*' } |
                Format-Table InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin -AutoSize |
                Out-String -Width 220
        }
    },
    [pscustomobject]@{
        Id = 8; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Ver dirección IP pública'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            try {
                $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
                "IP pública: $ip"
            }
            catch {
                try   { 'IP pública (alternativa): ' + (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 10) }
                catch { "No se pudo obtener la IP pública: $($_.Exception.Message)" }
            }
        }
    },
    [pscustomobject]@{
        Id = 9; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Probar gateway'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            $ruta = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 |
                    Sort-Object RouteMetric | Select-Object -First 1
            if (-not $ruta) { return 'No hay gateway predeterminado.' }
            "Gateway predeterminado: $($ruta.NextHop)"
            $r = Test-Connection -TargetName $ruta.NextHop -Count 4 -ErrorAction SilentlyContinue
            if ($r) { $r | Select-Object Address, Latency | Format-Table -AutoSize | Out-String }
            else    { 'Sin respuesta del gateway.' }
        }
    },
    [pscustomobject]@{
        Id = 10; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Probar resolución DNS'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            foreach ($dominio in 'www.microsoft.com', 'www.google.com', 'www.cloudflare.com') {
                try {
                    $r = Resolve-DnsName -Name $dominio -Type A -ErrorAction Stop |
                         Where-Object Type -eq 'A' | Select-Object -First 1
                    "[ OK ]  $dominio -> $($r.IPAddress)"
                }
                catch {
                    "[FALLO] $dominio : $($_.Exception.Message)"
                }
            }
        }
    },
    [pscustomobject]@{
        Id = 11; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Probar conexión a Internet'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            $ping = Test-Connection -TargetName '1.1.1.1' -Count 4 -ErrorAction SilentlyContinue
            if ($ping) {
                $media = [math]::Round(($ping | Measure-Object -Property Latency -Average).Average, 1)
                "ICMP 1.1.1.1: OK (latencia media $media ms)"
            }
            else { 'ICMP 1.1.1.1: sin respuesta' }

            $tcp = Test-NetConnection -ComputerName 'www.msftconnecttest.com' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue
            'TCP 80 -> www.msftconnecttest.com: ' + $(if ($tcp) { 'OK' } else { 'FALLO' })
        }
    },
    [pscustomobject]@{
        Id = 12; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Ejecutar traceroute'
        Confirmar = $null
        Entrada = @{ Pregunta = 'Destino (IP o dominio):'; Defecto = '8.8.8.8'; Patron = '^[A-Za-z0-9\.\-]+$' }
        Bloque = { param($t) tracert -d -h 20 $t | Out-String }
    },
    [pscustomobject]@{
        Id = 13; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Mostrar tabla ARP'
        Confirmar = $null; Entrada = $null
        Bloque = { param($t) arp -a | Out-String }
    },
    [pscustomobject]@{
        Id = 14; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Mostrar tabla de rutas'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            Get-NetRoute -AddressFamily IPv4 | Sort-Object RouteMetric |
                Format-Table DestinationPrefix, NextHop, RouteMetric, InterfaceAlias -AutoSize |
                Out-String -Width 220
        }
    },
    [pscustomobject]@{
        Id = 15; Seccion = 'DIAGNÓSTICO DE RED'; Nombre = 'Diagnóstico automático de red'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            $res = [System.Collections.Generic.List[string]]::new()
            function Revisar([string]$nombre, [bool]$ok, [string]$detalle) {
                $marca = if ($ok) { '[ OK ]' } else { '[FALLO]' }
                $res.Add(("{0} {1,-28} {2}" -f $marca, $nombre, $detalle))
            }

            $ad = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
            Revisar 'Adaptador físico activo' ([bool]$ad) $(if ($ad) { $ad.Name } else { 'ninguno' })

            $ipv4 = $null
            if ($ad) {
                $ipv4 = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $ad.ifIndex -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
            }
            Revisar 'IPv4 válida (no APIPA)' ([bool]$ipv4) $(if ($ipv4) { $ipv4.IPAddress } else { 'sin IP o 169.254.x.x' })

            $ruta = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric | Select-Object -First 1
            $gw   = if ($ruta) { $ruta.NextHop } else { $null }
            $gwOk = [bool]($gw -and (Test-Connection -TargetName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue))
            Revisar 'Gateway responde' $gwOk $(if ($gw) { $gw } else { 'sin gateway' })

            $dnsOk = [bool](Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction SilentlyContinue)
            Revisar 'Resolución DNS' $dnsOk 'www.microsoft.com'

            $netOk = [bool](Test-Connection -TargetName '1.1.1.1' -Count 2 -Quiet -ErrorAction SilentlyContinue)
            Revisar 'Conexión a Internet' $netOk '1.1.1.1 (ICMP)'

            $res.Add('')
            if     ($netOk -and -not $dnsOk) { $res.Add('Sugerencia: hay Internet pero falla DNS. Prueba la opción 5 y revisa la 20.') }
            elseif (-not $gwOk)              { $res.Add('Sugerencia: el gateway no responde. Revisa cable o Wi-Fi, o prueba las opciones 3 y 4.') }
            elseif (-not $netOk)             { $res.Add('Sugerencia: sin salida a Internet. Revisa el router o el proveedor.') }
            else                             { $res.Add('Resultado: la red funciona correctamente.') }

            $res -join [Environment]::NewLine
        }
    },

    # ---- REPARACIÓN AVANZADA ----
    [pscustomobject]@{
        Id = 16; Seccion = 'REPARACIÓN AVANZADA'; Nombre = 'Reset de Winsock y TCP/IP'
        Confirmar = 'Esto restablece Winsock y la pila TCP/IP, y requiere REINICIAR el equipo. ¿Continuar?'
        Entrada = $null
        Bloque = {
            param($t)
            netsh winsock reset | Out-String
            netsh int ip reset | Out-String
            ipconfig /flushdns | Out-String
            'Winsock y TCP/IP restablecidos. REINICIA el equipo para aplicar los cambios.'
        }
    },

    # ---- HERRAMIENTAS ADICIONALES (propuestas, fuera de la lista original) ----
    [pscustomobject]@{
        Id = 17; Seccion = 'HERRAMIENTAS ADICIONALES'; Nombre = 'Probar puerto TCP'
        Confirmar = $null
        Entrada = @{ Pregunta = 'Host y puerto (ej: github.com:443):'; Defecto = 'github.com:443'; Patron = '^[A-Za-z0-9\.\-]+:\d{1,5}$' }
        Bloque = {
            param($t)
            $destino, $puerto = $t -split ':'
            $r = Test-NetConnection -ComputerName $destino -Port ([int]$puerto) -WarningAction SilentlyContinue
            $estado = if ($r.TcpTestSucceeded) { 'ABIERTO (conexión correcta)' } else { 'NO ALCANZABLE (cerrado o bloqueado)' }
            "Destino:  $destino"
            "IP:       $($r.RemoteAddress)"
            "Puerto:   $puerto -> $estado"
        }
    },
    [pscustomobject]@{
        Id = 18; Seccion = 'HERRAMIENTAS ADICIONALES'; Nombre = 'Conexiones TCP establecidas'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            $procs = @{}
            Get-Process | ForEach-Object { $procs[[int]$_.Id] = $_.ProcessName }
            Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                Select-Object -First 60 @{ N = 'Proceso'; E = { $procs[[int]$_.OwningProcess] } }, LocalPort, RemoteAddress, RemotePort |
                Sort-Object Proceso |
                Format-Table -AutoSize |
                Out-String -Width 220
        }
    },
    [pscustomobject]@{
        Id = 19; Seccion = 'HERRAMIENTAS ADICIONALES'; Nombre = 'Información Wi-Fi activa'
        Confirmar = $null; Entrada = $null
        Bloque = { param($t) netsh wlan show interfaces | Out-String }
    },
    [pscustomobject]@{
        Id = 20; Seccion = 'HERRAMIENTAS ADICIONALES'; Nombre = 'Servidores DNS configurados'
        Confirmar = $null; Entrada = $null
        Bloque = {
            param($t)
            Get-DnsClientServerAddress -AddressFamily IPv4 |
                Where-Object ServerAddresses |
                Select-Object InterfaceAlias, ServerAddresses |
                Format-Table -AutoSize |
                Out-String -Width 220
        }
    }
)

# ---------------------------------------------------------------
# 4. Funciones auxiliares
# ---------------------------------------------------------------
function New-Boton {
    param([string]$Texto, [int]$X = 0, [int]$Y = 0, [int]$Ancho = 290, [int]$Alto = 30)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Texto
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($Ancho, $Alto)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $ColorBorde
    $b.BackColor = $ColorBoton
    $b.ForeColor = $ColorVerde
    $b.TextAlign = 'MiddleLeft'
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function Set-Ocupado {
    param([bool]$Ocupado)
    foreach ($b in $script:BotonesAccion) { $b.Enabled = -not $Ocupado }
    $form.Cursor = if ($Ocupado) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
}

function Write-Log {
    param([string]$Titulo, [string]$Texto)
    $cabecera = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Titulo
    Add-Content -LiteralPath $LogFile -Value $cabecera, $Texto, ('-' * 70) -Encoding UTF8
}

function Invoke-Accion {
    param($Accion)

    if ($script:Job) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Hay una operación en curso. Espera a que termine.', 'Aviso') | Out-Null
        return
    }

    if ($Accion.Confirmar) {
        $resp = [System.Windows.Forms.MessageBox]::Show($form, $Accion.Confirmar, 'Confirmar acción',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) {
            $script:Estado.Text = 'Acción cancelada.'
            return
        }
    }

    $parametro = $null
    if ($Accion.Entrada) {
        $parametro = [Microsoft.VisualBasic.Interaction]::InputBox($Accion.Entrada.Pregunta, $Accion.Nombre, $Accion.Entrada.Defecto).Trim()
        if (-not $parametro) {
            $script:Estado.Text = 'Acción cancelada.'
            return
        }
        if ($parametro -notmatch $Accion.Entrada.Patron) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Formato no válido.', 'Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
    }

    $script:AccionActual = $Accion
    $script:Job = Start-ThreadJob -ScriptBlock $Accion.Bloque -ArgumentList $parametro

    $script:Salida.AppendText(("`r`n==== {0:HH:mm:ss}  {1} ====`r`n" -f (Get-Date), $Accion.Nombre))
    Set-Ocupado $true
    $script:Estado.Text = "Ejecutando: $($Accion.Nombre)..."
    $script:Timer.Start()
}

# ---------------------------------------------------------------
# 5. Construcción de la interfaz
# ---------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Gestión y Diagnóstico de Red'
$form.Size          = New-Object System.Drawing.Size(1150, 760)
$form.MinimumSize   = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $ColorFondo
$form.ForeColor     = $ColorVerde
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

# Área de salida (Fill: se añade primero)
$script:Salida = New-Object System.Windows.Forms.TextBox
$script:Salida.Multiline   = $true
$script:Salida.ReadOnly    = $true
$script:Salida.ScrollBars  = 'Both'
$script:Salida.WordWrap    = $false
$script:Salida.Dock        = 'Fill'
$script:Salida.BackColor   = [System.Drawing.Color]::Black
$script:Salida.ForeColor   = $ColorVerde
$script:Salida.Font        = New-Object System.Drawing.Font('Consolas', 10)
$form.Controls.Add($script:Salida)

# Panel izquierdo con las acciones
$panelIzq = New-Object System.Windows.Forms.Panel
$panelIzq.Dock       = 'Left'
$panelIzq.Width      = 330
$panelIzq.AutoScroll = $true
$panelIzq.BackColor  = $ColorPanel

$y = 8
$seccionAnterior = ''
$script:BotonesAccion = @()
foreach ($acc in $Acciones) {
    if ($acc.Seccion -ne $seccionAnterior) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text      = $acc.Seccion
        $lbl.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $lbl.ForeColor = $ColorVerde
        $lbl.Location  = New-Object System.Drawing.Point(10, $y)
        $lbl.AutoSize  = $true
        $panelIzq.Controls.Add($lbl)
        $y += 26
        $seccionAnterior = $acc.Seccion
    }

    $btn = New-Boton -Texto ("{0,2}. {1}" -f $acc.Id, $acc.Nombre) -X 10 -Y $y
    $btn.Tag = $acc
    $btn.Add_Click({ param($s, $e) Invoke-Accion -Accion $s.Tag })
    $panelIzq.Controls.Add($btn)
    $script:BotonesAccion += $btn
    $y += 36
}
$form.Controls.Add($panelIzq)

# Barra inferior: estado + botones
$panelInf = New-Object System.Windows.Forms.Panel
$panelInf.Dock      = 'Bottom'
$panelInf.Height    = 46
$panelInf.BackColor = $ColorPanel

$script:Estado = New-Object System.Windows.Forms.Label
$script:Estado.Text      = 'Listo.'
$script:Estado.Dock      = 'Fill'
$script:Estado.Padding   = New-Object System.Windows.Forms.Padding(10, 12, 0, 0)
$script:Estado.ForeColor = $ColorVerde
$panelInf.Controls.Add($script:Estado)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock          = 'Right'
$flow.AutoSize      = $true
$flow.WrapContents  = $false
$flow.Padding       = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
$flow.BackColor     = $ColorPanel

$btnLimpiar = New-Boton -Texto 'Limpiar pantalla' -Ancho 140 -Alto 30
$btnLogs    = New-Boton -Texto 'Abrir carpeta de logs' -Ancho 170 -Alto 30
$btnSalir   = New-Boton -Texto 'Salir' -Ancho 90 -Alto 30
$flow.Controls.AddRange(@($btnLimpiar, $btnLogs, $btnSalir))
$panelInf.Controls.Add($flow)
$form.Controls.Add($panelInf)

$btnLimpiar.Add_Click({ $script:Salida.Clear() })
$btnLogs.Add_Click({ Invoke-Item -LiteralPath $LogDir })
$btnSalir.Add_Click({ $form.Close() })

# Temporizador que comprueba si la acción terminó
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 300
$script:Timer.Add_Tick({
    if (-not $script:Job -or $script:Job.State -in 'Running', 'NotStarted') { return }
    $script:Timer.Stop()

    $texto = (Receive-Job -Job $script:Job 2>&1 | Out-String -Width 220).TrimEnd()
    if (-not $texto) { $texto = '(sin salida)' }

    $script:Salida.AppendText($texto + "`r`n")
    $script:Salida.SelectionStart = $script:Salida.TextLength
    $script:Salida.ScrollToCaret()

    Write-Log -Titulo $script:AccionActual.Nombre -Texto $texto

    Remove-Job -Job $script:Job -Force
    $script:Job = $null
    Set-Ocupado $false
    $script:Estado.Text = "Listo.  Log: $LogFile"
})

# Si cierran la ventana con una acción en curso, se detiene
$form.Add_FormClosing({
    if ($script:Job) {
        Stop-Job -Job $script:Job
        Remove-Job -Job $script:Job -Force
    }
})

# Mensaje inicial
$script:Salida.Text = @"
Gestión y Diagnóstico de Red
Equipo:       $env:COMPUTERNAME
Usuario:      $env:USERNAME (administrador: sí)
Log de hoy:   $LogFile

Selecciona una opción del panel izquierdo.
"@

Write-Log -Titulo 'Sesión iniciada' -Texto "Equipo: $env:COMPUTERNAME  Usuario: $env:USERNAME"

# ---------------------------------------------------------------
# 6. Ejecutar
# ---------------------------------------------------------------
[void]$form.ShowDialog()
$script:Timer.Dispose()
