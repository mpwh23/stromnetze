import {levelElevationsDatum151} from '../building/coordinateReference151' // STROM151_COORDINATE_DATUM
import StromIcon from './StromIcon' // STROM169_ICONS
import { useEffect, useState, type ChangeEvent } from 'react'
import { readRoofSlopes148, saveRoofSlopes148, ROOF_EVENT148, type RoofSlope148 } from '../building/roofSlopes148'
import { cleanSlab149, inheritRoofPlane149 } from '../building/levelGeometry149'

// STROM149E_ROOF_EDITOR: names, visible selection, cross-level physical plane and close-on-apply.
const dirs=[{value:0,label:'→ Osten / rechts'},{value:90,label:'↓ Süden / unten'},{value:180,label:'← Westen / links'},{value:270,label:'↑ Norden / oben'}]
const value=(num:number)=>Number.isFinite(num)?num:0
function roofName149e(item:RoofSlope148,index:number){return item.name?.trim() || `Dachschräge ${index+1}`}

export default function RoofEditor148({floorId,roofId,onClose,onChanged,onSelectRoof149e}: {
  floorId:string;roofId:string;onClose:()=>void;onChanged?:()=>void;onSelectRoof149e?:(id:string)=>void
}) {
  const [draft,setDraft]=useState<RoofSlope148|null>(null)
  const [notice,setNotice]=useState('')
  const [sourceRoofId149,setSourceRoofId149]=useState('')
  useEffect(()=>{
    setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    setSourceRoofId149('');setNotice('')
  },[floorId,roofId])
  useEffect(()=>{
    const refresh=()=>setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    window.addEventListener(ROOF_EVENT148,refresh)
    return ()=>window.removeEventListener(ROOF_EVENT148,refresh)
  },[floorId,roofId])
  if(!draft)return null
  const patch=(next:Partial<RoofSlope148>)=>setDraft(current=>current?{...current,...next}:current)
  const numeric=(label:string,n:number,step:number,min:number,max:number,update:(val:number)=>void,unit:string)=><label className="strom-roof-field148" key={label}>{label}
    <span><input type="number" value={Number(n.toFixed(3))} min={min} max={max} step={step}
      title={`${label} ${unit}`} onChange={(e:ChangeEvent<HTMLInputElement>)=>update(value(Number(e.target.value)))} />{unit}</span>
  </label>

  const allRoofs149e=readRoofSlopes148(floorId,window.localStorage)
  const otherRoofs149=allRoofs149e.filter(item=>item.id!==draft.id)
  const named149e=(item:RoofSlope148)=>roofName149e(item,allRoofs149e.findIndex(v=>v.id===item.id))

  function applySource149e(source:RoofSlope148){
    if(!draft)return
    try{
      const raw:unknown=JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floorId}.list`)||'[]')
      const layers:Array<{id:string;heightM:number;slabThicknessM:number}>=Array.isArray(raw)?raw.flatMap((entry:unknown)=>{
        if(!entry||typeof entry!=='object')return []
        const obj=entry as Record<string,unknown>
        const height=Number(obj.heightM)
        return typeof obj.id==='string'&&Number.isFinite(height)?[{id:obj.id,heightM:height,slabThicknessM:cleanSlab149(obj.slabThicknessM)}]:[]
      }):[]
      // Same-level inheritance remains valid even if legacy levels lack metadata.
      const bothKnown=layers.some(item=>item.id===source.levelId)&&layers.some(item=>item.id===draft.levelId)
      if(!bothKnown&&source.levelId!==draft.levelId){
        setNotice('Ebene nicht gefunden. Bitte zuerst die vorhandenen Geschosse im Blueprint prüfen.');return
      }
      const elevations=bothKnown?levelElevationsDatum151(layers,floorId,window.localStorage):{}
      const zSource=bothKnown?elevations[source.levelId]:0
      const zTarget=bothKnown?elevations[draft.levelId]:0
      const converted=inheritRoofPlane149(source,draft.start,draft.end,zSource,zTarget)
      if(converted.startHeightM<-15||converted.startHeightM>15){
        setNotice('Übernahme nicht möglich: Anfangshöhe außerhalb des gültigen Bereichs.');return
      }
      // Never replace the target's id, room, name, level or start/end positions.
      patch({pitchDeg:converted.pitchDeg,directionDeg:converted.directionDeg,startHeightM:converted.startHeightM})
      setSourceRoofId149(source.id)
      setNotice(`Dachebene von „${named149e(source)}“ übernommen. Mit Anwenden speichern.`)
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function save(){
    if(!draft)return
    try{
      const list=readRoofSlopes148(floorId,window.localStorage)
      const index=list.findIndex(item=>item.id===draft.id)
      if(index<0)throw Error('Dachschräge nicht mehr vorhanden.')
      list[index]={...draft,name:draft.name?.trim().slice(0,60)||undefined}
      saveRoofSlopes148(floorId,list)
      onChanged?.()
      onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function remove(){
    if(!draft)return
    try{
      saveRoofSlopes148(floorId,readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id))
      onChanged?.();onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  return <section className="strom-roof-editor148" aria-label="Dachschräge bearbeiten">
    <header><strong>Dachschräge · Eigenschaften</strong><button type="button" title="Schließen" onClick={onClose}><StromIcon name="close" title="Schließen" /></button></header>
    <label className="strom-roof-field148">Name
      <input type="text" maxLength={60} value={draft.name??''} placeholder={named149e(draft)}
        onChange={(e:ChangeEvent<HTMLInputElement>)=>patch({name:e.target.value})}/>
    </label>
    {numeric('Neigung',draft.pitchDeg,1,0,65,v=>patch({pitchDeg:v}),'°')}
    {numeric('Beginnhöhe',Math.round(draft.startHeightM*1000),50,-15000,15000,v=>patch({startHeightM:v/1000}),'mm')}
    <label className="strom-roof-field148">Steigungsrichtung
      <select title="Ausrichtung der ansteigenden Dachfläche" value={dirs.some(item=>item.value===draft.directionDeg)?draft.directionDeg:'custom'}
        onChange={(e:ChangeEvent<HTMLSelectElement>)=>{if(e.target.value!=='custom')patch({directionDeg:Number(e.target.value)})}}>
        {dirs.map(d=><option key={d.value} value={d.value}>{d.label}</option>)}
        <option value="custom">Frei / Winkel</option>
      </select>
    </label>
    {numeric('Ausrichtung als Winkel',draft.directionDeg,1,0,359,v=>patch({directionDeg:v}),'°')}
    <fieldset className="strom-roof-reference149" aria-label="Bestehende Dachfläche übernehmen">
      <legend>Vorhandene Dachschrägen</legend>
      <label>Andere Schräge bearbeiten
        <select aria-label="Andere Dachschräge bearbeiten" value={draft.id} onChange={(event:ChangeEvent<HTMLSelectElement>)=>onSelectRoof149e?.(event.target.value)}>
          {allRoofs149e.map(item=><option key={item.id} value={item.id}>{named149e(item)} · {item.levelId}</option>)}
        </select>
      </label>
      <label>Dachebene übernehmen
        <select aria-label="Dachebene übernehmen von" value={sourceRoofId149}
          onChange={(event:ChangeEvent<HTMLSelectElement>)=>setSourceRoofId149(event.target.value)}>
          <option value="">Dachschräge auswählen …</option>
          {otherRoofs149.map(item=><option key={item.id} value={item.id}>{named149e(item)} · {item.levelId} · {item.pitchDeg}°</option>)}
        </select>
      </label>
      <button type="button" disabled={!sourceRoofId149} onClick={()=>{
        const source=otherRoofs149.find(item=>item.id===sourceRoofId149)
        if(source)applySource149e(source)
      }}>Dachebene übernehmen</button>
      <div className="strom-roof-reference-list149e" aria-label="Dachschrägen per Klick auswählen">
        {otherRoofs149.map(item=><div className="strom-roof-reference-entry149e" key={item.id}>
          <button type="button" onClick={()=>onSelectRoof149e?.(item.id)} title="Diese Dachschräge bearbeiten">{named149e(item)} · {item.levelId}</button>
          <button type="button" onClick={()=>applySource149e(item)} title="Parameter der vorhandenen Dachebene übernehmen">Kopieren</button>
        </div>)}
      </div>
    </fieldset>
    <details><summary>Start- und Endpunkte (mm)</summary>
      {numeric('Start X',draft.start.x*1000,50,-100000,100000,v=>patch({start:{...draft.start,x:v/1000}}),'mm')}
      {numeric('Start Y',draft.start.y*1000,50,-100000,100000,v=>patch({start:{...draft.start,y:v/1000}}),'mm')}
      {numeric('Ende X',draft.end.x*1000,50,-100000,100000,v=>patch({end:{...draft.end,x:v/1000}}),'mm')}
      {numeric('Ende Y',draft.end.y*1000,50,-100000,100000,v=>patch({end:{...draft.end,y:v/1000}}),'mm')}
    </details>
    <div className="strom-roof-actions148">
      <button type="button" onClick={save} title="Speichern und Fenster schließen">Anwenden</button>
      <button type="button" onClick={remove} title="Dachschräge löschen">Löschen</button>
    </div>
    {notice&&<p role="status">{notice}</p>}
  </section>
}
