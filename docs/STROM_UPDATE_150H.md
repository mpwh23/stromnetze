# Update 150h – Git deploy key und orientierter Kamerastart
- Die GitHub-Phase verwendet den etablierten Root-SSH-Deploy-Key (github-stromnetze).
- Die Draufsicht nutzt die längere Gebäudeachse als Bildschirm-Horizontalachse; Hochkant-Grundrisse werden entsprechend um 90 Grad gedreht.
- Identische Start-/Zielausrichtung in beiden Kameraflugrichtungen.
- OrbitControls-Sperre, 500 ms Überblendung, 1500 ms Kameraflug, Ladeindikator und Lade-Absicherung bleiben unverändert.
- Isolierter TypeScript/Vite-Build vor Git-Push; anschließend Stage-Update mit Backup und Deployment nur nach /strom-test/.
