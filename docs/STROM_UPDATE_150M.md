# Update 150m: Kamerastart, Blende und Flug strikt entkoppelt
- Ersetzt die 150l-Renderbestaetigung durch eine deterministische R3F Frame-Sequenz.
- Kamera ist beim ersten 3D-Frame korrekt auf die Blueprint-ausgerichtete Vogelperspektive eingestellt.
- Drei weitere Frame-Ticks halten dieselbe Kamerapose, bevor die Original-Blueprint-Ebene mit Ladeindikator ausgeblendet wird.
- Waerend der vollen Blende (5000ms) wird dieselbe Kamerapose in JEDEM 3D-Frame erneut angewendet.
- Erst nach Ende der Blende beginnt die Ease-out-Fahrt (5000ms).
- Bei Rueckkehr startet die Kamera von der tatsaechlich gerenderten aktuellen Ansicht.
- OrbitControls wird waehrend Vorbereitung, Blende und Fahrt deaktiviert und erst danach wiederhergestellt.
- Die vorhandene Ladeoberflaeche, 3D-Geometrie, Icons, Modelldaten und die Produktionsansicht bleiben unveraendert.
- Isolierter TS/Vite Build und Kamera-Regressionstests vor GitHub-Push; danach Stage und /strom-test/ only.
