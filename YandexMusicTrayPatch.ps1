# ============================================================================
#  YandexMusicTrayPatch.ps1
#  Патч десктоп-приложения "Яндекс Музыка" для Windows:
#  крестик (X) в окне теперь ВСЕГДА сворачивает приложение в трей,
#  а не закрывает его (раньше в трей сворачивало только при играющей музыке).
#
#  Как это работает:
#   1) В resources\app.asar меняется условие в функции closeWindow:
#        было:  if (state.player.isPlaying) { скрыть в трей } else { выйти }
#        стало: if (true                   ) { скрыть в трей } else { выйти }
#      Замена строго той же длины — структура asar-архива не меняется.
#   2) В exe-файле выключается fuse "EnableEmbeddedAsarIntegrityValidation"
#      (1 байт), иначе Electron заблокирует запуск из-за проверки целостности.
#
#  Параметры:
#    -InstallDir <путь>  — путь к папке установки (если авто-поиск не сработал)
#    -Undo               — вернуть оригинальные файлы из резервных копий
#    -NoRestart          — не запускать приложение после патча
#
#  Выход из приложения после патча:
#    — правой кнопкой по иконке в трее -> "Выход"
#    — или Alt+F4 (по-прежнему закрывает полностью)
#
#  ВНИМАНИЕ: после авто-обновления приложения патч слетит — просто
#  запустите скрипт ещё раз. Изменение exe делает его цифровую подпись
#  недействительной (это ожидаемо для любого бинарного патча).
# ============================================================================

param(
    [string]$InstallDir = "",
    [switch]$Undo,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

# ----------------------------- константы ------------------------------------
$SENTINEL        = 'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'  # fuse-wire sentinel (@electron/fuses)
$FUSE_INDEX      = 4    # EnableEmbeddedAsarIntegrityValidation
$FUSE_ENABLE     = 49   # '1'
$FUSE_DISABLE    = 48   # '0'
$CHUNK           = 4 * 1024 * 1024

$ANCHOR_PRIMARY  = 'closeWindow = (window) =>'
$ANCHOR_ALT      = 'closeWindow=(window)=>'
$ANCHOR_GENERIC  = 'closeWindow'
$TARGET          = 'state.player.isPlaying'
$VERIFY          = 'toggleWindowVisibility(window, false)'
$MAIN_EXE_NAME   = 'Яндекс Музыка.exe'
$BAK_SUFFIX      = '.bak_traypatch'

$enc = [System.Text.Encoding]::GetEncoding(28591)   # Latin-1: 1 байт = 1 символ

# ----------------------------- утилиты --------------------------------------
function Find-PatternPositions([string]$Path, [string]$Pattern) {
    $result = New-Object System.Collections.Generic.List[long]
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] $CHUNK
        $overlap = $Pattern.Length - 1
        [long]$pos = 0
        while ($true) {
            $read = $fs.Read($buf, 0, $CHUNK)
            if ($read -le 0) { break }
            $s = $enc.GetString($buf, 0, $read)
            $idx = $s.IndexOf($Pattern, [System.StringComparison]::Ordinal)
            while ($idx -ge 0) {
                $result.Add($pos + $idx)
                $idx = $s.IndexOf($Pattern, $idx + 1, [System.StringComparison]::Ordinal)
            }
            if ($read -lt $CHUNK) { break }
            $pos += $read - $overlap
            $fs.Position = $pos
        }
    }
    finally { $fs.Close() }
    return @($result)
}

function Read-Window([string]$Path, [long]$Offset, [int]$Length) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $fs.Position = $Offset
        $buf = New-Object byte[] $Length
        $have = 0
        while ($have -lt $Length) {
            $r = $fs.Read($buf, $have, $Length - $have)
            if ($r -le 0) { break }
            $have += $r
        }
        return $enc.GetString($buf, 0, $have)
    }
    finally { $fs.Close() }
}

function Write-BytesAt([string]$Path, [long]$Offset, [byte[]]$Bytes) {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Position = $Offset
        $fs.Write($Bytes, 0, $Bytes.Length)
        $fs.Flush()
    }
    finally { $fs.Close() }
}

function Test-HasSentinel([string]$Path) {
    return ((Find-PatternPositions $Path $SENTINEL).Count -gt 0)
}

function Get-AppVersion([string]$AsarPath) {
    try {
        $hits = @(Find-PatternPositions $AsarPath '"name":"YandexMusic"')
        if ($hits.Count -eq 0) { return $null }
        $win = Read-Window $AsarPath ([long]$hits[0]) 700
        if ($win -match '"version"\s*:\s*"([0-9][0-9A-Za-z.\-]*)"') { return $Matches[1] }
    } catch { }
    return $null
}

function Write-Ok([string]$msg)   { Write-Host ("  [OK] " + $msg)   -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host ("  [i]  " + $msg)  -ForegroundColor Gray }
function Write-Warn2([string]$msg){ Write-Host ("  [!]  " + $msg)  -ForegroundColor Yellow }
function Write-Err2([string]$msg) { Write-Host ("  [X]  " + $msg)  -ForegroundColor Red }

# ----------------------------- поиск установки ------------------------------
function Resolve-InstallDir {
    if ($InstallDir -ne '') {
        if (-not (Test-Path (Join-Path $InstallDir 'resources\app.asar'))) {
            throw "В указанной папке нет resources\app.asar: $InstallDir"
        }
        return $InstallDir
    }

    # 1) Реестр Windows (деинсталляционные записи)
    $regPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($rp in $regPaths) {
        try {
            $items = @(Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue)
            foreach ($it in $items) {
                if ($null -eq $it -or $null -eq $it.DisplayName) { continue }
                if ($it.DisplayName -like '*Яндекс*Музык*' -or $it.DisplayName -like '*Yandex*Music*') {
                    $loc = $it.InstallLocation
                    if ($loc -and (Test-Path (Join-Path $loc 'resources\app.asar'))) {
                        Write-Info ("Найдено через реестр: " + $loc)
                        return $loc
                    }
                }
            }
        } catch { }
    }

    # 2) Стандартные пути
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += @(
            (Join-Path $env:LOCALAPPDATA 'Programs\ymusic'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Яндекс Музыка'),
            (Join-Path $env:LOCALAPPDATA 'Programs\YandexMusic'),
            (Join-Path $env:LOCALAPPDATA 'ymusic')
        )
    }
    if ($env:ProgramFiles)   { $candidates += (Join-Path $env:ProgramFiles 'Яндекс Музыка') }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86)               { $candidates += (Join-Path $pf86 'Яндекс Музыка') }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'resources\app.asar'))) {
            Write-Info ("Найдено по стандартному пути: " + $c)
            return $c
        }
    }

    throw "Не удалось найти установленную Яндекс Музыку. Запустите скрипт с параметром: -InstallDir `"<путь к папке программы>`""
}

function Resolve-MainExe([string]$Dir) {
    $preferred = Join-Path $Dir $MAIN_EXE_NAME
    if (Test-Path $preferred) { return $preferred }

    # ищем любой exe в корне, кроме деинсталлятора и служебных
    $exes = @(Get-ChildItem -Path $Dir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'Uninstall*' -and $_.Name -notlike 'elevate*' -and $_.Name -notlike 'Update*' } |
        Sort-Object Length -Descending)
    foreach ($e in $exes) {
        if (Test-HasSentinel $e.FullName) { return $e.FullName }
    }
    throw "В папке $Dir не найден основной exe приложения (с fuse-sentinel)."
}

function Stop-AppProcesses([string]$Dir) {
    $stopped = 0
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($Dir, [System.StringComparison]::OrdinalIgnoreCase) })
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $stopped++ } catch { }
        }
    } catch { }
    if ($stopped -gt 0) {
        Write-Ok ("Остановлено процессов: " + $stopped)
        Start-Sleep -Seconds 2
    } else {
        Write-Info "Запущенных процессов приложения не найдено."
    }
}

# ----------------------------- патч asar ------------------------------------
function Patch-Asar([string]$AsarPath) {
    $replacement = 'true' + (' ' * ($TARGET.Length - 4))
    $patchedMark = 'if (true' + (' ' * ($TARGET.Length - 4)) + ')'

    $anchors = @($ANCHOR_PRIMARY, $ANCHOR_ALT, $ANCHOR_GENERIC)
    foreach ($anchor in $anchors) {
        $positions = @(Find-PatternPositions $AsarPath $anchor)
        if ($positions.Count -eq 0) { continue }

        $hits  = @()
        $marks = 0
        foreach ($p in $positions) {
            $win = Read-Window $AsarPath ([long]$p) 400
            if ($win.IndexOf($patchedMark, [System.StringComparison]::Ordinal) -ge 0) { $marks++; continue }
            $ti = $win.IndexOf($TARGET, [System.StringComparison]::Ordinal)
            if ($ti -lt 0) { continue }
            $after = $win.Substring($ti + $TARGET.Length)
            if ($after.IndexOf($VERIFY, [System.StringComparison]::Ordinal) -lt 0) { continue }
            $hits += ,@($p, $ti)
        }

        if ($marks -gt 0 -and $hits.Count -eq 0) { return 'already' }
        if ($hits.Count -eq 1) {
            $abs = [long]$hits[0][0] + [long]$hits[0][1]
            Write-BytesAt $AsarPath $abs ($enc.GetBytes($replacement))
            return 'patched'
        }
        if ($hits.Count -gt 1) { throw ("Найдено несколько (" + $hits.Count + ") мест для патча — прекращено из соображений безопасности.") }
    }

    # отдельная проверка: возможно, уже пропатчено (маркер мог быть за пределами окна анкора)
    $markerHits = @(Find-PatternPositions $AsarPath $patchedMark)
    if ($markerHits.Count -gt 0) { return 'already' }

    $ver = Get-AppVersion $AsarPath
    $verMsg = ''
    if ($ver) { $verMsg = " (версия приложения: " + $ver + ")" }
    throw ("Не найден код closeWindow в app.asar" + $verMsg + ". Возможно, приложение обновилось и код изменился.")
}

# ----------------------------- патч fuse в exe ------------------------------
function Patch-ExeFuse([string]$ExePath) {
    $positions = @(Find-PatternPositions $ExePath $SENTINEL)
    if ($positions.Count -eq 0) {
        throw "В exe не найден fuse-sentinel. Файл: $ExePath"
    }
    $flipped = 0
    $already = 0
    foreach ($p in $positions) {
        $wireStart = [long]$p + $SENTINEL.Length
        $hdr = Read-Window $ExePath $wireStart 2
        if ($hdr.Length -lt 2) { throw "Не удалось прочитать fuse-wire в exe." }
        $version = [int][char]$hdr[0]
        $count   = [int][char]$hdr[1]
        if ($version -ne 1) { throw ("Неизвестная версия fuse-wire: " + $version) }
        if ($count -lt ($FUSE_INDEX + 1)) { throw ("Fuse-wire короче ожидаемого: " + $count) }
        $fuseOffset = $wireStart + 2 + $FUSE_INDEX
        $cur = Read-Window $ExePath $fuseOffset 1
        $b = [int][char]$cur[0]
        if ($b -eq $FUSE_DISABLE) { $already++; continue }
        if ($b -ne $FUSE_ENABLE) { throw ("Неожиданное состояние fuse-байта: " + $b) }
        Write-BytesAt $ExePath $fuseOffset ([byte[]]@($FUSE_DISABLE))
        $flipped++
    }
    Write-Info ("Sentinel'ов в exe: " + $positions.Count + ", выключено: " + $flipped + ", уже было выключено: " + $already)
    if ($flipped -gt 0) { return 'patched' }
    return 'already'
}

# ----------------------------- бэкап ----------------------------------------
function Backup-File([string]$Path) {
    $bak = $Path + $BAK_SUFFIX
    if (Test-Path $bak) {
        Write-Info ("Резервная копия уже есть: " + (Split-Path $bak -Leaf))
    } else {
        [System.IO.File]::Copy($Path, $bak, $false)
        Write-Ok ("Резервная копия: " + (Split-Path $bak -Leaf))
    }
    return $bak
}

# ============================================================================
#                                ГЛАВНЫЙ КОД
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
if ($Undo) {
    Write-Host "  Яндекс Музыка — трей-патч : ОТМЕНА (возврат оригиналов)"  -ForegroundColor Cyan
} else {
    Write-Host "  Яндекс Музыка — трей-патч (крестик = свернуть в трей)"   -ForegroundColor Cyan
}
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

try {
    # --- 1. Поиск установки ---
    Write-Host "[1/5] Поиск установленного приложения..." -ForegroundColor White
    $dir = Resolve-InstallDir
    $asarPath = Join-Path $dir 'resources\app.asar'
    $exePath  = Resolve-MainExe $dir
    Write-Ok ("Папка: " + $dir)
    Write-Ok ("Asar : " + $asarPath)
    Write-Ok ("Exe  : " + $exePath)
    $ver = Get-AppVersion $asarPath
    if ($ver) { Write-Info ("Версия приложения: " + $ver) }

    # --- 2. Остановка приложения ---
    Write-Host ""
    Write-Host "[2/5] Остановка приложения (если запущено)..." -ForegroundColor White
    Stop-AppProcesses $dir

    if ($Undo) {
        # --- отмена патча ---
        Write-Host ""
        Write-Host "[3/5] Восстановление из резервных копий..." -ForegroundColor White
        $ok = $true
        foreach ($f in @($asarPath, $exePath)) {
            $bak = $f + $BAK_SUFFIX
            if (Test-Path $bak) {
                [System.IO.File]::Copy($bak, $f, $true)
                Remove-Item $bak -Force
                Write-Ok ("Восстановлено: " + (Split-Path $f -Leaf))
            } else {
                Write-Warn2 ("Резервная копия не найдена для " + (Split-Path $f -Leaf))
                $ok = $false
            }
        }
        Write-Host ""
        if ($ok) {
            Write-Host "  Патч отменён, оригинальные файлы возвращены." -ForegroundColor Green
        } else {
            Write-Host "  Отмена завершена с предупреждениями (см. выше)." -ForegroundColor Yellow
        }
    }
    else {
        # --- 3. Бэкап ---
        Write-Host ""
        Write-Host "[3/5] Создание резервных копий..." -ForegroundColor White
        $null = Backup-File $asarPath
        $null = Backup-File $exePath

        # --- 4. Патч asar ---
        Write-Host ""
        Write-Host "[4/5] Патч app.asar (крестик -> трей)..." -ForegroundColor White
        $r1 = Patch-Asar $asarPath
        if ($r1 -eq 'already') { Write-Warn2 "app.asar уже был пропатчен — пропускаю." }
        else { Write-Ok "app.asar пропатчен (замена строго той же длины)." }

        # --- 5. Патч exe (fuse) ---
        Write-Host ""
        Write-Host "[5/5] Выключение проверки целостности asar в exe..." -ForegroundColor White
        $r2 = Patch-ExeFuse $exePath
        if ($r2 -eq 'already') { Write-Warn2 "fuse уже был выключен — пропускаю." }
        else { Write-Ok "fuse EnableEmbeddedAsarIntegrityValidation выключен (1 байт)." }

        # --- финальная проверка ---
        Write-Host ""
        Write-Host "Проверка результата..." -ForegroundColor White
        $chk = Read-Window $asarPath ([long]@(Find-PatternPositions $asarPath 'closeWindow')[0]) 400
        if ($chk -match 'if \(true +\)') { Write-Ok "Код closeWindow: условие заменено на true." }
        else { Write-Warn2 "Не удалось подтвердить патч — проверьте вручную." }

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  ГОТОВО! Теперь крестик всегда сворачивает в трей."           -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Как выйти из приложения полностью:"                            -ForegroundColor White
        Write-Host "   - иконка в трее (правая кнопка) -> 'Выход'"
        Write-Host "   - или закрыть окно через Alt+F4"
        Write-Host ""
        Write-Host "  Полезно знать:"                                                 -ForegroundColor White
        Write-Host "   - после обновления приложения патч слетит - запустите скрипт ещё раз"
        Write-Host "   - отмена:  YandexMusicTrayPatch.ps1 -Undo"
        Write-Host "   - цифровая подпись exe изменена (нормально для бинарного патча)"
    }

    # --- перезапуск ---
    if (-not $NoRestart) {
        Write-Host ""
        Write-Host "Запуск Яндекс Музыки..." -ForegroundColor White
        try {
            if ($Undo) {
                # после отмены не запускаем автоматически
            } else {
                Start-Process -FilePath $exePath -WorkingDirectory $dir
                Write-Ok "Приложение запущено."
            }
        } catch { Write-Warn2 ("Не удалось запустить: " + $_.Exception.Message) }
    }
}
catch {
    Write-Host ""
    Write-Err2 $_.Exception.Message
    Write-Host ""
    Write-Host "  Подсказки:" -ForegroundColor Yellow
    Write-Host "   - запустите от имени администратора (если приложение ставилось для всех)"
    Write-Host "   - укажите папку вручную:  .\YandexMusicTrayPatch.ps1 -InstallDir `"C:\Users\<имя>\AppData\Local\Programs\ymusic`""
    Write-Host "   - если PowerShell блокирует запуск:  powershell -ExecutionPolicy Bypass -File .\YandexMusicTrayPatch.ps1"
    exit 1
}
