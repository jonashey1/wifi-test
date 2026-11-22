#!/bin/bash
# Wifi-diagnose voor macOS
# Uitvoeren in Terminal:  bash wifi-check-mac.sh

problemen=()
kop() { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

kop "Huidige wifi-verbinding"
info=$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{f=1;next} f&&/Other Local Wi-Fi Networks:/{exit} f')
echo "$info" | head -20
kanaal=$(echo "$info" | awk -F': ' '/Channel:/{print $2; exit}' | awk '{print $1}')
signaal=$(echo "$info" | awk -F': ' '/Signal \/ Noise:/{print $2; exit}' | awk '{print $1}')
ruis=$(echo "$info" | awk -F': ' '/Signal \/ Noise:/{print $2; exit}' | awk -F'/ ' '{print $2}' | awk '{print $1}')
phy=$(echo "$info" | awk -F': ' '/PHY Mode:/{print $2; exit}')
rate=$(echo "$info" | awk -F': ' '/Transmit Rate:/{print $2; exit}')
[[ -n "$signaal" && "$signaal" -lt -70 ]] && problemen+=("Zwak signaal ($signaal dBm). Ga dichter bij de router zitten of overweeg een mesh/repeater.")
[[ -n "$signaal" && -n "$ruis" && $((signaal - ruis)) -lt 25 ]] && problemen+=("Weinig marge tussen signaal en ruis ($((signaal - ruis)) dB). Er is storing (magnetron, babyfoon, buren).")
[[ -n "$kanaal" && "$kanaal" -le 14 ]] && problemen+=("Je zit op 2,4 GHz (kanaal $kanaal). Gebruik het 5 GHz-netwerk als je dat hebt.")
[[ "$phy" =~ 802\.11(b|g|n)$ ]] && problemen+=("Oude wifi-standaard ($phy).")
[[ -n "$rate" && "$rate" -lt 100 ]] && problemen+=("Lage verbindingssnelheid met de router ($rate Mbit/s).")

kop "Netwerken in de buurt (per kanaal)"
andere=$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Other Local Wi-Fi Networks:/{f=1} f' | awk -F': ' '/Channel:/{print $2}' | awk '{print $1}')
echo "$andere" | sort -n | uniq -c | sort -rn | head
if [[ -n "$kanaal" ]]; then
  zelfde=$(echo "$andere" | grep -cx "$kanaal")
  [[ "$zelfde" -ge 3 ]] && problemen+=("$zelfde andere netwerken op jouw kanaal $kanaal. Kies in de router een rustiger kanaal.")
fi

kop "VPN en proxy"
vpn=$(scutil --nc list 2>/dev/null | grep Connected)
utun=$(ifconfig | grep -c '^utun')
echo "${vpn:-geen VPN via Systeeminstellingen}"; echo "utun-interfaces: $utun"
[[ -n "$vpn" ]] && problemen+=("Er is een VPN actief. Dat verlaagt de snelheid vaak.")
scutil --proxy | grep -qE '(HTTP|HTTPS)Enable : 1' && problemen+=("Er staat een proxy ingesteld.")

kop "Vertraging (ping)"
gw=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
for doel in $gw 1.1.1.1 8.8.8.8; do
  uit=$(ping -c 10 -q "$doel" 2>/dev/null)
  verlies=$(echo "$uit" | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
  gem=$(echo "$uit" | awk -F'/' '/round-trip|rtt/{print int($5)}')
  echo "$doel: gem ${gem:-?} ms, verlies ${verlies:-?}%"
  [[ "$doel" == "$gw" && -n "$gem" && "$gem" -gt 10 ]] && problemen+=("Ping naar je router is hoog ($gem ms). Het probleem zit in de wifi zelf.")
  [[ -n "$verlies" && "${verlies%.*}" -ge 10 ]] && problemen+=("${verlies}% pakketverlies naar $doel.")
done

kop "DNS-snelheid"
start=$(perl -MTime::HiRes=time -e 'print int(time*1000)')
dscacheutil -q host -a name "example$RANDOM.com" >/dev/null
eind=$(perl -MTime::HiRes=time -e 'print int(time*1000)')
echo "DNS-opzoeking: $((eind - start)) ms"
[[ $((eind - start)) -gt 200 ]] && problemen+=("Trage DNS ($((eind - start)) ms). Probeer DNS 1.1.1.1 of 8.8.8.8.")

kop "Programma's met netwerkverkeer (5 sec meten)"
nettop -P -L 2 -s 5 -J bytes_in,bytes_out 2>/dev/null | tail -n +2 | sort -t, -k2 -nr | head -10
for p in Dropbox OneDrive "Google Drive" Steam bird cloudd Transmission qBittorrent zoom.us "Microsoft Teams" softwareupdated; do
  pgrep -qf "$p" && actief+="$p, "
done
[[ -n "$actief" ]] && problemen+=("Deze programma's/diensten kunnen bandbreedte gebruiken: ${actief%, }. (bird/cloudd = iCloud-synchronisatie)")

kop "Snelheidstest (ingebouwd networkQuality)"
networkQuality -s 2>/dev/null || echo "networkQuality niet beschikbaar (macOS 12+ nodig)"

kop "GEVONDEN PROBLEMEN"
if [[ ${#problemen[@]} -eq 0 ]]; then
  echo "Geen duidelijke problemen op deze Mac. Kijk ook naar de router (herstarten, firmware) en je abonnement."
else
  i=1; for p in "${problemen[@]}"; do printf "\033[33m%d. %s\033[0m\n" $i "$p"; ((i++)); done
fi
