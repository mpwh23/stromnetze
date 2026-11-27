# Strom 168: Blueprint-Zoom wie in anderen Programmen

## Ursachen (bis 167)
- React meldet `wheel` passiv an. `preventDefault()` im Blueprint wirkte nicht: Der Browser
  scrollte bei jeder Raste zusaetzlich um ca. 100 px, das Programm korrigierte ein Bild spaeter.
  Der Punkt unter dem Mauszeiger sprang (gemessen 112 px je Raste, 700 px nach 5 Rasten).
- Jedes Rad-Ereignis zoomte fest um 12 %. Ein Trackpad schickt Dutzende kleine Ereignisse:
  40 kleine Wischbewegungen zoomten von 100 % auf das Maximum 1000 %.
- Zwei-Finger-Zoom (Pinch, ctrlKey) vergroesserte die ganze Webseite statt der Zeichnung.
- Zoom und Scroll wurden in getrennten Bildern gesetzt; jedes Scroll-Ereignis baute den
  kompletten Blueprint-Editor neu auf (nur fuer die Lineale) und schrieb in den localStorage.
- Das obere Lineal lag 15 px neben dem Raster (Scrollbalken-Abstand links nicht beruecksichtigt).
- Zoomknoepfe aenderten linear um 15 Prozentpunkte und zoomten um die linke obere Ecke.

## Aenderungen
- Nativer, nicht-passiver wheel-Listener am Zeichenbereich; Zoom am Mauszeiger.
- Zoom proportional zur Raddrehung: Faktor 2^(-deltaY * 0,002), eine Raste = +14,9 %;
  Pinch zehnfach empfindlicher; Safari-Pinch ueber gesture-Ereignisse.
- Seitliches Wischen bzw. Shift+Mausrad verschiebt waagerecht.
- Alle Ereignisse eines Bildes werden gesammelt; Zeichnung wird synchron (flushSync)
  aktualisiert und im selben Bild gescrollt. Rundungsfehler von scrollLeft/Top summieren sich nicht.
- Lineale verschieben sich per transform mit der Zeichnung, ohne Neuaufbau des Editors.
- Ansicht wird hoechstens alle 200 ms gespeichert, beim Verlassen (z. B. nach 3D) sofort.
- Zoomknoepfe: x1,25 bzw. /1,25 um die Bildmitte; 100 % ebenfalls um die Bildmitte.
- Keine Hintergrund-Unschaerfe mehr unter Linealen und Werkzeugleisten (bei jedem Bild neu berechnet).
- Zoom wird stufenlos gespeichert (4 statt 2 Nachkommastellen).
- Hilfetext korrigiert (stand vorher: "Mausrad scrollt, Shift+Mausrad zoomt").
- Klassische Wandansicht unveraendert.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
