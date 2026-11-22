# Wifi-diagnose voor Windows
# Uitvoeren: rechtsklik > "Uitvoeren met PowerShell", of in PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\wifi-check-windows.ps1

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'  # voortgangsbalk maakt downloads in PowerShell 5.1 veel trager
$problemen = @()
function Kop($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

# 1. Verbinding: signaal, band, kanaal, snelheid
Kop "Huidige wifi-verbinding"
$if = netsh wlan show interfaces
$if | Write-Host
$signaal = ($if | Select-String '^\s*(Signal|Signaal)\s*:\s*(\d+)%').Matches.Groups[2].Value
$kanaal  = ($if | Select-String '^\s*(Channel|Kanaal)\s*:\s*(\d+)').Matches.Groups[2].Value
$radio   = ($if | Select-String '^\s*(Radio type|Radiotype)\s*:\s*(.+)$').Matches.Groups[2].Value
$ssid    = ($if | Select-String '^\s*SSID\s*:\s*(.+)$').Matches.Groups[1].Value
if ($signaal -and [int]$signaal -lt 60) { $problemen += "Zwak signaal ($signaal%). Ga dichter bij de router zitten, haal obstakels weg of overweeg een mesh/repeater." }
if ($kanaal -and [int]$kanaal -le 14) { $problemen += "Je zit op 2,4 GHz (kanaal $kanaal). Dat is trager en drukker; gebruik het 5 GHz-netwerk als je dat hebt." }
if ($radio -match '802\.11[bg]$|802\.11n$') { $problemen += "Oude wifi-standaard ($radio). De router of netwerkkaart beperkt je snelheid." }

# 2. Drukte: andere netwerken op hetzelfde kanaal
Kop "Netwerken in de buurt"
$scan = netsh wlan show networks mode=bssid
$kanalen = ($scan | Select-String '^\s*(Channel|Kanaal)\s*:\s*(\d+)').Matches | ForEach-Object { $_.Groups[2].Value }
$kanalen | Group-Object | Sort-Object Count -Descending | ForEach-Object { Write-Host ("Kanaal {0,-4} : {1} zender(s)" -f $_.Name, $_.Count) }
if ($kanaal) {
  $zelfde = ($kanalen | Where-Object { $_ -eq $kanaal }).Count - 1
  if ($zelfde -ge 3) { $problemen += "$zelfde andere zenders op jouw kanaal $kanaal. Kies in de router een rustiger kanaal (2,4 GHz: 1, 6 of 11)." }
}

# 3. Energiebeheer van de wifi-kaart
Kop "Energiebeheer van de wifi-adapter"
$wifi = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' -and $_.Status -eq 'Up' } | Select-Object -First 1
if ($wifi) {
  Write-Host "Adapter: $($wifi.InterfaceDescription)  Linksnelheid: $($wifi.LinkSpeed)"
  $pm = Get-NetAdapterPowerManagement -Name $wifi.Name
  if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') { $problemen += "Windows mag de wifi-kaart uitschakelen om stroom te besparen. Zet dit uit in Apparaatbeheer > adapter > Energiebeheer." }
  $plan = powercfg /getactivescheme
  Write-Host "Energieplan: $plan"
  if ($plan -match 'Energiebesparing|Power saver') { $problemen += "Het energiebesparingsplan staat aan; dat kan wifi afremmen." }
}

# 4. VPN / proxy
Kop "VPN en proxy"
$vpn = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'VPN|TAP|TUN|WireGuard|Fortinet|Cisco|NordLynx|Proton|Tailscale' }
$vpn | ForEach-Object { Write-Host "Actief: $($_.InterfaceDescription)" }
if ($vpn) { $problemen += "Er is een VPN actief ($($vpn[0].InterfaceDescription)). VPN's verlagen de snelheid vaak flink." }
$proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if ($proxy.ProxyEnable -eq 1) { $problemen += "Er staat een proxy ingesteld ($($proxy.ProxyServer))." }

# 5. Vertraging: router vs. internet, DNS
Kop "Vertraging (ping)"
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
foreach ($doel in @($gw, '1.1.1.1', '8.8.8.8')) {
  if (-not $doel) { continue }
  $p = Test-Connection $doel -Count 10
  $ok = @($p).Count
  $gem = [math]::Round(($p | Measure-Object -Property ResponseTime -Average).Average)
  $verlies = (10 - $ok) * 10
  Write-Host ("{0,-16} gem {1} ms, verlies {2}%" -f $doel, $gem, $verlies)
  if ($doel -eq $gw -and $gem -gt 10) { $problemen += "Ping naar je router is hoog ($gem ms). Het probleem zit in de wifi zelf (signaal, storing, drukte)." }
  if ($verlies -ge 10) { $problemen += "$verlies% pakketverlies naar $doel." }
}
Kop "DNS-snelheid"
# Vraag rechtstreeks aan de ingestelde DNS-server (slaat de lokale cache over), met bekende sites
$dnsSrv = (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses[0]
$tijden = foreach ($d in 'google.com','youtube.com','wikipedia.org','netflix.com','microsoft.com') {
  (Measure-Command { Resolve-DnsName $d -Server $dnsSrv -DnsOnly | Out-Null }).TotalMilliseconds
}
$dnsMs = [math]::Round(($tijden | Sort-Object)[2])
Write-Host "DNS-server $dnsSrv : mediaan $dnsMs ms"
if ($dnsMs -gt 80) { $problemen += "Trage DNS ($dnsMs ms). Probeer DNS 1.1.1.1 of 8.8.8.8." }

# 6. Programma's die bandbreedte gebruiken
Kop "Programma's met de meeste netwerkverbindingen"
Get-NetTCPConnection -State Established | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
  $n = (Get-Process -Id $_.Name).ProcessName
  Write-Host ("{0,-30} {1} verbindingen" -f $n, $_.Count)
}
$verdacht = Get-Process | Where-Object { $_.ProcessName -match 'OneDrive|Dropbox|GoogleDrive|steam|EpicGames|Battle\.net|qbittorrent|utorrent|BitTorrent|Teams|Zoom' }
if ($verdacht) { $problemen += "Deze programma's kunnen op de achtergrond veel bandbreedte gebruiken: $(($verdacht.ProcessName | Sort-Object -Unique) -join ', ')." }
$wu = Get-Service wuauserv, BITS | Where-Object Status -eq 'Running'
if ($wu) { Write-Host "Windows Update/BITS actief: $($wu.Name -join ', ')" }

# 7. Snelheidstest (download van ~25 MB)
Kop "Snelheidstest"
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-WebRequest 'https://speed.cloudflare.com/__down?bytes=25000000' -UseBasicParsing -OutFile $env:TEMP\wifitest.bin
$sw.Stop()
$mbps = [math]::Round(25 * 8 / $sw.Elapsed.TotalSeconds, 1)
Write-Host "Download: $mbps Mbit/s"
Remove-Item $env:TEMP\wifitest.bin

# Samenvatting
Kop "GEVONDEN PROBLEMEN"
if ($problemen.Count -eq 0) { Write-Host "Geen duidelijke problemen gevonden op deze computer. Kijk ook naar de router (herstarten, firmware) en je abonnement." -ForegroundColor Green }
else { $i=1; $problemen | ForEach-Object { Write-Host "$i. $_" -ForegroundColor Yellow; $i++ } }
Read-Host "`nDruk op Enter om te sluiten"
