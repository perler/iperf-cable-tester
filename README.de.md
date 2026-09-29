# iperf-cable-tester

Einen Raspberry Pi 4/5 (Raspberry Pi OS) oder einen PiKVM zur dauerhaft bereiten iperf3-Gegenstelle machen, um zu prüfen, ob eine LAN-Strecke wirklich Gigabit schafft.

Ein Kabeltester zeigt nur den Durchgang: Alle acht Adern gehen durch. Ob die Strecke auch 1 Gbit/s liefert, zeigt erst ein Durchsatztest, und dafür braucht es am anderen Ende eine Gegenstelle. Genau die liefert dieses Projekt: ein kleines Gerät, das an das eine Ende der Strecke kommt, während das Notebook am anderen hängt.

- Der Pi startet beim Booten einen iperf3-Server (Port 5201).
- Sein Ethernet-Anschluss hat immer die feste Link-Local-Adresse `169.254.99.1`. Ein Notebook am nackten Kabel (ohne Router, ohne DHCP) erreicht ihn ohne jede Konfiguration, denn Windows (APIPA) und macOS geben sich selbst eine `169.254.x.x`-Adresse, wenn kein DHCP antwortet.
- In einem normalen LAN bekommt der Pi zusätzlich eine Adresse per DHCP.
- Er verteilt selbst nie Adressen und kann daher gefahrlos in fremde Netze gesteckt werden.

Sprachen: [English](README.md), Deutsch (diese Datei).

## Hardware

- **Raspberry Pi 4 oder 5.** Ein Pi 3B+ schafft nur etwa 300 Mbit/s, ältere Modelle 100 Mbit/s. Das sähe genauso aus wie ein schlechtes Kabel, deshalb nicht verwenden.
- **Auch das Notebook braucht einen Gigabit-Anschluss.** Manche USB-C-Ethernet-Adapter können nur 100 Mbit/s. Die Client-Skripte zeigen die Link-Geschwindigkeit der Schnittstelle des Notebooks an.
- Ein kurzes Patchkabel und ein Netzteil für den Pi.

## Einrichtung

Die zum Gerät passende Variante wählen und einmal ausführen. Beide Skripte lassen sich gefahrlos erneut starten.

### Raspberry Pi OS (Bookworm oder neuer, NetworkManager)

Auf dem Pi, mit Internetzugang:

```
sudo bash server/setup-raspberry-pi-os.sh
sudo reboot
```

Der Hostname ist standardmäßig `iperf-peer`; änderbar mit `--hostname NAME` oder `HOSTNAME_NEW=name`. Das Skript:

- installiert iperf3 und startet es als systemd-Dienst (`lantester-iperf3`);
- legt zwei NetworkManager-Profile für `eth0` an: zuerst DHCP (20 s Timeout), und wenn keine Adresse kommt, die feste `169.254.99.1/16`;
- schaltet andere Kabel-Profile nur ab, löscht sie aber nicht, damit eine laufende SSH-Sitzung über das Kabel nicht abreißt. Wirksam wird alles nach dem Neustart.

Nach dem Neustart antwortet der Pi am nackten Kabel unter `169.254.99.1`, im Netzwerk unter seiner DHCP-Adresse oder `iperf-peer.local`.

Einschränkung: NetworkManager ignoriert Verbindungsverluste, die kürzer als etwa 6 Sekunden sind. Beim Umstecken des Pi von einem Netz in ein anderes das Kabel mindestens 10 Sekunden abziehen oder neu starten, sonst behält er womöglich die alte Adresse und der Fallback greift nicht. Funktioniert der Fallback, ist die feste Adresse etwa 22 Sekunden nach dem Link-Aufbau aktiv.

### PiKVM (Arch Linux ARM, Root schreibgeschützt, systemd-networkd)

Zuerst `pikvm-update` ausführen (und neu starten, falls verlangt). Teil-Upgrades unter Arch können das System beschädigen, deshalb aktualisiert das Skript bewusst nicht selbst.

Danach als root auf dem PiKVM (mit den Zugangsdaten des PiKVM):

```
bash server/setup-pikvm.sh
```

Das Skript prüft, ob es auf einem PiKVM läuft, schaltet das Root-Dateisystem auf schreibbar (`rw`), installiert iperf3, legt den Dienst `lantester-iperf3` an, fügt ein systemd-networkd-Drop-in `/etc/systemd/network/eth0.network.d/lantester.conf` mit `Address=169.254.99.1/16` hinzu (die `eth0.network` des Pakets bleibt unangetastet) aktiviert `avahi-daemon` (beim PiKVM vorhanden, aber abgeschaltet), damit der PiKVM unter `<hostname>.local` antwortet (standardmäßig `pikvm.local`), und schaltet am Ende wieder auf schreibgeschützt (`ro`), auch nach einem Fehler. Die Adresse kommt zusätzlich zu einer per DHCP erhaltenen. Ein Neustart ist nicht nötig.

## Messen

Die Client-Skripte messen je 10 Sekunden in jede Richtung und geben den Empfänger-Wert aus. Vorher iperf3 auf dem Notebook besorgen:

- Windows: ein Build wie https://github.com/ar51an/iperf3-win-builds/releases (entpacken, `client/lantest.cmd` und `client/lantest-find.ps1` in denselben Ordner wie `iperf3.exe` legen). Adminrechte sind nicht nötig. Nicht den alten Build 3.1.3 von iperf.fr nehmen: Er legt seine Temp-Datei neben `iperf3.exe` ab und scheitert ohne Adminrechte ("unable to create a new stream"); `lantest.cmd` lehnt ihn ab.
- macOS: `brew install iperf3`.
- Linux: `apt install iperf3` bzw. das Äquivalent der Distribution.

### Direkt am Kabel (ohne Router)

1. Pi an das eine Ende der Strecke, Notebook an das andere. Am Notebook das WLAN ausschalten.
2. Pi einschalten und ein bis zwei Minuten warten. Ohne DHCP-Antwort gibt sich das Notebook selbst eine `169.254.x.x`-Adresse (etwa 30 s nach dem Einstecken) und liegt damit im selben Netz wie der Pi. Konfiguriert werden muss nichts.
3. Das Client-Skript starten (siehe unten).

### Über Switches (normales Netz)

Den Pi an die Dose oder den Switch stecken, das Notebook ist wie gewohnt im Netz. Das Client-Skript ohne Argument starten; es findet den Pi über seinen Namen oder einen Netzwerk-Scan (siehe unten). Klappt das nicht, die DHCP-Adresse des Pi aus der Geräteliste des Routers mitgeben.

### So wird die Gegenstelle gefunden

Ohne Argument probieren beide Client-Skripte in dieser Reihenfolge und nehmen die erste Gegenstelle, die auf Port 5201 antwortet (etwa 2 s pro Versuch):

1. `169.254.99.1` (Direktkabel; unter macOS oft auch im normalen Netz, siehe unten).
2. `iperf-peer.local` (der Standard-Hostname aus `setup-raspberry-pi-os.sh`).
3. `pikvm.local` (der Standard-Hostname eines PiKVM).
4. Ein Scan des Netzes des Notebooks, nur wenn es ein `/24` oder kleiner ist: ein schneller Ping-Durchlauf, danach wird jeder Raspberry Pi in der ARP-Tabelle (erkannt am Anfang der MAC-Adresse) auf Port 5201 geprüft.

Das Skript zeigt an, welche Gegenstelle es verwendet (`Peer found: ...`). Antwortet keine, listet es auf, was probiert wurde, und endet mit einem Fehlercode ungleich 0. Mit einem Argument entfällt die Suche.

Grenzen:

- Ein umbenannter Pi oder PiKVM wird nicht über den Namen gefunden. Dann seinen Namen (`meinpi.local`) oder seine IP mitgeben, oder auf den Scan setzen.
- Netze, die mDNS (`.local`-Namen) sperren oder Geräte voneinander abschotten (Gäste-WLAN, manche Firmennetze), verhindern Namen und Scan. Dann die IP mitgeben.
- Der Scan pingt jede Adresse im Netz an. Sicherheitssoftware in einem verwalteten Netz kann das bemerken oder melden.
- Der iperf3-Server lauscht nur am Kabelanschluss der Gegenstelle (`eth0`), deshalb kann eine Gegenstelle, die auch im WLAN hängt, nicht versehentlich über WLAN gemessen werden.
- `LANTEST_PEERS="name-oder-ip ..."` ersetzt die Liste der Namen, die vor dem Scan probiert werden.

### Windows

`client/lantest.cmd` doppelklicken oder in einer Eingabeaufforderung starten:

```
lantest.cmd                  rem Gegenstelle automatisch finden
lantest.cmd 192.168.1.50     rem diese Gegenstelle verwenden
```

`iperf3.exe` und `lantest-find.ps1` müssen im selben Ordner liegen; die beiden Skripte immer zusammen weitergeben. Das Skript zeigt auch die Link-Geschwindigkeiten des Notebooks an.

### macOS und Linux

```
client/lantest.sh                  # Gegenstelle automatisch finden
client/lantest.sh 192.168.1.50     # diese Gegenstelle verwenden
```

Es zeigt, über welche Schnittstelle das Ziel erreicht wird, warnt bei WLAN, zeigt die Link-Geschwindigkeit der Schnittstelle, misst beide Richtungen und gibt ein Urteil in einer Zeile aus. Ist der Pi nicht erreichbar, endet es mit einem Fehlercode ungleich 0 und einem Hinweis. Es läuft mit der bash 3.2, die macOS mitbringt.

Unter macOS ist `169.254.99.1` sogar in einem normalen DHCP-Netz erreichbar, weil macOS eine direkte `169.254/16`-Route behält.

Gemessenes Beispiel: MacBook Air mit USB-C-Ethernet-Adapter gegen einen Raspberry Pi 4 über eine 1-Gbit/s-Verbindung ergab 940 und 941 Mbit/s in den beiden Richtungen zu `169.254.99.1`, 0 Wiederholungen (Retransmits).

## Ergebnis lesen

Maßgeblich ist die Zeile mit `receiver` am Ende jeder Messung.

| # | Ergebnis | Bedeutung |
|---|----------|-----------|
| 1 | ca. 850-940 Mbit/s in beide Richtungen | Gigabit-Strecke in Ordnung |
| 2 | ca. 94 Mbit/s, Link zeigt 100 Mbit/s | Strecke linkt nur mit 100 Mbit/s, siehe unten |
| 3 | Link zeigt 1 Gbit/s, Durchsatz deutlich unter 800 | Störungen auf der Strecke (Übersprechen, schlechte Dose oder Patchung); bei TCP sichtbar an vielen Wiederholungen (`Retr`) |
| 4 | Stark unterschiedlich je Richtung | Meist ein Adernpaar mit Problem oder ein Endgerät am Limit |

Die Link-Geschwindigkeit des Pi: `ethtool eth0 | grep Speed` (beim PiKVM: `cat /sys/class/net/eth0/speed`).

## Link nur mit 100 Mbit/s

100BASE-TX nutzt nur zwei der vier Adernpaare (Pins 1, 2, 3, 6), 1000BASE-T braucht alle vier. Linkt eine Strecke nur mit 100 Mbit/s, ist deshalb fast immer eines der Paare an Pin 4/5 oder 7/8 unterbrochen, vertauscht oder zu weit aufgedrillt. Oder die Strecke hat ein aufgetrenntes Paar („split pair“), das ein einfacher Kabeltester nicht erkennt, obwohl jede einzelne Ader Durchgang hat.

Zum Gegenprüfen Pi und Notebook direkt an die beiden Enden der Strecke stecken, ohne Switch dazwischen. Linkt es direkt mit 1 Gbit/s, liegt es am Switch oder einem Patchkabel. Linkt es auch direkt nur mit 100 Mbit/s, liegt es an der verlegten Strecke oder den Dosen.

## Sicherheitshinweis

Der iperf3-Server lauscht auf Port 5201 ohne Authentifizierung. Für ein Testgerät, das für eine Messung angesteckt wird, ist das in Ordnung. Nicht dauerhaft in einem nicht vertrauenswürdigen Netz betreiben. Der Pi routet nicht und verteilt kein DHCP.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
