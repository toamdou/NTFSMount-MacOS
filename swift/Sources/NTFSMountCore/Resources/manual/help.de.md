# NTFSMount Benutzerhandbuch

## 1. Was dieses Werkzeug tut und was nicht

macOS kann NTFS von Haus aus **lesen**, aber nicht schreiben. NTFSMount ergänzt genau diese Hälfte: Es verwendet den ausgereiften Open-Source-NTFS-Treiber `ntfs-3g` zusammen mit dem von `macFUSE` bereitgestellten Framework für Dateisysteme im Userspace, um ein NTFS-Volume als les- und schreibbar neu einzubinden, sodass Sie im Finder wie auf einer gewöhnlichen Festplatte Dateien ablegen können.

Ebenso wichtig ist, was es **nicht** tut. Keine der folgenden Aufgaben übernimmt es:

- Es formatiert nicht, partitioniert nicht und konvertiert keine Dateisystemformate;
- Es verändert keine Partitionstabellen und rührt keinen Bootsektor an;
- Es greift weder auf die Zugriffssteuerungslisten (ACL) noch auf das Verschlüsselungssystem von Windows zu;
- Es betreibt keine Datenrettung. Das `ntfsfix` in der Funktion „Zurücksetzen“ entfernt lediglich die Markierung „unsauberes Volume“; es repariert keine Dateiinhalte;
- Es lässt keinen Fremdprozess dauerhaft im Hintergrund laufen, stellt keine Netzwerkverbindung her und lädt keine Informationen hoch.

> [!WARN]
> Jeder Schreibvorgang auf NTFS birgt Risiken, unabhängig davon, welches Werkzeug Sie verwenden. Bevor Sie zum ersten Mal auf eine Festplatte schreiben, sollten Sie die darauf befindlichen wichtigen Dateien gesondert sichern. Dieses Werkzeug wird „wie besehen“ bereitgestellt und übernimmt keine Haftung für Datenverlust.

> [!IMPORTANT]
> Die Datenintegrität hängt zu einem großen Teil von der Hardware selbst ab. USB-Sticks mit minderwertigen Flash-Speicherzellen verlieren bei anhaltendem Schreiben an Geschwindigkeit, melden Fehler oder fallen ganz aus und wirken dabei, als läge ein Softwareproblem vor. Für umfangreiche Lese- und Schreibvorgänge sollten Sie eine externe Festplatte oder einen Solid-State-USB-Stick mit garantierter Lese- und Schreibleistung verwenden.

## 2. Systemvoraussetzungen und Abhängigkeiten

| Projekt | Anforderung |
| --- | --- |
| Betriebssystem | macOS 14.0 oder höher |
| Prozessor | Für Apple Silicon und Intel liegen jeweils passende Installationspakete vor |
| Erforderliche Abhängigkeiten | macFUSE, ntfs-3g |
| Speicherplatzbedarf | ca. 30 MB (die Anwendung selbst etwa 4 MB) |

Die Abhängigkeiten sind keine gleichrangigen zwei Punkte, sondern eine Kette:

```
NTFSMount        ->  ntfs-3g        ->  macFUSE        ->  macOS kernel
  (UI)                 (driver)           (framework)        (system)
```

`ntfs-3g` versteht die Datenträgerstruktur von NTFS, kann aber nicht selbst direkt mit dem macOS-Kernel kommunizieren – es benötigt eine Zwischenschicht eines „Dateisystems im Userspace“, die die Dateianfragen des Kernels an es weiterleitet, und diese Schicht ist `macFUSE`. Fehlt auch nur ein Glied, kommt keine Einbindung zustande.

> [!NOTE]
> Diese Anwendung ist eine vollständig native Implementierung: Oberfläche, Geräteerkennung und Einbindungsablauf nutzen ausschließlich Systemframeworks – ohne Drittanbieter-Laufzeitumgebung und ohne dauerhaften Hilfsprozess. Das Anstecken und Abziehen von Geräten wird über die nativen Systembenachrichtigungen von IOKit und DiskArbitration erkannt, ohne Polling; im Leerlauf liegt die CPU-Auslastung nahe 0.

## 3. Systemabhängigkeiten vorbereiten

### 3.1 Zuerst die Anwendung melden lassen, was fehlt

Öffnen Sie die Anwendung, wechseln Sie zur Seite „Systemabhängigkeiten“ und klicken Sie oben rechts auf „Abhängigkeiten prüfen“. Diese Seite listet den tatsächlichen Status von vier Punkten auf:

1. Ob die macOS-Version die Mindestanforderung erfüllt;
2. ob die Xcode Command Line Tools installiert sind (gegebenenfalls erforderlich für die Installation von ntfs-3g);
3. ob macFUSE vorhanden ist;
4. ob ntfs-3g vorhanden ist.

Jeder Punkt lässt sich aufklappen, und nach dem Aufklappen sehen Sie, was für diesen Punkt zu installieren ist und mit welchem Befehl. Neben dem Befehl befindet sich eine Schaltfläche zum Kopieren. Fehlende Punkte werden rot markiert, installierte grün.

> [!TIP]
> Nach der Installation der Abhängigkeiten müssen Sie die Anwendung weder neu starten noch erneut auf „Abhängigkeiten prüfen“ klicken. Diese Seite prüft alle drei Sekunden automatisch nach (reine Dateisystemprüfung, es wird kein Prozess gestartet); sobald Sie im Terminal `brew install` oder `port install` ausgeführt haben, sehen Sie beim Zurückwechseln zum Fenster, wie der Status von selbst grün wird.

### 3.2 MacPorts (die erste Wahl für Intel-Mac)

```bash
sudo port install macfuse
```

```bash
sudo port install ntfs-3g
```

MacPorts installiert alles unter `/opt/local`. Diese Anwendung bezieht `/opt/local/bin` in ihren Suchbereich mit ein, sodass es nach der Installation sofort erkannt wird – Sie müssen weder `PATH` konfigurieren noch der Anwendung sagen, wo sie suchen soll.

### 3.3 Homebrew (die erste Wahl für Apple Silicon)

```bash
brew install --cask macfuse
```

```bash
brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac
```

Der Tap `ntfs-3g-mac` stellt eine für Apple Silicon angepasste Build-Version bereit.

### 3.4 Manuelle Installation über die Release-Seite

Sie können auch ohne Paketverwaltung über die Projekt-Release-Seite herunterladen und installieren:

- macFUSE: https://macfuse.github.io
- ntfs-3g: https://github.com/tuxera/ntfs-3g

Bei der manuellen Installation treten leicht Pfadprobleme auf: Wird an einen nicht standardmäßigen Ort installiert, findet die Anwendung die Datei nicht. Vergewissern Sie sich in diesem Fall, dass die ausführbare Datei in einem der Verzeichnisse `/usr/local/bin`, `/opt/local/bin` oder `/opt/homebrew/bin` liegt.

### 3.5 Installationsreihenfolge und Überprüfung

Zuerst `macFUSE`, danach `ntfs-3g`. Umgekehrt schlägt die Installation des Letzteren fehl, weil das Framework nicht gefunden wird.

Nach der Installation einmal im Terminal überprüfen:

```bash
ntfs-3g --version
```

Wird eine Versionsnummer ausgegeben, ist der Pfad in Ordnung – genau diese ausführbare Datei erkennt die Anwendung.

> [!IMPORTANT]
> Nach der Installation von macFUSE blockiert macOS dessen Systemerweiterung und zeigt einen Hinweis an. Sie müssen zu „Systemeinstellungen → Datenschutz & Sicherheit“ gehen, weiter unten den Eintrag von macFUSE finden und auf „Zulassen“ klicken und anschließend den Computer wie aufgefordert neu starten. Wenn Sie diesen Schritt nicht ausführen, schlägt die Einbindung fehl, und zwar mit einer Berechtigungsfehlermeldung – die nichts mit NTFS selbst zu tun hat.

### 3.6 Zur Version

Die Anwendung führt eine Prüfung der Version von `ntfs-3g` durch: Liegt sie unter der empfohlenen Version, erscheint auf der Abhängigkeitsseite ein Aktualisierungshinweis; bei bekannten Versionen mit Regressionen (die das Anlegen neuer Dateien und Verzeichnisse verhindern) erscheint eine ausdrückliche Warnung. Sie aktualisiert nicht selbst, sondern teilt Ihnen nur mit, dass aktualisiert werden sollte.

## 4. Die erste Einbindung erfolgreich durchführen

1. Stecken Sie ein externes Laufwerk im NTFS-Format an. macOS bindet es zunächst **nur lesend** ein; im Finder ist das Volume sichtbar, Sie können aber nichts darauf speichern.
2. Öffnen Sie NTFSMount, wechseln Sie zur Seite „NTFS-Geräte“ und klicken Sie auf „Aktualisieren“ oder warten Sie, bis automatisch aktualisiert wird.
3. Suchen Sie das Zielgerät in der Liste und prüfen Sie, ob in der Spalte „Gerät-Einhängepunkt“ der Nur-Lesen-Status steht.
4. Klicken Sie auf der rechten Seite dieser Zeile auf die Schaltfläche „Lesen & Schreiben“.
5. Das System zeigt einen Autorisierungsdialog an; geben Sie Ihr Mac-Anmeldepasswort ein (ist „Administratorpasswort speichern“ aktiviert, erscheint dieser Schritt nicht).
6. Nach erfolgreicher Einbindung wechselt der Status dieser Zeile zu „Lesen & Schreiben“, und das Volume lässt sich im Finder normal beschreiben.

Jetzt können Sie Dateien auf das Volume schreiben. Um nach Gebrauch in den systemseitigen Nur-Lesen-Standardzustand zurückzukehren, klicken Sie in dieser Zeile auf „Nur Lesen wiederherstellen“; um das Laufwerk vollständig zu trennen, klicken Sie auf „Auswerfen“.

> [!NOTE]
> Das in Schritt 5 angezeigte Fenster ist der Autorisierungsdialog von macOS selbst und keine von dieser Anwendung gezeichnete Oberfläche. Er unterstützt Touch ID und Apple Watch, das Passwort wird direkt vom systemeigenen `securityd` geprüft, und diese Anwendung erhält das von Ihnen eingegebene Passwort zu keinem Zeitpunkt. Dies ist der Standardweg und zugleich der sicherere.

## 5. Rundgang durch die Hauptoberfläche

Das Hauptfenster verwendet das übliche macOS-Spaltenlayout: links die Navigation, rechts der Inhalt, unten eine Statusleiste.

### 5.1 Die vier Seiten der Seitenleiste

- **Systemabhängigkeiten** – prüft macFUSE und ntfs-3g, zeigt die Installationsanleitung.
- **NTFS-Geräte** – Geräteliste und sämtliche Aktionen befinden sich hier.
- **Aktionsprotokoll** – Zeitpunkt und Ursache jeder Einbindung, Ausbindung und jedes Fehlschlags. Standardmäßig deaktiviert, muss in den Einstellungen aktiviert werden.
- **Handbuch** – genau diese Seite, die Sie gerade lesen. Das linke Inhaltsverzeichnis ist durchsuchbar, Codeblöcke lassen sich mit einem Klick kopieren.

Die Einstellungen befinden sich **nicht** in der Seitenleiste. Sie liegen wie unter macOS üblich im Anwendungsmenü unter „Einstellungen …“ (⌘,); ein zweiter Eintrag in der Seitenleiste würde nur zwei Zugänge auf dieselbe Stelle schaffen.

### 5.2 Die Statusleiste unten

Die Statusleiste fasst die aktuelle Lage mit einem Punkt und einem Satz zusammen:

| Farbe | Bedeutung |
| --- | --- |
| Grau | Abhängigkeiten werden geprüft |
| Grün | Bereit. Dahinter steht, wie viele Geräte les- und schreibbar und wie viele nur lesend sind |
| Orange | Ein Problem liegt vor, ist aber nicht kritisch |
| Rot | Abhängigkeiten fehlen, die Einbindungsfunktion ist nicht verfügbar |

### 5.3 Symbolleiste der Geräte-Seite

Von links nach rechts: **Aktualisieren**, **Alle lesen & schreiben**, **Alle nur lesen**, **Alle ausbinden**, **Alle auswerfen**. Das Suchfeld befindet sich ebenfalls in der Symbolleiste und filtert nach Volume- oder Gerätename.

Die Sammelschaltflächen wirken auf die **aktuell ausgewählten Zeilen**; ist keine Zeile ausgewählt, wirken sie auf alle Geräte.

## 6. Geräte-Seite: den Status richtig lesen

### 6.1 Drei Statuswerte

| Anzeige | Bedeutung | Beschreibbar |
| --- | --- | --- |
| Lesen & Schreiben | Wird bereits von ntfs-3g übernommen und les- und schreibbar eingebunden | Ja |
| Nur Lesen | Nur-Lesen-Einbindung des systemeigenen NTFS-Treibers | Nein |
| Ausgebunden | Sie haben es ausgebunden, das Gerät steckt aber noch | Nein |

Der Status „Ausgebunden“ wird bewusst beibehalten: Bevor Sie ein Gerät abziehen, binden Sie es aus, und danach soll es nicht aus der Liste verschwinden – sonst würden Sie glauben, das Gerät sei verloren gegangen. Damit es endgültig verschwindet, verwenden Sie „Auswerfen“.

### 6.2 Kapazitätsleiste

Unter dem Gerätenamen jeder Zeile befindet sich eine Kapazitätsleiste, die „Verfügbar / Gesamt“ und den Belegungsprozentsatz anzeigt. Auch bei nicht eingebundenem Gerät wird die Kapazität angezeigt – die Kapazität wird aus den Kopfdaten des Dateisystems gelesen und ist ohne Einbindung verfügbar.

Die Farbe der Kapazitätsleiste kennt drei Stufen:

- Blau (Standard) – Belegung unter 75 %;
- Orange – Belegung zwischen 75 % und 90 %, jetzt ist Aufmerksamkeit angebracht;
- Rot – über 90 %, jetzt sollte aufgeräumt werden.

Drei Stufen statt eines stufenlosen Farbverlaufs, weil dieser Fortschrittsbalken in der Oberfläche nur wenige Millimeter breit ist und ein Verlauf bei dieser Größe schlicht nicht zu unterscheiden wäre.

### 6.3 Einhängepunkt

Die Spalte „Gerät-Einhängepunkt“ zeigt einen Pfad wie `/Volumes/<name>`. Bei nicht eingebundenem Gerät wird „Nicht eingebunden“ angezeigt. Nach dem Einbinden zum Lesen und Schreiben ist genau dieser Pfad der im Finder erreichbare.

## 7. Geräte-Seite: was die sechs Aktionen jeweils tun

Alle sechs Aktionen befinden sich rechts in jeder Zeile. Ihr Unterschied besteht nicht nur in „einbinden“ und „nicht einbinden“; eine falsche Wahl kostet im besten Fall nur Zeit, im schlimmsten Fall unterbricht sie eine laufende Übertragung.

| Aktion | Was sie tatsächlich tut | Wann sie zu verwenden ist |
| --- | --- | --- |
| Lesen & Schreiben | Bindet zunächst die aktuelle Nur-Lesen-Einbindung aus und bindet dann mit ntfs-3g les- und schreibbar ein | Wenn Sie auf das Laufwerk schreiben möchten |
| Erneut lesen & schreiben | Bindet zunächst aus und bindet dann erneut les- und schreibbar ein | Wenn im Lesen-&-Schreiben-Zustand Probleme auftreten und Sie neu beginnen möchten |
| Nur Lesen wiederherstellen | Bindet aus, übergibt an den systemeigenen Treiber und bindet nur lesend ein | Wenn Sie fertig geschrieben haben und in den konservativsten Zustand zurückkehren möchten |
| Ausbinden | Bindet aus, das Gerät bleibt aber in der Liste | Bevor Sie das Laufwerk abziehen |
| Auswerfen | Trennt dieses Gerät vollständig vom System | Wenn Sie sicher sind, es nicht mehr zu nutzen, und es abziehen möchten |
| Zurücksetzen | Ausbinden → „Dirty-Flag“ mit `ntfsfix` löschen → nur lesend neu einbinden | Bei „Resource busy“ oder wenn es sich nicht nutzen lässt |

### 7.1 Lesen & Schreiben

Vor dem Einbinden wird geprüft, ob macFUSE und ntfs-3g vorhanden sind. Fehlt eines davon, wird Ihnen direkt mitgeteilt, was fehlt und wo es installiert wird; es erscheint keine unverständliche Fehlermeldung, und Sie müssen nicht anhand eines regungslosen Symbols raten.

### 7.2 Nur Lesen wiederherstellen

Diese Aktion bindet zunächst die aktuelle Einbindung aus und lässt dann den systemeigenen Treiber erneut nur lesend einbinden. **Dabei gehen keine Daten verloren**, vorausgesetzt, dass in diesem Moment kein Programm auf dieses Laufwerk schreibt. Läuft gerade eine Kopie oder ein Download, warten Sie deren Ende ab.

### 7.3 Unterschied zwischen Ausbinden und Auswerfen

Ausbinden hängt lediglich das Dateisystem ab, das Gerät bleibt angeschlossen und kann jederzeit erneut eingebunden werden. Auswerfen trennt das Gerät tatsächlich vom System; vor dem Abziehen des Kabels ist dies der sicherste Schritt. Nach dem Auswerfen verschwindet das Gerät aus der Liste und kehrt erst nach erneutem Anstecken zurück.

### 7.4 Zurücksetzen

Manche Störungen lassen sich durch bloßes erneutes Einbinden nicht beheben, etwa ein von einem vorherigen abnormalen Beenden hinterlassenes „Dirty-Flag“ oder ein Programm, das das Laufwerk belegt. Das Zurücksetzen führt drei Dinge aus: es erzwingt das Ausbinden, ruft `ntfsfix` auf, um das NTFS-Dirty-Flag zu löschen, und bindet es nur lesend wieder ein. Nach dem Löschen des Flags ist in der Regel wieder normales Lesen und Schreiben möglich.

> [!NOTE]
> `ntfsfix` löscht die Markierung „Partition nicht sauber“; es prüft und repariert keine Dateiinhalte. Wenn Ihr Laufwerk nach einem nicht ordnungsgemäßen Herunterfahren unter Windows Probleme zeigt, ist es nach dem Löschen des Flags meist wiederhergestellt; ist jedoch die Dateisystemstruktur selbst beschädigt, benötigen Sie die Windows-eigene Datenträgerprüfung und nicht diese Schaltfläche.

### 7.5 Sammelaktionen

Die Sammelschaltflächen der Symbolleiste wirken auf die aktuell ausgewählten Zeilen; ist keine Zeile ausgewählt, auf alle. Eine Sammel-Einbindung startet die Aktion nacheinander für jedes Gerät – ohne gespeichertes Administratorpasswort sehen Sie aufeinanderfolgende Autorisierungsdialoge, was dem erwarteten Verhalten entspricht.

## 8. Einbindungsparameter

Die Parameter für die Einbindung legt die Anwendung einheitlich fest; keinen einzigen müssen Sie manuell angeben. Sie sind hier aufgeführt, damit Sie sie im Problemfall verstehen können:

| Parameter | Wirkung |
| --- | --- |
| `-olocal` | Lässt das System dieses Volume als lokales Volume statt als Netzwerkvolume behandeln. Beeinflusst, ob es im Finder unter „Orte“ oder „Netzwerk“ erscheint |
| `-oallow_other` | Erlaubt Prozessen außerhalb des Einbindenden den Zugriff auf dieses Volume. Ohne diese Option kann nur root lesen, was in einer Desktop-Umgebung praktisch einer Unbenutzbarkeit gleichkommt |
| `-oremove_hiberfile` | Löscht die Hibernationsdatei, wenn das Volume von Windows im Ruhezustand belegt ist, und erkauft so eine schreibbare Einbindung |
| `-onoatime` | Aktualisiert nicht die „letzte Zugriffszeit“ einer Datei. Bei jedem Lesevorgang einen Indexeintrag zu schreiben ist reine Write Amplification |
| `-ovolname` | Lässt das Volume im Finder den korrekten Namen anzeigen |

> [!IMPORTANT]
> Die Bedeutung von `-oremove_hiberfile` muss klar sein: Der „Schnellstart“ von Windows schreibt den Systemzustand vor dem Herunterfahren in eine Hibernationsdatei, wobei das NTFS-Volume in einem Zustand „wird gerade verwendet“ verbleibt. Mit diesem Parameter löscht die Anwendung diese Hibernationsdatei und erhält dadurch Schreibrechte – **zum Preis des Verlusts des ungespeicherten Sitzungszustands auf der Windows-Seite**. Falls Sie unter Windows noch nicht gespeicherte Dinge haben, stecken Sie das Laufwerk zuerst zurück an Windows und fahren Sie ordnungsgemäß herunter.

## 9. E/A-Blockgröße

Dies ist die einzige leistungsbezogene einstellbare Option, zu finden unter „Einstellungen → Einbindungsparameter“.

macFUSE stellt für jedes von Ihnen angesprochene Volume ein „gedachtes Speichergerät“ bereit; `iosize` bestimmt die Blockgröße, mit der der Kernel E/A-Anfragen an das Dateisystem richtet. Der Standardwert von macFUSE selbst beträgt 64 KiB, und die offizielle Dokumentation sagt es ganz offen: Bei schneller Anbindung (etwa bei einer lokalen Festplatte) senkt eine große Blockgröße den Zugriffsaufwand deutlich. Eine lokale USB- oder Thunderbolt-Festplatte gehört offensichtlich zu den „schnellen Anbindungen“.

| Stufe | Anwendungsfall |
| --- | --- |
| macFUSE-Standard (64 KiB) | Mechanische Festplatten; überwiegend sehr viele kleine Dateien mit kaum sequenziellem Lesen und Schreiben großer Dateien |
| 1 MiB (empfohlen) | Standardstufe. Gängiges Szenario für SSDs und externe Festplatten |
| 4 MiB | Überwiegend sehr große Dateien: Videomaterial, Datenträgerabbilder, vollständige Laufwerkssicherungen |

Die Änderung wird für die **nächste Einbindung** wirksam; bereits eingebundene Geräte müssen einmal erneut les- und schreibbar eingebunden werden.

> [!NOTE]
> Dieser Parameter hat Formatbeschränkungen: Er muss eine Zweierpotenz sein, maximal 32 MiB. Die drei von der Anwendung angebotenen Stufen liegen alle im sicheren Bereich, sodass Sie sich diese Einschränkungen nicht merken müssen – beachten Sie sie aber, wenn Sie an anderer Stelle manuell einbinden.

## 10. Berechtigungen und Administratorpasswort

Für das Einbinden zum Lesen und Schreiben sind Administratorrechte erforderlich. Die Anwendung bietet zwei Wege, diese Rechte zu erlangen.

### 10.1 Standardweg: der Systemautorisierungsdialog

Jedes Mal, wenn eine Rechteerweiterung erforderlich ist, erscheint der Dialog von macOS, das Passwort wird vom System geprüft und ist für diese Anwendung durchweg unzugänglich. Touch ID und Apple Watch werden unterstützt. Dies ist der Standardweg und der sicherere.

### 10.2 Optionale Variante: Administratorpasswort speichern

Öffnen Sie unter „Einstellungen → Systemintegration“ die Option „Administratorpasswort speichern“, geben Sie einmal das Passwort ein und klicken Sie auf „Prüfen und speichern“. Danach erscheint beim Einbinden kein Dialog mehr.

Das Passwort wird im macOS-Schlüsselbund gespeichert, der Eintragstyp ist ein allgemeines Passwort, und der Eintrag ist der Bundle-Kennung dieser Anwendung zugeordnet. In keinem Protokoll und keiner Datei dieser Anwendung erscheint dieses Passwort.

> [!WARN]
> Bitte verstehen Sie diese Abwägung zutreffend: Ein gespeichertes Passwort ist **weniger sicher** als die manuelle Eingabe bei jedem Vorgang. Der Unterschied besteht darin, dass das Passwort von dieser Anwendung übermittelt wird und nicht direkt vom System beim Nutzer abgefragt wird. Wenn dieser Mac von mehreren Personen genutzt wird oder Sie sich über die Herkunft der Software auf dem Rechner nicht sicher sind, aktivieren Sie diese Option nicht.

### 10.3 Der Schalter kennt drei Zustände – nicht verwechseln

| Schalter | Passwort im Schlüsselbund | Tatsächliches Verhalten |
| --- | --- | --- |
| Aus | Unerheblich | Jedes Mal erscheint der Systemautorisierungsdialog |
| Ein | Nicht vorhanden | **Es erscheint trotzdem ein Dialog.** Der Schalter drückt nur die Absicht aus, ein nutzbares Passwort liegt noch nicht vor |
| Ein | Vorhanden | Kein Dialog, die Rechteerweiterung erfolgt mit dem gespeicherten Passwort |

Der zweite Zustand wird gesondert mit einer orangen Zeile gekennzeichnet, damit Sie nicht vor einem eingeschalteten Schalter rätseln, „warum trotzdem ein Dialog erscheint“.

### 10.4 Was geschieht, wenn das Passwort ungültig wird

Wenn Sie später das Anmeldepasswort Ihres Mac ändern, wird der im Schlüsselbund gespeicherte Eintrag ungültig. In diesem Fall wird die Anwendung: das ungültige Passwort löschen, diesen Umstand im Protokoll und auf der Einstellungsseite erläutern und zum Systemautorisierungsdialog zurückkehren, sodass Ihre Aktion dennoch abgeschlossen werden kann. Ein Fall von „wiederholtem Scheitern, das nie besser wird“ tritt nicht auf.

### 10.5 Wie man es endgültig löscht

Schalten Sie einfach den Schalter „Administratorpasswort speichern“ aus – das Ausschalten selbst schließt das Löschen des Eintrags im Schlüsselbund ein. Alternativ können Sie in der Anwendung „Schlüsselbundverwaltung“ nach der Bundle-Kennung dieser Anwendung suchen und den Eintrag manuell löschen.

## 11. Verhalten beim Start: wie die vier Schalter zusammenspielen

Diese vier Schalter hängen alle mit „Start“ und „Automatisch“ zusammen und werden leicht verwechselt. Jeder von ihnen regelt nur eine Sache:

| Einstellung | Regelungsbereich |
| --- | --- |
| Systemstart | Ob diese Anwendung beim Hochfahren **gestartet wird** |
| Stiller Start | Ob beim Start **das Hauptfenster geöffnet wird**. Nach dem Öffnen bleibt sie nur in der Menüleiste |
| Automatisches Lesen & Schreiben beim Start | Bindet im Augenblick des Starts die **bereits am Rechner angeschlossenen** NTFS-Geräte les- und schreibbar ein |
| Automatisches Lesen & Schreiben | Bindet während des Betriebs der Anwendung **danach neu angesteckte** Geräte automatisch les- und schreibbar ein |

Einige typische Kombinationen:

- Sie möchten nur, dass nach dem Hochfahren ein Laufwerk direkt beschreibbar ist: „Systemstart“ + „Automatisches Lesen & Schreiben beim Start“ aktivieren.
- Sie möchten nach dem Hochfahren im Hintergrund bereitstehen und kein auftauchendes Fenster sehen: zusätzlich „Stiller Start“.
- Sie möchten nicht automatisch beim Hochfahren einbinden, aber jedes künftig angesteckte Laufwerk automatisch beschreibbar haben: nur „Automatisches Lesen & Schreiben“ aktivieren.
- Sie möchten nicht einmal einen Autorisierungsdialog: zusätzlich „Administratorpasswort speichern“ aktivieren; dann läuft die Einbindung beim Start unbeaufsichtigt ab.

> [!TIP]
> Nach dem Aktivieren von „Stiller Start“ behält die Anwendung nur ein Symbol in der Menüleiste, im Dock erscheint sie nicht. Ein Linksklick darauf genügt, um Geräte zu verwalten; das Kontextmenü enthält „Hauptfenster“; das Schließen des Fensters aus dem Hauptfenster heraus beendet die Anwendung nicht, sie kehrt in die Menüleiste zurück und bleibt bereit.

## 12. Menüleisten-Symbol und Schnellpanel

Das Schließen des Hauptfensters beendet die Anwendung nicht – dies ist das Grundverhalten einer dauerhaft in der Menüleiste präsenten Anwendung. Nach dem Schließen des Fensters arbeitet die Anwendung über das Menüleisten-Symbol weiter.

### 12.1 Linksklick auf das Symbol

Es erscheint ein Schnellpanel, das alle NTFS-Geräte direkt auflistet. Für jedes Gerät werden angezeigt:

- Statussymbol und Volume-Name;
- der Einbindungsstatus des Volume;
- die **Kapazitätsleiste**: „Verfügbar / Gesamt“ und der Belegungsprozentsatz;
- die Aktionsschaltflächen auf der rechten Seite.

Einbinden, Ausbinden, Wiederherstellen und Auswerfen lassen sich erledigen, ohne das Hauptfenster zu öffnen. Der im Panel angezeigte Status stammt aus denselben Daten wie die Hauptoberfläche, eine Nichtsynchronisation zwischen zwei Stellen gibt es nicht.

Auch das Symbol selbst ändert sich: Befindet sich ein Gerät im Lesen-&-Schreiben-Zustand, wird ein anderes Symbol verwendet, sodass auf einen Blick erkennbar ist, „dass gerade ein Laufwerk beschreibbar ist“.

### 12.2 Was das Panel bei fehlgeschlagener Aktion anzeigt

Die Fehlerursache wird direkt unter der jeweiligen Zeile angezeigt, in Rot, mit Warnsymbol, und zwar als **vollständiger Satz**, nicht abgeschnitten. Diese Gestaltung ist notwendig und nicht bloß eine Verschönerung – das Schnellpanel hat keine Protokollseite, und wenn Fehlerinformationen nur ins Protokoll geschrieben würden, sähen Sie beim Klick auf „Lesen & Schreiben“ in diesem kleinen Panel „keine Reaktion“: kein Dialog, kein Hinweis, unverändertes Symbol.

Der häufigste Fall ist eine nicht installierte Abhängigkeit: Dann wird ausdrücklich genannt, ob macFUSE oder ntfs-3g fehlt, und auf die Seite „Systemabhängigkeiten“ zur Installation verwiesen.

### 12.3 Rechtsklick auf das Symbol

Das Menü enthält: Hauptfenster, Geräteliste aktualisieren, Alle lesen & schreiben, Alle ausbinden, Einstellungen, Beenden.

## 13. Finder-Integration

Die Anwendung enthält eine Finder-Erweiterung. Sie fügt Volumes unter `/Volumes` um zwei Dinge ergänzt.

### 13.1 Volume-Badge

Betrachtet man im Finder das Symbol eines Volume, erscheint unten rechts ein kleines Badge mit dem aktuellen Status: **Lesen & Schreiben**, **Nur Lesen**, **Nicht eingebunden**. So wissen Sie, ob dieses Laufwerk derzeit beschreibbar ist, ohne zur Anwendung zurückzukehren.

### 13.2 Kontextmenü und Symbolleiste

In der Finder-Symbolleiste erscheint eine Schaltfläche dieser Anwendung; ein Klick darauf ergibt „NTFSMount öffnen“. Ein Rechtsklick auf ein Volume unter `/Volumes` bringt eine zusätzliche Gruppe von Menüpunkten hervor:

- Als Lesen & Schreiben einbinden
- Ausbinden
- Nur Lesen wiederherstellen
- Auswerfen
- Volume zurücksetzen (ntfsfix)
- In NTFSMount anzeigen

So lassen sich die Aktionen direkt im Finder ausführen, ohne zum Hauptfenster zurückzuwechseln.

> [!NOTE]
> Die Finder-Erweiterung wird vom System bei Bedarf geladen; bei der ersten Verwendung kann es etwas dauern, bis sie im Menü erscheint. Erscheint sie dauerhaft nicht, prüfen Sie unter „Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Finder-Erweiterungen“, ob sie aktiviert ist.

## 14. Aktionsprotokoll

Die Seite „Aktionsprotokoll“ zeichnet Zeitpunkt, Inhalt und Ergebnis jeder Aktion auf. Sie ist standardmäßig deaktiviert; die Aufzeichnung beginnt erst, wenn Sie unter „Einstellungen → Allgemein“ die Option „Aktionsprotokoll aktivieren“ einschalten.

Im Panel können Sie das Protokoll leeren oder als Textdatei exportieren. Das Protokoll wird ausschließlich im Application-Support-Verzeichnis dieses Rechners geschrieben und nirgendwohin hochgeladen.

Wenn Sie bei einem Problem Feedback geben möchten, fügen Sie bitte das exportierte Protokoll bei – die darin enthaltene Fehlerursache ist meist der Schlüssel zur Beurteilung des Problems; allein aus einer Beschreibung der Symptome lässt sich oft nichts ableiten.

## 15. Fehlerbehebung nach Symptom

| Was Sie sehen | Die tatsächliche Ursache | Was zu tun ist |
| --- | --- | --- |
| Mein Laufwerk erscheint nicht in der Liste | Die Partition ist nicht NTFS; oder das Gerät wurde vom System noch nicht erkannt | Vergewissern Sie sich zunächst, dass das Laufwerk tatsächlich im NTFS-Format vorliegt; ziehen Sie es ab und stecken Sie es erneut an; klicken Sie auf „Aktualisieren“ |
| Es wird gemeldet, dass macFUSE / ntfs-3g fehlt | Abhängigkeit nicht installiert | Gehen Sie zur Seite „Systemabhängigkeiten“ und installieren Sie nach Anleitung |
| Es wird „Windows is hibernated“ gemeldet | Windows hat den Schnellstart aktiviert, das Volume ist durch die Hibernationsdatei belegt | Stecken Sie das Laufwerk an Windows an, führen Sie `shutdown /s /t 0` für ein vollständiges Herunterfahren aus und stecken Sie es dann wieder an |
| Es wird „Resource busy“ gemeldet | Ein Programm verwendet dieses Laufwerk gerade | Schließen Sie das belegende Programm; oder verwenden Sie die Schaltfläche „Zurücksetzen“ |
| Es wird gemeldet, dass die Berechtigung nicht ausreicht | Die Systemerweiterung von macFUSE wurde nicht genehmigt | Erlauben Sie macFUSE unter „Systemeinstellungen → Datenschutz & Sicherheit“ und starten Sie dann neu |
| Es wird ein falsches Passwort gemeldet | Das gespeicherte Passwort ist ungültig geworden | Geben Sie es in den Einstellungen erneut ein und speichern Sie es einmal |
| Nach dem Einbinden lässt sich nichts schreiben | Tatsächlich liegt noch eine Nur-Lesen-Einbindung vor | Prüfen Sie, ob der Status dieser Zeile „Lesen & Schreiben“ ist; falls nicht, klicken Sie erneut auf „Lesen & Schreiben“ |
| Das Laufwerk fällt mitten in der Übertragung aus | Hardware- oder Versorgungsproblem | Tauschen Sie Kabel und Anschluss; vermeiden Sie USB-Hubs ohne eigene Stromversorgung |
| Die Finder-Erweiterung erscheint nicht | Erweiterung nicht aktiviert | Prüfen Sie unter „Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen“, ob sie aktiviert ist |

## 16. Deinstallation und vollständige Bereinigung

1. Stellen Sie zunächst alle NTFS-Geräte auf „Nur Lesen wiederherstellen“ oder „Auswerfen“ um; lassen Sie sie nicht im Lesen-&-Schreiben-Zustand stehen.
2. Beenden Sie die Anwendung. Rechtsklick auf das Menüleisten-Symbol → Beenden, oder ⌘Q.
3. Schalten Sie unter „Einstellungen → Systemintegration“ die Option „Systemstart“ aus – sonst kehrt sie nach einem Neustart zurück.
4. Ziehen Sie die Anwendung aus dem Ordner „Programme“ in den Papierkorb.
5. Falls Sie „Administratorpasswort speichern“ aktiviert hatten, suchen Sie in der „Schlüsselbundverwaltung“ nach der Bundle-Kennung dieser Anwendung und löschen Sie den betreffenden Eintrag.
6. Wenn Sie NTFS nicht mehr einbinden müssen, können Sie die beiden Abhängigkeiten mit entfernen. Bei Homebrew lauten sie `brew uninstall ntfs-3g-mac` und `brew uninstall --cask macfuse`, bei MacPorts `sudo port uninstall ntfs-3g macfuse`.

Die Konfigurationsdateien der Anwendung liegen unter `~/Library/Application Support/NTFSMount/`; das Löschen dieses Verzeichnisses entfernt alle Einstellungen.
