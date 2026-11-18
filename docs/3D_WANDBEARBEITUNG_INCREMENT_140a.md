# STROM 140a – Wandauswahl im echten 3D-Wanddetail

- Das 3D-Wandvolumen von 139 bleibt unverändert; `solidGeometry.ts` und `model.ts` werden nicht gepatcht.
- `wallHitSelection.ts` ordnet einen 3D-Mesh-Treffer einer Raumkante im gemeinsamen Blueprint-Modell zu.
- Klick auf eine Wand im echten Wanddetail öffnet die *bestehende* Frontalansicht samt Objektbibliothek.
- Bisherige Funktionen zum Einsetzen, Verschieben, Skalieren und Löschen von Wandobjekten nutzen weiterhin die bisherigen APIs und die Wandgruppen.
- Nach erfolgreichem Speichern/Löschen liest der 3D-Renderer die aktualisierten API-Wandobjekte erneut, damit Öffnungen direkt sichtbar werden.
- Türgruppenauswahl im 3D-Modell bleibt nutzbar.
- In `3D Haus` findet weiterhin nur Raumauswahl statt; die Wand-Popups sind ausschließlich im Wanddetail aktiv.
- Der alte Wanddetail-Editor ist weiterhin über den vorhandenen Button erreichbar.
- Blueprint, 3D-Volumen, Etagenlayout, Datenbankschema und Produktionssystem werden nicht umgebaut.
