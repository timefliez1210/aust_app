<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { DepthCapture } from '$lib/plugins/depth-capture';
  import type { Detection, BoundingBox, ArcProgress } from '$lib/plugins/depth-capture';

  // ── State ────────────────────────────────────────────────────────────────

  type PageState =
    | 'detection_idle'
    | 'item_selected'
    | 'arc_sweep'
    | 'item_saved'
    | 'draw_mode'
    | 'label_input';

  let pageState: PageState = $state('detection_idle');
  let detections: Detection[] = $state([]);
  let selectedDetection: Detection | null = $state(null);
  let arcDegrees = $state(0);
  let arcDirection: 'left' | 'right' | 'up' | 'down' = $state('left');
  let savedLabel = $state('');
  let labelInput = $state('');
  let pendingBbox: BoundingBox | null = $state(null);
  let sessionStarted = $state(false);

  // ── RE catalogue suggestions ──────────────────────────────────────────────
  const CATALOGUE = [
    'Sofa', 'Couch', 'Sessel', 'Stuhl', 'Bett', 'Tisch', 'Esstisch', 'Schreibtisch',
    'Schrank', 'Kleiderschrank', 'Regal', 'Bücherregal', 'Kommode', 'Sideboard',
    'Fernseher', 'Kühlschrank', 'Waschmaschine', 'Herd', 'Spülmaschine', 'Mikrowelle',
    'Klavier', 'Fahrrad', 'Matratze', 'Badezimmerschrank', 'Vitrine',
  ];

  let catalogueSuggestions: string[] = $derived(
    labelInput.length >= 2
      ? CATALOGUE.filter(n => n.toLowerCase().includes(labelInput.toLowerCase())).slice(0, 5)
      : [],
  );

  // ── Listener handles ──────────────────────────────────────────────────────
  let detectHandle: any, arcHandle: any, savedHandle: any, drawnHandle: any;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  onMount(async () => {
    capture.clear();

    detectHandle = await DepthCapture.addListener('detections', ({ detections: d }) => {
      detections = d;
    });

    arcHandle = await DepthCapture.addListener('arcProgress', (data: ArcProgress) => {
      arcDegrees = data.degrees;
      arcDirection = data.direction;
    });

    savedHandle = await DepthCapture.addListener('itemSaved', async (evt) => {
      const { items } = await DepthCapture.getAllItems();
      const latest = items[items.length - 1];
      if (latest) capture.addItem(latest);

      if (!capture.intrinsics) {
        capture.intrinsics = await DepthCapture.getIntrinsics();
      }

      savedLabel = evt.label;
      pageState = 'item_saved';
      setTimeout(() => {
        pageState = 'detection_idle';
        arcDegrees = 0;
      }, 1500);
    });

    drawnHandle = await DepthCapture.addListener('boxDrawn', (box) => {
      pendingBbox = { x: box.x, y: box.y, w: box.w, h: box.h };
      labelInput = '';
      pageState = 'label_input';
    });

    await DepthCapture.startSession();
    sessionStarted = true;
  });

  onDestroy(() => {
    detectHandle?.remove();
    arcHandle?.remove();
    savedHandle?.remove();
    drawnHandle?.remove();
    DepthCapture.stopSession();
  });

  // ── Actions ───────────────────────────────────────────────────────────────

  function tapDetection(det: Detection) {
    if (pageState !== 'detection_idle') return;
    selectedDetection = det;
    pageState = 'item_selected';
  }

  async function confirmItem() {
    if (!selectedDetection) return;
    pageState = 'arc_sweep';
    await DepthCapture.startItemScan({
      label: selectedDetection.germanLabel || selectedDetection.label,
      bbox: selectedDetection.bbox,
    });
  }

  async function confirmManualLabel() {
    const label = labelInput.trim();
    if (!label || !pendingBbox) return;
    pageState = 'arc_sweep';
    labelInput = '';
    await DepthCapture.startItemScan({ label, bbox: pendingBbox });
    pendingBbox = null;
  }

  function cancelItemSelection() {
    selectedDetection = null;
    pendingBbox = null;
    labelInput = '';
    pageState = 'detection_idle';
  }

  async function cancelArcSweep() {
    await DepthCapture.cancelItemScan();
    arcDegrees = 0;
    pageState = 'detection_idle';
  }

  async function enterDrawMode() {
    pageState = 'draw_mode';
    await DepthCapture.setDrawMode({ enabled: true });
  }

  async function cancelDrawMode() {
    await DepthCapture.setDrawMode({ enabled: false });
    pageState = 'detection_idle';
  }

  async function finish() {
    DepthCapture.stopSession();
    goto('/scan/form');
  }

  async function closeCapture() {
    DepthCapture.stopSession();
    capture.clear();
    goto('/');
  }

  // ── Arc SVG ───────────────────────────────────────────────────────────────
  const ARC_R = 120;
  const ARC_MAX = 28;

  function describeArc(deg: number): string {
    const clamped = Math.min(deg, ARC_MAX);
    if (clamped <= 0) return '';
    const rad = (clamped / 360) * 2 * Math.PI;
    const cx = 150, cy = 150;
    const endX = cx + ARC_R * Math.sin(rad);
    const endY = cy - ARC_R * Math.cos(rad);
    const largeArc = clamped > 180 ? 1 : 0;
    return `M ${cx} ${cy - ARC_R} A ${ARC_R} ${ARC_R} 0 ${largeArc} 1 ${endX} ${endY}`;
  }

  let arcPath = $derived(describeArc(arcDegrees));
</script>

<!-- Root: transparent so ARSCNView shows through from behind the WebView -->
<div class="fixed inset-0" style="background: transparent;">

  <!-- Detection tap targets — invisible divs positioned over native bounding boxes -->
  {#if pageState === 'detection_idle'}
    {#each detections as det}
      <button
        onclick={() => tapDetection(det)}
        class="absolute"
        style="
          left: {det.bbox.x * 100}%;
          top: {det.bbox.y * 100}%;
          width: {det.bbox.w * 100}%;
          height: {det.bbox.h * 100}%;
          background: transparent;
          border: none;
        "
        aria-label="Objekt auswählen: {det.germanLabel || det.label}"
      ></button>
    {/each}
  {/if}

  <!-- ── Top bar — safe area aware ─────────────────────────────────────── -->
  <div
    class="absolute top-0 left-0 right-0 flex items-center justify-between px-5 z-20"
    style="padding-top: max(20px, env(safe-area-inset-top)); padding-bottom: 12px;"
  >
    <div class="flex items-center gap-2 bg-black/50 px-3.5 py-1.5 rounded-full backdrop-blur-sm">
      <div class="w-2 h-2 rounded-full {capture.itemCount > 0 ? 'bg-green-400' : 'bg-white/30'}"></div>
      <span class="text-white text-xs font-bold tracking-wider uppercase">
        {capture.itemCount} {capture.itemCount === 1 ? 'Objekt' : 'Objekte'}
      </span>
    </div>
    <button
      onclick={closeCapture}
      class="w-10 h-10 flex items-center justify-center bg-black/50 rounded-full backdrop-blur-sm text-white active:scale-90 transition-transform"
      aria-label="Schließen"
    >
      <span class="material-symbols-outlined">close</span>
    </button>
  </div>

  <!-- ── Draw mode ──────────────────────────────────────────────────────── -->
  {#if pageState === 'draw_mode'}
    <div class="absolute inset-0 z-10 pointer-events-none" style="background: rgba(0,0,0,0.3);">
      <div class="absolute inset-8" style="
        background-image: radial-gradient(circle, rgba(255,255,255,0.35) 1px, transparent 1px);
        background-size: 24px 24px;
      "></div>
      <p class="absolute bottom-36 left-0 right-0 text-white/80 text-sm font-medium text-center px-8">
        Ziehe ein Rechteck um das Objekt
      </p>
    </div>
    <div
      class="absolute bottom-0 left-0 right-0 flex justify-center z-20 pointer-events-auto"
      style="padding-bottom: max(24px, env(safe-area-inset-bottom));"
    >
      <button
        onclick={cancelDrawMode}
        class="px-6 py-3 bg-white/20 backdrop-blur-sm rounded-xl text-white font-bold text-sm"
      >
        Abbrechen
      </button>
    </div>
  {/if}

  <!-- ── Arc sweep overlay ──────────────────────────────────────────────── -->
  {#if pageState === 'arc_sweep'}
    <div class="absolute inset-0 flex flex-col items-center justify-center z-10 pointer-events-none">
      <svg width="300" height="300" class="drop-shadow-lg">
        <circle cx="150" cy="150" r={ARC_R} fill="none" stroke="rgba(255,255,255,0.15)" stroke-width="4" />
        {#if arcPath}
          <path d={arcPath} fill="none" stroke="white" stroke-width="5" stroke-linecap="round" />
        {/if}
        <text x="150" y="155" text-anchor="middle" fill="white" font-size="28" font-weight="bold" font-family="system-ui">
          {Math.round(arcDegrees)}°
        </text>
        <text x="150" y="178" text-anchor="middle" fill="rgba(255,255,255,0.6)" font-size="13" font-family="system-ui">
          von {ARC_MAX}°
        </text>
      </svg>
      <div class="mt-4 px-5 py-2.5 bg-black/50 backdrop-blur-sm rounded-full">
        <span class="text-white text-sm font-medium">
          {#if arcDirection === 'left'}← langsam nach links bewegen
          {:else if arcDirection === 'right'}→ langsam nach rechts bewegen
          {:else if arcDirection === 'up'}↑ langsam nach oben bewegen
          {:else}↓ langsam nach unten bewegen{/if}
        </span>
      </div>
    </div>
    <div
      class="absolute bottom-0 left-0 right-0 flex justify-center z-20"
      style="padding-bottom: max(24px, env(safe-area-inset-bottom));"
    >
      <button
        onclick={cancelArcSweep}
        class="px-6 py-3 bg-white/20 backdrop-blur-sm rounded-xl text-white font-bold text-sm active:scale-95"
      >
        Abbrechen
      </button>
    </div>
  {/if}

  <!-- ── Item saved flash ────────────────────────────────────────────────── -->
  {#if pageState === 'item_saved'}
    <div class="absolute inset-0 flex flex-col items-center justify-center z-30" style="background: rgba(0,0,0,0.6);">
      <div class="w-20 h-20 rounded-full bg-green-500 flex items-center justify-center mb-4">
        <span class="material-symbols-outlined text-white" style="font-size: 40px; font-variation-settings: 'FILL' 1;">check</span>
      </div>
      <p class="text-white text-xl font-bold">{savedLabel}</p>
      <p class="text-white/70 text-sm mt-1">gespeichert</p>
    </div>
  {/if}

  <!-- ── Item selected bottom sheet ─────────────────────────────────────── -->
  {#if pageState === 'item_selected' && selectedDetection}
    <button class="absolute inset-0 z-20" onclick={cancelItemSelection} aria-label="Schließen"></button>
    <div
      class="absolute bottom-0 left-0 right-0 z-30 bg-surface-container rounded-t-3xl p-6 shadow-2xl"
      style="padding-bottom: max(24px, env(safe-area-inset-bottom));"
    >
      <div class="w-10 h-1 rounded-full bg-outline/30 mx-auto mb-5"></div>
      <p class="text-xs font-bold uppercase tracking-widest text-outline mb-1">Erkanntes Objekt</p>
      <p class="text-on-surface text-xl font-bold mb-1">
        {selectedDetection.germanLabel || selectedDetection.label}
      </p>
      <p class="text-outline text-sm mb-6">
        {Math.round(selectedDetection.confidence * 100)}% Konfidenz · 28° Sweep
      </p>
      <div class="flex gap-3">
        <button
          onclick={cancelItemSelection}
          class="flex-1 py-3.5 rounded-xl bg-surface-container-high text-on-surface-variant font-bold text-sm"
        >
          Abbrechen
        </button>
        <button
          onclick={confirmItem}
          class="flex-1 py-3.5 rounded-xl bg-primary text-white font-bold text-sm active:scale-95 transition-transform"
        >
          Erfassen →
        </button>
      </div>
    </div>
  {/if}

  <!-- ── Manual label input ─────────────────────────────────────────────── -->
  {#if pageState === 'label_input'}
    <button class="absolute inset-0 z-20 bg-black/40" onclick={cancelItemSelection} aria-label="Schließen"></button>
    <div
      class="absolute bottom-0 left-0 right-0 z-30 bg-surface-container rounded-t-3xl p-6 shadow-2xl"
      style="padding-bottom: max(24px, env(safe-area-inset-bottom));"
    >
      <div class="w-10 h-1 rounded-full bg-outline/30 mx-auto mb-5"></div>
      <p class="text-xs font-bold uppercase tracking-widest text-outline mb-3">Objekt benennen</p>
      <!-- svelte-ignore a11y_autofocus -->
      <input
        bind:value={labelInput}
        placeholder="z.B. Schrank, Sofa, Bett..."
        class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none mb-3"
        style="border: none;"
        autofocus
      />
      {#if catalogueSuggestions.length > 0}
        <div class="flex flex-wrap gap-2 mb-4">
          {#each catalogueSuggestions as sug}
            <button
              onclick={() => { labelInput = sug; }}
              class="px-3 py-1.5 rounded-lg bg-surface-container-high text-on-surface text-sm font-medium active:bg-primary active:text-white transition-colors"
            >
              {sug}
            </button>
          {/each}
        </div>
      {/if}
      <div class="flex gap-3">
        <button
          onclick={cancelItemSelection}
          class="flex-1 py-3.5 rounded-xl bg-surface-container-high text-on-surface-variant font-bold text-sm"
        >
          Abbrechen
        </button>
        <button
          onclick={confirmManualLabel}
          disabled={!labelInput.trim()}
          class="flex-1 py-3.5 rounded-xl bg-primary text-white font-bold text-sm active:scale-95 transition-transform disabled:opacity-50"
        >
          Erfassen →
        </button>
      </div>
    </div>
  {/if}

  <!-- ── Bottom action bar (detection_idle only) ────────────────────────── -->
  {#if pageState === 'detection_idle'}
    <div
      class="absolute bottom-0 left-0 right-0 z-20 px-5"
      style="padding-bottom: max(24px, env(safe-area-inset-bottom));"
    >
      {#if detections.length > 0}
        <div class="flex justify-center mb-4">
          <p class="text-white/70 text-xs bg-black/40 px-3 py-1.5 rounded-full backdrop-blur-sm">
            Tippe auf ein erkanntes Objekt
          </p>
        </div>
      {:else if sessionStarted}
        <div class="flex justify-center mb-4">
          <p class="text-white/50 text-xs bg-black/40 px-3 py-1.5 rounded-full backdrop-blur-sm">
            Richte die Kamera auf Möbel...
          </p>
        </div>
      {/if}
      <div class="flex items-center justify-between">
        <button
          onclick={enterDrawMode}
          class="w-12 h-12 flex items-center justify-center bg-black/50 backdrop-blur-sm rounded-xl text-white active:scale-90 transition-transform"
          aria-label="Objekt manuell markieren"
        >
          <span class="material-symbols-outlined">add</span>
        </button>
        <button
          onclick={finish}
          disabled={capture.itemCount === 0}
          class="px-7 py-3.5 rounded-xl font-bold text-sm transition-all active:scale-95 disabled:opacity-40
            {capture.itemCount > 0 ? 'bg-primary text-white' : 'bg-white/10 text-white/40'}"
        >
          Fertig{capture.itemCount > 0 ? ` (${capture.itemCount})` : ''}
        </button>
      </div>
    </div>
  {/if}

</div>
