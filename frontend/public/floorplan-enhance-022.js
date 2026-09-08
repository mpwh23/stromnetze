(() => {
  const LS_TITLE_KEY = 'strom.floorplan.titleOffsets.v2';
  const HELP_ID = 'strom-floorplan-help-backdrop';

  const helpHtml = `
    <div class="floorplan-help-card" role="dialog" aria-modal="true" aria-label="Grundriss Hilfe">
      <button type="button" class="floorplan-help-close" aria-label="Schliessen">×</button>
      <h2>Grundriss: Bedienung</h2>
      <div class="floorplan-help-grid">
        <section><h3>Auswahl</h3><p>Pfeil-Werkzeug: Raum anklicken, verschieben oder freie Canvas-Flaeche ziehen.</p><p><kbd>Shift</kbd> beim Verschieben: nur horizontal oder vertikal.</p><p>Klick auf freie Flaeche hebt die Auswahl auf.</p></section>
        <section><h3>Rechteck</h3><p>Rechteck-Werkzeug: erster Klick setzt die Ecke, Maus aufziehen, zweiter Klick erstellt den Raum.</p><p>Werte werden in der Eigenschaftenleiste live angezeigt und koennen dort angepasst werden.</p></section>
        <section><h3>Polygon</h3><p>Punkte per Klick setzen. Doppelklick oder Klick auf den Startpunkt schliesst das Polygon.</p><p><kbd>Shift</kbd>: naechster Punkt rastet waagerecht, senkrecht oder 45° ein. <kbd>Ruecktaste</kbd>: letzter Punkt zurueck.</p></section>
        <section><h3>Bearbeiten</h3><p>Rechtecke ueber Seiten-Handles aendern. Polygone ueber Punkt-Handles bearbeiten.</p><p>Pfeiltasten bewegen die Auswahl, <kbd>Shift</kbd> + Pfeiltaste groesserer Schritt.</p></section>
        <section><h3>Aussparung</h3><p>Raum auswaehlen, Aussparungswerkzeug anklicken, Rechteck in den Raum zeichnen.</p><p>Floating-Fenster und Handles bearbeiten die Aussparung. Erst <strong>OK</strong> verbindet die Form.</p></section>
        <section><h3>Bemaszung</h3><p>Button ⌁ schaltet technische Bemaszung an/aus.</p><p>Einzelne Masslinien ziehen. <kbd>Shift</kbd> zieht Teil- und Gesamtlinie als Paar.</p></section>
        <section><h3>Zoom und Ansicht</h3><p>Mausrad zoomt am Mauszeiger. Plus/Minus und 100% steuern die Groesse.</p><p>Center-All zeigt alle Elemente passend im Canvas.</p></section>
        <section><h3>Titel</h3><p>Raumname oder Flaechenanzeige direkt ziehen, um die Beschriftung zu verschieben.</p></section>
      </div>
    </div>`;

  function readStore() {
    try { return JSON.parse(localStorage.getItem(LS_TITLE_KEY) || '{}') || {}; } catch { return {}; }
  }
  function writeStore(value) {
    try { localStorage.setItem(LS_TITLE_KEY, JSON.stringify(value)); } catch {}
  }
  function svgPoint(svg, ev) {
    const point = svg.createSVGPoint();
    point.x = ev.clientX;
    point.y = ev.clientY;
    const ctm = svg.getScreenCTM();
    if (!ctm) return { x: ev.clientX, y: ev.clientY };
    return point.matrixTransform(ctm.inverse());
  }
  function titleKey(group, label) {
    const name = (group.querySelector('.room-label')?.textContent || label.textContent || '').trim();
    const measure = (group.querySelector('.room-measure')?.textContent || '').trim();
    let box = { x: 0, y: 0, width: 0, height: 0 };
    try { box = group.querySelector('.room')?.getBBox?.() || group.getBBox(); } catch {}
    return `${name}|${measure}|${Math.round(box.x)}|${Math.round(box.y)}|${Math.round(box.width)}|${Math.round(box.height)}`;
  }
  function getOffset(node) {
    const raw = node.dataset.stromTitleOffset || '0,0';
    const [x, y] = raw.split(',').map(Number);
    return { x: Number.isFinite(x) ? x : 0, y: Number.isFinite(y) ? y : 0 };
  }
  function setOffset(node, x, y) {
    node.dataset.stromTitleOffset = `${x},${y}`;
    node.setAttribute('transform', `translate(${x} ${y})`);
  }

  function ensureHelpUi() {
    if (!document.getElementById(HELP_ID)) {
      const backdrop = document.createElement('div');
      backdrop.id = HELP_ID;
      backdrop.className = 'floorplan-help-backdrop';
      backdrop.hidden = true;
      backdrop.innerHTML = helpHtml;
      document.body.appendChild(backdrop);
      backdrop.addEventListener('click', (event) => {
        if (event.target === backdrop || event.target.closest('.floorplan-help-close')) backdrop.hidden = true;
      });
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') backdrop.hidden = true;
      });
    }

    const toolbarRow = document.querySelector('.canvas-toolbar-row');
    const toolbar = toolbarRow || document.querySelector('.canvas-toolbox, [aria-label="Grundriss Werkzeuge"]');
    if (!toolbar || toolbar.dataset.stromHelpAdded === '1') return;
    toolbar.dataset.stromHelpAdded = '1';
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'floorplan-toolbar-help-button';
    button.title = 'Hilfe und Bedienung zum Grundriss';
    button.setAttribute('aria-label', 'Hilfe und Bedienung zum Grundriss');
    button.textContent = '?';
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      const modal = document.getElementById(HELP_ID);
      if (modal) modal.hidden = false;
    });
    toolbar.appendChild(button);
  }

  function installTitleDrag() {
    const store = readStore();
    document.querySelectorAll('svg .room-label, svg .room-measure').forEach((textNode) => {
      const group = textNode.closest('.room-group');
      if (!group || textNode.dataset.stromTitleDrag === '1') return;
      textNode.dataset.stromTitleDrag = '1';
      textNode.style.pointerEvents = 'auto';
      textNode.style.cursor = 'move';
      const targets = Array.from(group.querySelectorAll('.room-label, .room-measure'));
      const key = titleKey(group, textNode);
      if (store[key]) targets.forEach((target) => setOffset(target, store[key].x || 0, store[key].y || 0));

      textNode.addEventListener('pointerdown', (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
        const svg = textNode.ownerSVGElement;
        if (!svg) return;
        const start = svgPoint(svg, event);
        const startOffset = getOffset(textNode);
        const pointerId = event.pointerId;
        textNode.setPointerCapture?.(pointerId);
        const move = (moveEvent) => {
          moveEvent.preventDefault();
          moveEvent.stopPropagation();
          const p = svgPoint(svg, moveEvent);
          const dx = p.x - start.x;
          const dy = p.y - start.y;
          targets.forEach((target) => setOffset(target, startOffset.x + dx, startOffset.y + dy));
        };
        const up = () => {
          textNode.releasePointerCapture?.(pointerId);
          textNode.removeEventListener('pointermove', move);
          textNode.removeEventListener('pointerup', up);
          textNode.removeEventListener('pointercancel', up);
          const nextStore = readStore();
          nextStore[key] = getOffset(textNode);
          writeStore(nextStore);
        };
        textNode.addEventListener('pointermove', move);
        textNode.addEventListener('pointerup', up);
        textNode.addEventListener('pointercancel', up);
      }, { capture: true });
    });
  }

  function tick() {
    ensureHelpUi();
    installTitleDrag();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', tick);
  else tick();
  new MutationObserver(tick).observe(document.documentElement, { childList: true, subtree: true });
})();
