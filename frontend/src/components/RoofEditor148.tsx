import { useEffect, useState, type ChangeEvent } from 'react'
import { readRoofSlopes148, saveRoofSlopes148, ROOF_EVENT148, type RoofSlope148 } from '../building/roofSlopes148'
import { cleanSlab149, levelElevations149, inheritRoofPlane149 } from '../building/levelGeometry149'

const dirs=[{value:0,label:'→ Osten / rechts'},{value:90,label:'↓ Süden / unten'},{value:180,label:'← Westen / links'},{value:270,label:'↑ Norden / oben'}]
const value=(num:number)=>Number.isFinite(num)?num:0
export default function RoofEditor148({floorId,roofId,onClose,onChanged}: {
  floorId:string;roofId:string;onClose:()=>void;onChanged?:()=>void
}) {
  const [draft,setDraft]=useState<RoofSlope148|null>(null)
  const [notice,setNotice]=useState('')
  const [sourceRoofId149,setSourceRoofId149]=useState('')
  useEffect(()=>{
    setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    setNotice('')
  },[floorId,roofId])
  useEffect(()=>{
    const refresh=()=>setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    window.addEventListener(ROOF_EVENT148,refresh)
    return ()=>window.removeEventListener(ROOF_EVENT148,refresh)
  },[floorId,roofId])
  if(!draft)return null
  const patch=(next:Partial<RoofSlope148>)=>setDraft(current=>current?{...current,...next}:current)
  const numeric=(label:string,n:number,step:number,min:number,max:number,update:(val:number)=>void,unit:string)=>
    <label className="strom-roof-field148" key={label}>{label}
      <span><input type="number" value={Number(n.toFixed(3))} min={min} max={max} step={step}
        title={`${label} ${unit}`} onChange={(e:ChangeEvent<HTMLInputElement>)=>update(value(Number(e.target.value)))} />{unit}</span>
    </label>
  // 149: the same mathematical world-space roof plane can be reused across rooms and storeys.
  const otherRoofs149=readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id)
  function inherit149(){
    // Event handlers are closures: React state may become null after the render.
    // Explicitly narrow draft here, not only in the component render body.
    if (!draft) return
    const source=otherRoofs149.find(item=>item.id===sourceRoofId149)
    if(!source){setNotice('Bitte eine bestehende Dachschräge auswählen.');return}
    let layers:Array<{id:string;name:string;heightM:number;slabThicknessM:number}>=[]
    try {
      const raw:unknown=JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floorId}.list`)||'[]')
      if(Array.isArray(raw))layers=raw.flatMap((v:unknown)=>{
        if(!v||typeof v!=='object')return []
        const item=v as Record<string,unknown>
        if(typeof item.id!=='string'||!Number.isFinite(Number(item.heightM)))return []
        return [{id:item.id,name:String(item.name||item.id),heightM:Number(item.heightM),slabThicknessM:cleanSlab149(item.slabThicknessM)}]
      })
    }catch{/* invalid legacy storage is treated as missing */}
    if(!layers.some(item=>item.id===source.levelId)||!layers.some(item=>item.id===draft.levelId)){
      setNotice('Die gespeicherten Ebenenhöhen sind unvollständig. Bitte Ebenen im Blueprint prüfen.');return
    }
    const elevations=levelElevations149(layers)
    const inherited=inheritRoofPlane149(source,draft.start,draft.end,elevations[source.levelId],elevations[draft.levelId])
    setDraft({...draft,directionDeg:inherited.directionDeg,pitchDeg:inherited.pitchDeg,startHeightM:inherited.startHeightM})
    setNotice('Dachebene übernommen. Ihre absolute Höhe und Neigung stimmen mit der Vorlage überein. Zum Übernehmen speichern.')
  }
  function save() {
    if(!draft)return
    try {
      const list=readRoofSlopes148(floorId,window.localStorage)
      const position=list.findIndex(item=>item.id===draft.id)
      if(position<0)throw Error('Dachschräge nicht mehr vorhanden.')
      list[position]=draft
      saveRoofSlopes148(floorId,list)
      setNotice('Dachschräge gespeichert und in 2D/3D aktualisiert.')
      onChanged?.()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function remove() {
    if(!draft)return
    try {
      const list=readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id)
      saveRoofSlopes148(floorId,list)
      onChanged?.();onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  return <section className="strom-roof-editor148" aria-label="Dachschräge bearbeiten">
    <header><strong>Dachschräge · Eigenschaften</strong><button type="button" title="Schließen" onClick={onClose}>×</button></header>
    {numeric('Neigung',draft.pitchDeg,1,0,65,v=>patch({pitchDeg:v}),'°')}
    {numeric('Beginnhöhe',Math.round(draft.startHeightM*1000),50,-15000,15000,v=>patch({startHeightM:v/1000}),'mm')}
    <label className="strom-roof-field148">Steigungsrichtung
      <select title="Ausrichtung der ansteigenden Dachfläche" value={dirs.some(d=>d.value===draft.directionDeg)?draft.directionDeg:'custom'}
        onChange={(e:ChangeEvent<HTMLSelectElement>)=>{if(e.target.value!=='custom')patch({directionDeg:Number(e.target.value)})}}>
        {dirs.map(d=><option key={d.value} value={d.value}>{d.label}</option>)}
        <option value="custom">Frei / Winkel</option>
      </select>
    </label>
    {numeric('Ausrichtung als Winkel',draft.directionDeg,1,0,359,v=>patch({directionDeg:v}),'°')}
    <fieldset className="strom-roof-reference149" aria-label="Bestehende Dachfläche übernehmen">
      <legend>Dachebene aus vorhandener Schräge übernehmen</legend>
      <select title="Vorlage aus beliebiger Blueprint-Ebene auswählen" aria-label="Vorhandene Dachschräge" value={sourceRoofId149}
        onChange={event=>setSourceRoofId149(event.currentTarget.value)}>
        <option value="">Vorhandene Schräge wählen …</option>
        {otherRoofs149.map(item=><option key={item.id} value={item.id}>
          {item.levelId} · {item.roomId} · {item.pitchDeg}°
        </option>)}
      </select>
      <button type="button" disabled={!sourceRoofId149} onClick={inherit149} title="Gleiche geometrische Dachebene auch über Etagen hinweg übernehmen">Ebene übernehmen</button>
    </fieldset>
    <details open><summary>Position der Startlinie (mm) – im Blueprint auch ziehbar</summary>
      {numeric('Start X',draft.start.x*1000,50,-100000,100000,v=>patch({start:{...draft.start,x:v/1000}}),'mm')}
      {numeric('Start Y',draft.start.y*1000,50,-100000,100000,v=>patch({start:{...draft.start,y:v/1000}}),'mm')}
      {numeric('Ende X',draft.end.x*1000,50,-100000,100000,v=>patch({end:{...draft.end,x:v/1000}}),'mm')}
      {numeric('Ende Y',draft.end.y*1000,50,-100000,100000,v=>patch({end:{...draft.end,y:v/1000}}),'mm')}
    </details>
    <div className="strom-roof-actions148"><button type="button" onClick={save} title="Änderungen in Blueprint, Wanddetail und 3D Haus übernehmen">Speichern</button>
      <button type="button" onClick={remove} title="Diese Dachschräge löschen; andere Schrägen im Raum bleiben erhalten">Löschen</button></div>
    {notice&&<p role="status">{notice}</p>}
  </section>
}
