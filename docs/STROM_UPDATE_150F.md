# Update 150f – Geometrisch korrekte Blueprint/3D-Ausrichtung
- Physikalisch eindeutige Draufsicht: Blueprint X horizontal wird Welt X horizontal, Blueprint Y nach unten wird Welt Z nach unten.
- Die 3D-Kamerasteuerung darf waehrend des Kamera-Flugs die Orientierung nicht zurueckdrehen; sie wird voruebergehend eingefroren.
- Kamerasteuerung nach dem Flug bzw. beim Unmount wiederherstellen; auch spaete Control-Registrierung moeglich.
- 500 ms Ueberblendung, 1500 ms Ease-out-Flug und vorhandener Ladekreis bleiben unveraendert.
- Keine Aenderung an 3D-Geometrie, Blueprint-Daten, CSS oder Icons.
- Isolierter Build vor GitHub-Push; ausschliesslich Stage und /strom-test/, Produktion /strom/ unberuehrt.
