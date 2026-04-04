<script lang="ts">
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

  // ── RE catalogue suggestions (subset for manual label input) ─────────────
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

  // ── Plugin event listeners ────────────────────────────────────────────────

  $effect(() => {
    let detectHandle: any, arcHandle: any, savedHandle: any, drawnHandle: any;

    (async () => {
      await capture.clear();

      detectHandle = await DepthCapture.addListener('detections', ({ detections: d }) => {
        detections = d;
      });

      arcHandle = await DepthCapture.addListener('arcProgress', (data: ArcProgress) => {
        arcDegrees = data.degrees;
        arcDirection = data.direction;
      });

      savedHandle = await DepthCapture.addListener('itemSaved', async (evt) => {
        // Fetch the latest item from plugin and store it
        const { items } = await DepthCapture.getAllItems();
        const latest = items[items.length - 1];
        if (latest) capture.addItem(latest);

        // Update intrinsics once (constant per session)
        if (!capture.intrinsics) {
          const intrinsics = await DepthCapture.getIntrinsics();
          capture.intrinsics = intrinsics;
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
      pageState = 'detection_idle';
    })();

    return async () => {
      await detectHandle?.remove();
      await arcHandle?.remove();
      await savedHandle?.remove();
      await drawnHandle?.remove();
      await DepthCapture.stopSession();
      sessionStarted = false;
    };
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
    await DepthCapture.stopSession();
    goto('/scan/form');
  }

  async function closeCapture() {
    await DepthCapture.stopSession();
    capture.clear();
    goto('/');
  }

  // ── Arc SVG helpers ───────────────────────────────────────────────────────

  const ARC_R = 120; // radius px
  const ARC_MAX = 28; // degrees

  function describeArc(deg: number): string {
    const clamped = Math.min(deg, ARC_MAX);
    if (clamped <= 0) return '';
    const radians = ((clamped / 360) * 2 * Math.PI);
    const cx = 150, cy = 150;
    const startX = cx;
    const startY = cy - ARC_R;
    const endX = cx + ARC_R * Math.sin(radians);
    const endY = cy - ARC_R * Math.cos(radians);
    const largeArc = clamped > 180 ? 1 : 0;
    return `M ${startX} ${startY} A ${ARC_R} ${ARC_R} 0 ${largeArc} 1 ${endX} ${endY}`;
  }

  let arcPath = $derived(describeArc(arcDegrees));
  let arcPercent = $derived(Math.min(100, Math.round((arcDegrees / ARC_MAX) * 100)));
</script>

<!-- Root: black canvas, full screen -->
<div class="fixed inset-0 bg-black">

  <!-- ── Camera preview (web only — on iOS the native ARSCNView shows through) ── -->
  <!-- The native plugin makes the WebView transparent on iOS; this div is invisible there -->
  <div
    class="absolute inset-0"
    style="background: transparent;"
    aria-hidden="true"
  ></div>

  <!-- ── Detection tap targets (invisible, sit over native bounding boxes) ── -->
  {#if pageState === 'detection_idle'}
    {#each detections as det}
      <button
        onclick={() => tapDetection(det)}
        class="absolute flex flex-col items-center justify-center text-white"
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

  <!-- ── Top bar ─────────────────────────────────────────────────────────── -->
  <div class="absolute top-0 left-0 right-0 flex items-center justify-between p-5 z-20">
    <!-- Item count chip -->
    <div class="flex items-center gap-2 bg-black/50 px-3.5 py-1.5 rounded-full backdrop-blur-sm">
      <div class="w-2 h-2 rounded-full {capture.itemCount > 0 ? 'bg-green-400' : 'bg-white/30'}"></div>
      <span class="text-white text-xs font-bold tracking-wider uppercase">
        {capture.itemCount}
        {capture.itemCount === 1 ? 'Objekt' : 'Objekte'}
      </span>
    </div>

    <!-- Close -->
    <button
      onclick={closeCapture}
      class="w-10 h-10 flex items-center justify-center bg-black/50 rounded-full backdrop-blur-sm text-white active:scale-90 transition-transform"
      aria-label="Schließen"
    >
      <span class="material-symbols-outlined">close</span>
    </button>
  </div>

  <!-- ── Draw mode dot grid ──────────────────────────────────────────────── -->
  {#if pageState === 'draw_mode'}
    <div
      class="absolute inset-0 z-10 flex items-center justify-center"
      style="background: rgba(0,0,0,0.25);"
    >
      <!-- Dot grid visual hint -->
      <div class="absolute inset-8" style="
        background-image: radial-gradient(circle, rgba(255,255,255,0.4) 1px, transparent 1px);
        background-size: 24px 24px;
      "></div>
      <p class="text-white/80 text-sm font-medium text-center px-8 mt-40">
        Ziehe ein Rechteck um das Objekt
      </p>
    </div>
    <div class="absolute bottom-10 left-0 right-0 flex justify-center z-20">
      <button
        onclick={cancelDrawMode}
        class="px-6 py-3 bg-white/20 backdrop-blur-sm rounded-xl text-white font-bold text-sm"
      >
        Abbrechen
      </button>
    </div>
  {/if}

  <!-- ── Arc sweep overlay ───────────────────────────────────────────────── -->
  {#if pageState === 'arc_sweep'}
    <div class="absolute inset-0 flex flex-col items-center justify-center z-10 pointer-events-none">
      <!-- Circular arc progress -->
      <svg width="300" height="300" class="drop-shadow-lg">
        <!-- Track -->
        <circle cx="150" cy="150" r={ARC_R} fill="none" stroke="rgba(255,255,255,0.15)" stroke-width="4" />
        <!-- Progress arc -->
        {#if arcPath}
          <path d={arcPath} fill="none" stroke="white" stroke-width="5" stroke-linecap="round" />
        {/if}
        <!-- Degree label -->
        <text x="150" y="155" text-anchor="middle" fill="white" font-size="28" font-weight="bold" font-family="system-ui">
          {Math.round(arcDegrees)}°
        </text>
        <text x="150" y="178" text-anchor="middle" fill="rgba(255,255,255,0.6)" font-size="13" font-family="system-ui">
          von {ARC_MAX}°
        </text>
      </svg>

      <!-- Direction hint -->
      <div class="mt-4 px-5 py-2.5 bg-black/50 backdrop-blur-sm rounded-full">
        <span class="text-white text-sm font-medium">
          {#if arcDirection === 'left'}← langsam nach links bewegen
          {:else if arcDirection === 'right'}→ langsam nach rechts bewegen
          {:else if arcDirection === 'up'}↑ langsam nach oben bewegen
          {:else}↓ langsam nach unten bewegen{/if}
        </span>
      </div>
    </div>

    <!-- Cancel sweep -->
    <div class="absolute bottom-10 left-0 right-0 flex justify-center z-20">
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
    <div class="absolute inset-0 flex flex-col items-center justify-center z-30 bg-black/60">
      <div class="w-20 h-20 rounded-full bg-green-500 flex items-center justify-center mb-4">
        <span class="material-symbols-outlined text-white" style="font-size: 40px; font-variation-settings: 'FILL' 1;">check</span>
      </div>
      <p class="text-white text-xl font-bold">{savedLabel}</p>
      <p class="text-white/70 text-sm mt-1">gespeichert</p>
    </div>
  {/if}

  <!-- ── Item selected bottom sheet ─────────────────────────────────────── -->
  {#if pageState === 'item_selected' && selectedDetection}
    <div class="absolute inset-0 z-20" onclick={cancelItemSelection} aria-label="Schließen"></div>
    <div class="absolute bottom-0 left-0 right-0 z-30 bg-surface-container rounded-t-3xl p-6 shadow-2xl">
      <div class="w-10 h-1 rounded-full bg-outline/30 mx-auto mb-5"></div>
      <p class="text-xs font-bold uppercase tracking-widest text-outline mb-1">Erkanntes Objekt</p>
      <p class="text-on-surface text-xl font-bold mb-1">
        {selectedDetection.germanLabel || selectedDetection.label}
      </p>
      <p class="text-outline text-sm mb-6">
        {Math.round(selectedDetection.confidence * 100)}% Konfidenz
        · Bewege die Kamera 28° um das Objekt
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

  <!-- ── Manual label input bottom sheet ────────────────────────────────── -->
  {#if pageState === 'label_input'}
    <div class="absolute inset-0 z-20 bg-black/40" onclick={cancelItemSelection} aria-label="Schließen"></div>
    <div class="absolute bottom-0 left-0 right-0 z-30 bg-surface-container rounded-t-3xl p-6 shadow-2xl">
      <div class="w-10 h-1 rounded-full bg-outline/30 mx-auto mb-5"></div>
      <p class="text-xs font-bold uppercase tracking-widest text-outline mb-3">Objekt benennen</p>
      <input
        bind:value={labelInput}
        placeholder="z.B. Schrank, Sofa, Bett..."
        class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none mb-3"
        style="border: none;"
        autofocus
      />
      <!-- Catalogue suggestions -->
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

  <!-- ── Bottom action bar (detection_idle) ─────────────────────────────── -->
  {#if pageState === 'detection_idle'}
    <div class="absolute bottom-0 left-0 right-0 z-20 p-5">
      {#if detections.length > 0}
        <!-- Detection hint -->
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
        <!-- Manual add -->
        <button
          onclick={enterDrawMode}
          class="w-12 h-12 flex items-center justify-center bg-white/20 backdrop-blur-sm rounded-xl text-white active:scale-90 transition-transform"
          aria-label="Objekt manuell markieren"
        >
          <span class="material-symbols-outlined">add</span>
        </button>

        <!-- Fertig -->
        <button
          onclick={finish}
          disabled={capture.itemCount === 0}
          class="px-7 py-3.5 rounded-xl font-bold text-sm transition-all active:scale-95 disabled:opacity-40
            {capture.itemCount > 0
              ? 'bg-primary text-white'
              : 'bg-white/10 text-white/40'}"
        >
          Fertig
          {#if capture.itemCount > 0}
            ({capture.itemCount})
          {/if}
        </button>
      </div>
    </div>
  {/if}

</div>
