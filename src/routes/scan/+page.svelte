<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import NavBar from '$lib/components/NavBar.svelte';
  import Sheet from '$lib/components/Sheet.svelte';
  import ItemSheet from '$lib/components/ItemSheet.svelte';
  import RoomSketch from '$lib/components/RoomSketch.svelte';
  import { capture, MAX_BOXES, type NewItem, type Room, type StoredItem } from '$lib/stores/capture.svelte';
  import { BOX_VOLUME_M3, canScanRooms, movableObjects, RoomPlan, SCAN_DEBUG } from '$lib/plugins/roomplan';
  import { tapHaptic, successHaptic, errorHaptic } from '$lib/haptics';
  import { Box, Camera, ChevronRight, CircleAlert, Minus, Plus, ScanLine, Package, X } from 'lucide-svelte';

  const roomPresets = ['Wohnzimmer', 'Schlafzimmer', 'Küche', 'Kinderzimmer', 'Arbeitszimmer', 'Esszimmer', 'Flur', 'Bad', 'Keller', 'Dachboden', 'Garage', 'Balkon'];

  /** null until known; LiDAR iPhones scan rooms, everything else enters items by hand. */
  let canScan: boolean | null = $state(null);
  let scanningRoomId: string | null = $state(null);
  let notice: { tone: 'error' | 'info'; text: string } | null = $state(null);

  let addRoomOpen = $state(false);
  let newRoomName = $state('');
  let menuRoom: Room | null = $state(null);
  let renameValue = $state('');
  let confirmDelete = $state(false);
  let itemSheet: { roomId: string; item: StoredItem | null } | null = $state(null);

  onMount(async () => {
    canScan = await canScanRooms();
  });

  const invalid = $derived(capture.invalidItemIds);

  function m3(v: number) {
    return v.toFixed(v < 1 ? 2 : 1).replace('.', ',');
  }

  function roomVolume(room: Room) {
    return room.items.reduce((s, i) => s + (i.volumeM3 ?? 0), 0);
  }

  /** "Kleinteile (14 Stück, ≈ 2 Kartons)" — the small leftovers of one scan. */
  function smallItemsLabel(count: number, boxes: number) {
    return `Kleinteile (${count} Stück, ≈ ${boxes} ${boxes === 1 ? 'Karton' : 'Kartons'})`;
  }

  /** One line of what the scan's leftover measurement saw, for TestFlight testing. */
  function diagnosticsText(d: Record<string, unknown>) {
    const rejected = Object.entries((d.rejected as Record<string, number>) ?? {}).map(([k, v]) => `${k} ${v}`).join(', ');
    return `Scan: ${d.source} · ${d.points} Punkte → ${d.kept} übrig → ${d.clusters} Inseln → ${d.leftovers} vermessen`
      + ` · Fotos ${d.photos ?? 0}/${d.leftovers} aus ${d.keyframes} Bildern`
      + (rejected ? ` · verworfen: ${rejected}` : '');
  }

  function dimsText(dimsM: number[]) {
    return dimsM.map(d => Math.round(d * 100)).join(' × ') + ' cm';
  }

  async function scan(room: Room, isNew: boolean) {
    notice = null;
    scanningRoomId = room.id;
    try {
      const result = await RoomPlan.scanRoom({ roomName: room.name });
      if (result.cancelled) {
        // Backing out of the first scan of a room just created means "never mind".
        if (isNew && room.items.length === 0) capture.removeRoom(room.id);
        return;
      }
      if (result.diagnostics) console.info('RoomPlan leftovers', result.diagnostics);
      const { items: found, fixtures, small } = movableObjects(result.objects);
      const scanned: NewItem[] = found.map(o => ({
        label: o.label,
        source: 'scan',
        frames: o.imageBase64 ? [{ imageBase64: o.imageBase64, depthMapBase64: null, pose: null }] : [],
        hasDepth: true,
        volumeM3: o.volumeM3,
        dimsM: o.dimsM,
        deviceConfidence: o.confidence,
        ...(o.footprint ? { footprints: [o.footprint] } : {}),
      }));
      if (small.count > 0) {
        scanned.push({
          label: smallItemsLabel(small.count, small.boxes),
          source: 'scan',
          frames: [],
          hasDepth: true,
          volumeM3: small.boxes * BOX_VOLUME_M3,
          dimsM: null,
          deviceConfidence: null,
          footprints: small.footprints,
        });
      }
      const plan = result.walls ? { walls: result.walls, fixtures } : undefined;
      capture.applyScan(room.id, scanned, plan, result.diagnostics);
      successHaptic();
      if (scanned.length === 0) {
        notice = { tone: 'info', text: `In „${room.name}“ wurden keine Möbel erkannt. Sie können Gegenstände von Hand hinzufügen.` };
      }
    } catch (e: any) {
      errorHaptic();
      if (isNew && room.items.length === 0) capture.removeRoom(room.id);
      notice = {
        tone: 'error',
        text: e?.code === 'CAMERA_DENIED'
          ? 'Bitte erlauben Sie den Kamerazugriff in den Einstellungen, um Räume zu scannen.'
          : 'Der Scan hat nicht geklappt. Bitte versuchen Sie es erneut.',
      };
    } finally {
      scanningRoomId = null;
    }
  }

  function openAddRoom() {
    tapHaptic();
    newRoomName = '';
    addRoomOpen = true;
  }

  function createRoom(withScan: boolean) {
    const name = newRoomName.trim();
    if (!name) return;
    tapHaptic();
    addRoomOpen = false;
    const room = capture.addRoom(name);
    if (withScan) scan(room, true);
    else itemSheet = { roomId: room.id, item: null };
  }

  function openRoomMenu(room: Room) {
    tapHaptic();
    menuRoom = room;
    renameValue = room.name;
    confirmDelete = false;
  }

  function saveItem(item: NewItem) {
    if (!itemSheet) return;
    if (itemSheet.item) capture.updateItem(itemSheet.roomId, itemSheet.item.id, item);
    else capture.addItem(itemSheet.roomId, item);
    itemSheet = null;
  }

  function setBoxes(n: number) {
    capture.boxes = Math.max(0, Math.min(MAX_BOXES, Math.round(n) || 0));
  }

  function next() {
    tapHaptic();
    goto('/scan/form');
  }
</script>

<NavBar title="Ihr Umzugsgut" back="/" />

<main
  class="px-4 max-w-lg mx-auto rise-in"
  style="padding-top: calc(3rem + env(safe-area-inset-top, 0px) + 1rem); padding-bottom: calc(8rem + env(safe-area-inset-bottom, 0px));"
>
  {#if notice}
    <div class="ios-card mb-5 p-4 flex gap-3 items-start"
      style="background: {notice.tone === 'error' ? 'var(--ios-red-soft)' : 'var(--ios-tint-soft)'};">
      <CircleAlert size={18} class="shrink-0 mt-0.5 {notice.tone === 'error' ? 'text-red' : 'text-tint'}" />
      <p class="flex-1 text-[14px] text-label">{notice.text}</p>
      <button onclick={() => (notice = null)} aria-label="Hinweis schließen" class="text-label-2"><X size={16} /></button>
    </div>
  {/if}

  {#if capture.rooms.length === 0}
    <div class="text-center pt-6 pb-8">
      <div class="w-16 h-16 rounded-full bg-tint-soft text-tint flex items-center justify-center mx-auto mb-4">
        {#if canScan}<ScanLine size={28} strokeWidth={1.8} />{:else}<Box size={28} strokeWidth={1.8} />{/if}
      </div>
      <h1 class="text-[22px] font-bold text-label tracking-tight mb-2">Raum für Raum</h1>
      <p class="text-[15px] text-label-2 max-w-xs mx-auto">
        {#if canScan}
          Scannen Sie jeden Raum mit der Kamera — Möbel werden automatisch erkannt und vermessen.
        {:else}
          Tragen Sie Ihre Möbel je Raum ein — mit Maßen oder einem Foto.
        {/if}
      </p>
    </div>
  {/if}

  {#each capture.rooms as room (room.id)}
    <div class="ios-card mb-5 overflow-hidden">
      <button onclick={() => openRoomMenu(room)} class="ios-row w-full flex items-center gap-3 px-4 py-3 text-left tappable">
        <div class="flex-1 min-w-0">
          <p class="text-[17px] font-semibold text-label truncate">{room.name}</p>
          <p class="text-[13px] text-label-2">
            {room.items.length} {room.items.length === 1 ? 'Gegenstand' : 'Gegenstände'}{#if room.items.length > 0}{` · ≈ ${m3(roomVolume(room))} m³`}{/if}
          </p>
        </div>
        <ChevronRight size={18} class="text-label-3 shrink-0" />
      </button>

      {#if scanningRoomId === room.id}
        <div class="ios-row flex items-center gap-3 px-4 py-3">
          <span class="ios-spinner" style="width: 18px; height: 18px;"></span>
          <span class="text-[15px] text-label-2">Scan läuft …</span>
        </div>
      {/if}

      {#each room.items as item (item.id)}
        <button onclick={() => { tapHaptic(); itemSheet = { roomId: room.id, item }; }}
          class="ios-row w-full flex items-center gap-3 px-4 py-2.5 text-left tappable">
          {#if item.frames[0]}
            <img src="data:image/jpeg;base64,{item.frames[0].imageBase64}" alt=""
              class="w-8 h-8 rounded-lg object-cover shrink-0 {invalid.has(item.id) ? 'ring-2 ring-red' : ''}" />
          {:else if room.plan && item.footprints?.length && !invalid.has(item.id)}
            <div class="w-8 h-8 rounded-lg bg-fill shrink-0 p-0.5">
              <RoomSketch plan={room.plan} highlight={item.footprints} compact />
            </div>
          {:else}
            <div class="w-8 h-8 rounded-lg flex items-center justify-center shrink-0
              {invalid.has(item.id) ? 'bg-red-soft text-red' : 'bg-tint-soft text-tint'}">
              {#if item.source === 'scan'}<ScanLine size={15} />{:else if item.volumeM3 == null}<Camera size={15} />{:else}<Box size={15} />{/if}
            </div>
          {/if}
          <div class="flex-1 min-w-0">
            <p class="text-[15px] truncate {item.label ? 'text-label' : 'text-label-3 italic'}">{item.label || (item.source === 'scan' ? 'Unbekannter Gegenstand' : 'Ohne Bezeichnung')}</p>
            <p class="text-[12px] text-label-2">
              {#if item.dimsM}{dimsText(item.dimsM)}{:else if item.volumeM3 == null}Größe wird geschätzt{:else}Volumen angegeben{/if}
            </p>
          </div>
          {#if invalid.has(item.id)}
            <span class="text-[13px] font-semibold text-red">Prüfen</span>
          {:else if item.volumeM3 != null}
            <span class="text-[13px] font-semibold text-label">≈ {m3(item.volumeM3)} m³</span>
          {/if}
        </button>
      {/each}

      <div class="ios-row flex">
        <button onclick={() => { tapHaptic(); itemSheet = { roomId: room.id, item: null }; }}
          class="flex-1 h-11 flex items-center justify-center gap-1.5 text-[15px] text-tint tappable">
          <Plus size={17} /> Gegenstand
        </button>
        {#if canScan}
          <button onclick={() => { tapHaptic(); scan(room, false); }} disabled={scanningRoomId !== null}
            class="flex-1 h-11 flex items-center justify-center gap-1.5 text-[15px] text-tint tappable border-l-[0.5px] border-separator disabled:opacity-40">
            <ScanLine size={17} /> {room.scanned ? 'Erneut scannen' : 'Scannen'}
          </button>
        {/if}
      </div>
    </div>
    {#if SCAN_DEBUG && room.diagnostics}
      <p class="text-[11px] text-label-3 px-4 -mt-3 mb-5 break-all">{diagnosticsText(room.diagnostics)}</p>
    {/if}
  {/each}

  <button onclick={openAddRoom} disabled={scanningRoomId !== null}
    class="{capture.rooms.length === 0 ? 'btn-filled' : 'btn-tinted'} w-full mb-8 disabled:opacity-40">
    <Plus size={19} />
    {capture.rooms.length === 0 ? 'Ersten Raum hinzufügen' : 'Raum hinzufügen'}
  </button>

  <p class="ios-section-header">Umzugskartons</p>
  <div class="ios-card px-4 py-3 mb-2 flex items-center gap-3">
    <Package size={20} class="text-tint shrink-0" />
    <span class="flex-1 text-[15px] text-label">Für die ganze Wohnung</span>
    <div class="flex items-center bg-fill rounded-lg">
      <button onclick={() => { tapHaptic(); setBoxes(capture.boxes - 1); }} aria-label="Weniger Kartons"
        class="w-9 h-8 flex items-center justify-center text-label disabled:opacity-30" disabled={capture.boxes === 0}>
        <Minus size={16} />
      </button>
      <input
        value={capture.boxes}
        onchange={(e) => setBoxes(Number(e.currentTarget.value))}
        inputmode="numeric"
        aria-label="Anzahl Kartons"
        class="w-11 h-8 text-center text-[15px] font-semibold text-label bg-transparent outline-none"
      />
      <button onclick={() => { tapHaptic(); setBoxes(capture.boxes + 1); }} aria-label="Mehr Kartons"
        class="w-9 h-8 flex items-center justify-center text-label disabled:opacity-30" disabled={capture.boxes >= MAX_BOXES}>
        <Plus size={16} />
      </button>
    </div>
  </div>
  <p class="text-[12px] text-label-2 px-4">
    {#if capture.rooms.some(r => r.scanned)}Kleinteile, die beim Scan offen herumstanden, sind schon eingerechnet. Hier zählt, was in Schränken und Regalen steckt.{:else}Eine grobe Schätzung reicht.{/if}
    Wir rechnen 0,1 m³ pro Karton.
  </p>
</main>

<!-- Bottom action bar -->
<div class="fixed bottom-0 left-0 w-full z-50 tab-bar" style="padding-bottom: env(safe-area-inset-bottom, 0px);">
  <div class="max-w-lg mx-auto px-4 py-3 flex items-center gap-4">
    <div class="flex-1 min-w-0">
      {#if invalid.size > 0}
        <p class="text-[13px] font-semibold text-red">Bitte markierte Gegenstände prüfen</p>
      {:else if capture.itemCount === 0}
        <p class="text-[15px] text-label-2">Noch nichts erfasst</p>
      {:else}
        <p class="text-[17px] font-bold text-label">≈ {m3(capture.knownVolumeM3)} m³</p>
        <p class="text-[12px] text-label-2">{capture.itemCount} {capture.itemCount === 1 ? 'Position' : 'Positionen'}</p>
      {/if}
    </div>
    <button onclick={next} disabled={capture.itemCount === 0 || invalid.size > 0 || scanningRoomId !== null}
      class="btn-filled px-8">
      Weiter
    </button>
  </div>
</div>

{#if addRoomOpen}
  <Sheet title="Raum hinzufügen" onclose={() => (addRoomOpen = false)}>
    <div class="flex flex-wrap gap-2 mb-4">
      {#each roomPresets as preset}
        <button onclick={() => { tapHaptic(); newRoomName = preset; }}
          class="h-9 px-4 rounded-full text-[14px] font-medium {newRoomName === preset ? 'bg-tint text-on-tint' : 'bg-fill text-label'}">
          {preset}
        </button>
      {/each}
    </div>
    <div class="ios-card px-4 mb-5">
      <input bind:value={newRoomName} placeholder="Oder eigener Name" class="ios-input" />
    </div>
    {#if canScan}
      <p class="text-[13px] text-label-2 px-1 mb-4">
        Gehen Sie langsam durch den Raum und richten Sie die Kamera auf alle Möbel — auch in die Ecken.
      </p>
      <button onclick={() => createRoom(true)} disabled={!newRoomName.trim()} class="btn-filled w-full mb-2">
        <ScanLine size={19} /> Raum scannen
      </button>
      <button onclick={() => createRoom(false)} disabled={!newRoomName.trim()} class="btn-gray w-full disabled:opacity-40">
        Ohne Scan, selbst eintragen
      </button>
    {:else}
      <button onclick={() => createRoom(false)} disabled={!newRoomName.trim()} class="btn-filled w-full">
        Hinzufügen
      </button>
    {/if}
  </Sheet>
{/if}

{#if menuRoom}
  {@const room = menuRoom}
  <Sheet title={room.name} onclose={() => (menuRoom = null)}>
    <p class="ios-section-header">Name</p>
    <div class="ios-card px-4 mb-2 flex items-center gap-2">
      <input bind:value={renameValue} class="ios-input" />
      {#if renameValue.trim() && renameValue.trim() !== room.name}
        <button onclick={() => { tapHaptic(); capture.renameRoom(room.id, renameValue); menuRoom = null; }}
          class="text-[15px] font-semibold text-tint shrink-0">Sichern</button>
      {/if}
    </div>
    {#if canScan && room.scanned}
      <p class="text-[12px] text-label-2 px-4 mb-5">
        Erneutes Scannen ersetzt die gescannten Möbel dieses Raums. Selbst eingetragene bleiben erhalten.
      </p>
    {:else}
      <div class="mb-5"></div>
    {/if}
    <button
      onclick={() => {
        tapHaptic();
        if (!confirmDelete) { confirmDelete = true; return; }
        capture.removeRoom(room.id);
        menuRoom = null;
      }}
      class="btn-gray w-full text-red"
    >
      {confirmDelete ? `„${room.name}“ wirklich löschen?` : 'Raum löschen'}
    </button>
  </Sheet>
{/if}

{#if itemSheet}
  {@const target = itemSheet}
  {@const room = capture.rooms.find(r => r.id === target.roomId)}
  <ItemSheet
    item={target.item}
    plan={room?.plan}
    others={(room?.items ?? []).filter(i => i.id !== target.item?.id).flatMap(i => i.footprints ?? [])}
    requireSize={canScan === true}
    onsave={saveItem}
    ondelete={target.item ? () => { capture.removeItem(target.roomId, target.item!.id); itemSheet = null; } : undefined}
    onclose={() => (itemSheet = null)}
  />
{/if}
