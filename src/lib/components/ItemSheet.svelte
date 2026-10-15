<script lang="ts">
  import Sheet from './Sheet.svelte';
  import { boxVolume, MAX_ITEM_M3, MIN_ITEM_M3 } from '$lib/plugins/roomplan';
  import type { NewItem, StoredItem } from '$lib/stores/capture.svelte';
  import { tapHaptic } from '$lib/haptics';
  import { Camera, Trash2 } from 'lucide-svelte';

  let {
    item = null,
    requireSize,
    onsave,
    ondelete,
    onclose,
  }: {
    /** The item being edited, or null to add a new one. */
    item?: StoredItem | null;
    /**
     * On LiDAR phones every item needs a size: one photo-only item would send the
     * whole submission to server-side estimation and throw away the scanned volumes.
     */
    requireSize: boolean;
    onsave: (item: NewItem) => void;
    ondelete?: () => void;
    onclose: () => void;
  } = $props();

  const suggestions = ['Sofa', 'Bett', 'Schrank', 'Kommode', 'Regal', 'Tisch', 'Stuhl', 'Waschmaschine', 'Fahrrad'];

  // The sheet is mounted per open, so reading the prop once is intended.
  // svelte-ignore state_referenced_locally
  const initial = item;
  const cm = (m: number) => String(Math.round(m * 100));

  let name = $state(initial?.label ?? '');
  let mode: 'dims' | 'volume' = $state(initial && !initial.dimsM && initial.volumeM3 != null ? 'volume' : 'dims');
  /** Length, width, height in cm, as typed. */
  let dims = $state(initial?.dimsM ? initial.dimsM.map(cm) : ['', '', '']);
  let volume = $state(initial && !initial.dimsM && initial.volumeM3 != null ? fmt(initial.volumeM3) : '');
  let photo: string | null = $state(initial?.frames[0]?.imageBase64 ?? null);
  let error: string | null = $state(null);
  let fileInput: HTMLInputElement | undefined = $state();

  function fmt(v: number) {
    return (Math.round(v * 100) / 100).toString().replace('.', ',');
  }

  function num(s: string): number | null {
    const v = parseFloat(s.trim().replace(',', '.'));
    return Number.isFinite(v) && v > 0 ? v : null;
  }

  /** Volume + dims from the inputs; undefined when the inputs are unusable. */
  function measured(): { volumeM3: number | null; dimsM: number[] | null } | undefined {
    if (mode === 'volume') {
      if (!volume.trim()) return { volumeM3: null, dimsM: null };
      const v = num(volume);
      if (v == null) { error = 'Bitte ein gültiges Volumen eingeben, z. B. 1,5.'; return; }
      return { volumeM3: v, dimsM: null };
    }
    if (dims.every(s => !s.trim())) return { volumeM3: null, dimsM: null };
    const parsed = dims.map(num);
    if (parsed.some(d => d == null)) { error = 'Bitte Länge, Breite und Höhe in cm eingeben.'; return; }
    const dimsM = (parsed as number[]).map(d => d / 100);
    return { volumeM3: boxVolume(dimsM), dimsM };
  }

  function save() {
    error = null;
    const m = measured();
    if (!m) return;
    if (m.volumeM3 == null) {
      if (requireSize) { error = 'Bitte Maße oder Volumen angeben.'; return; }
      if (!photo) { error = 'Bitte Maße angeben oder ein Foto aufnehmen.'; return; }
    } else if (m.volumeM3 < MIN_ITEM_M3 || m.volumeM3 > MAX_ITEM_M3) {
      error = `Das ergibt ${fmt(m.volumeM3)} m³ — bitte Maße prüfen (höchstens ${MAX_ITEM_M3} m³ pro Gegenstand).`;
      return;
    }

    const sameDims = !!initial?.dimsM && !!m.dimsM && initial.dimsM.every((d, i) => Math.abs(d - m.dimsM![i]) < 0.005);
    tapHaptic();
    onsave({
      label: name.trim(),
      source: initial?.source ?? 'manual',
      frames: photo ? [{ imageBase64: photo, depthMapBase64: null, pose: null }] : [],
      hasDepth: initial?.hasDepth ?? false,
      volumeM3: m.volumeM3,
      dimsM: m.dimsM,
      // A scanned item's confidence only holds while its box is RoomPlan's own.
      deviceConfidence: sameDims ? (initial?.deviceConfidence ?? null) : null,
    });
  }

  async function pickPhoto(e: Event) {
    const file = (e.currentTarget as HTMLInputElement).files?.[0];
    if (!file) return;
    photo = await downscale(file);
    error = null;
  }

  /** Phone photos are several MB; 1600 px JPEG is plenty to name an item. */
  function downscale(file: File, maxSide = 1600): Promise<string> {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
        const canvas = document.createElement('canvas');
        canvas.width = Math.round(img.width * scale);
        canvas.height = Math.round(img.height * scale);
        canvas.getContext('2d')!.drawImage(img, 0, 0, canvas.width, canvas.height);
        URL.revokeObjectURL(url);
        resolve(canvas.toDataURL('image/jpeg', 0.85).split(',')[1]);
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Foto konnte nicht gelesen werden.')); };
      img.src = url;
    });
  }
</script>

<Sheet title={initial ? 'Gegenstand bearbeiten' : 'Gegenstand hinzufügen'} {onclose}>
  <p class="ios-section-header">Bezeichnung</p>
  <div class="ios-card px-4 mb-2">
    <input bind:value={name} placeholder="Optional, z. B. Sofa" class="ios-input" />
  </div>
  {#if !initial}
    <div class="flex flex-wrap gap-2 mb-5">
      {#each suggestions as s}
        <button onclick={() => { tapHaptic(); name = s; }}
          class="h-8 px-3.5 rounded-full text-[13px] font-medium {name === s ? 'bg-tint text-on-tint' : 'bg-fill text-label'}">
          {s}
        </button>
      {/each}
    </div>
  {:else}
    <div class="mb-5"></div>
  {/if}

  <div class="flex items-center justify-between mb-2 px-4">
    <p class="text-[13px] uppercase tracking-[0.02em] text-label-2">Größe</p>
    <div class="flex bg-fill rounded-lg p-0.5">
      <button onclick={() => { mode = 'dims'; error = null; }}
        class="h-7 px-3 rounded-md text-[13px] font-semibold {mode === 'dims' ? 'bg-card text-label shadow-sm' : 'text-label-2'}">
        Maße
      </button>
      <button onclick={() => { mode = 'volume'; error = null; }}
        class="h-7 px-3 rounded-md text-[13px] font-semibold {mode === 'volume' ? 'bg-card text-label shadow-sm' : 'text-label-2'}">
        Volumen
      </button>
    </div>
  </div>
  {#if mode === 'dims'}
    <div class="ios-card flex mb-2">
      {#each ['Länge', 'Breite', 'Höhe'] as label, i}
        <label class="flex-1 min-w-0 px-3 py-2 {i > 0 ? 'border-l-[0.5px] border-separator' : ''}">
          <span class="block text-[12px] text-label-2">{label} (cm)</span>
          <input bind:value={dims[i]} inputmode="decimal" placeholder="0" class="ios-input min-h-[32px]" />
        </label>
      {/each}
    </div>
    <p class="text-[12px] text-label-2 px-4 mb-5">Außenmaße. Den Platz zum Tragen und Stapeln rechnen wir dazu.</p>
  {:else}
    <div class="ios-card flex items-center px-4 mb-2">
      <input bind:value={volume} inputmode="decimal" placeholder="z. B. 1,5" class="ios-input" />
      <span class="text-[17px] text-label-2">m³</span>
    </div>
    <p class="text-[12px] text-label-2 px-4 mb-5">Wird so übernommen, wie Sie es angeben.</p>
  {/if}

  <p class="ios-section-header">Foto {requireSize ? '(optional)' : ''}</p>
  <div class="ios-card mb-2 overflow-hidden">
    {#if photo}
      <img src="data:image/jpeg;base64,{photo}" alt="Foto des Gegenstands" class="w-full max-h-48 object-cover" />
      <div class="flex">
        <button onclick={() => fileInput?.click()} class="flex-1 h-11 text-[15px] text-tint tappable">Neues Foto</button>
        <button onclick={() => (photo = null)} class="flex-1 h-11 text-[15px] text-red tappable border-l-[0.5px] border-separator">Entfernen</button>
      </div>
    {:else}
      <button onclick={() => fileInput?.click()} class="w-full h-11 flex items-center justify-center gap-2 text-[15px] text-tint tappable">
        <Camera size={18} /> Foto aufnehmen
      </button>
    {/if}
  </div>
  <p class="text-[12px] text-label-2 px-4 mb-5">
    {requireSize ? 'Hilft uns, den Gegenstand zu erkennen.' : 'Ohne Maße schätzen wir die Größe anhand des Fotos.'}
  </p>
  <input bind:this={fileInput} type="file" accept="image/*" capture="environment" class="hidden" onchange={pickPhoto} />

  {#if error}
    <p class="text-[13px] text-red px-4 mb-3">{error}</p>
  {/if}

  <button onclick={save} class="btn-filled w-full mb-2">Sichern</button>
  {#if ondelete}
    <button onclick={() => { tapHaptic(); ondelete(); }} class="btn-gray w-full text-red">
      <Trash2 size={17} /> Löschen
    </button>
  {/if}
</Sheet>
