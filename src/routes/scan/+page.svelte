<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { Capacitor } from '@capacitor/core';
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

  let hasSupport = $state(false);
  let rootEl: HTMLDivElement;
  const savedAncestorBgs: { el: HTMLElement; bg: string }[] = [];

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

    // Make entire HTML tree transparent so native ARSCNView behind WebView is visible
    document.documentElement.classList.add('ar-mode');

    // Force ALL ancestor backgrounds transparent via inline styles (CSS selectors
    // can miss SvelteKit wrapper layers). Save originals to restore on destroy.
    document.body.style.setProperty('background', 'transparent', 'important');
    let ancestor: HTMLElement | null = rootEl?.parentElement ?? null;
    while (ancestor && ancestor !== document.documentElement) {
      savedAncestorBgs.push({ el: ancestor, bg: ancestor.style.background });
      ancestor.style.setProperty('background', 'transparent', 'important');
      ancestor = ancestor.parentElement;
    }

    try {
      const support = await DepthCapture.checkSupport();
      hasSupport = support.supported;
    } catch { /* non-native platform */ }

    try {
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
    } catch { /* session start failed */ }

    sessionStarted = true;
  });

  onDestroy(() => {
    document.documentElement.classList.remove('ar-mode');
    document.body.style.background = '';
    for (const { el, bg } of savedAncestorBgs) {
      el.style.background = bg;
    }
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

<!-- Root: transparent, with translateZ(0) to force GPU compositing layer in WKWebView -->
<div
  bind:this={rootEl}
  style="position: fixed; inset: 0; z-index: 9999; background: transparent; -webkit-transform: translateZ(0); transform: translateZ(0);"
>

  <!-- Detection tap targets — invisible divs positioned over native bounding boxes -->
  {#if pageState === 'detection_idle'}
    {#each detections as det}
      <button
        onclick={() => tapDetection(det)}
        style="
          position: absolute;
          left: {det.bbox.x * 100}%;
          top: {det.bbox.y * 100}%;
          width: {det.bbox.w * 100}%;
          height: {det.bbox.h * 100}%;
          background: transparent;
          border: none;
          -webkit-transform: translateZ(0);
        "
        aria-label="Objekt auswählen: {det.germanLabel || det.label}"
      ></button>
    {/each}
  {/if}

  <!-- ── Top bar — safe area aware ─────────────────────────────────────── -->
  <div style="
    position: absolute; top: 0; left: 0; right: 0; z-index: 20;
    display: flex; align-items: center; justify-content: space-between;
    padding: max(20px, env(safe-area-inset-top)) 20px 12px 20px;
    -webkit-transform: translateZ(0);
  ">
    <div style="
      display: flex; align-items: center; gap: 8px;
      background: rgba(0,0,0,0.8); padding: 6px 14px; border-radius: 999px;
    ">
      <div style="width: 8px; height: 8px; border-radius: 50%; background: {capture.itemCount > 0 ? '#4ade80' : 'rgba(255,255,255,0.3)'};"></div>
      <span style="color: white; font-size: 12px; font-weight: 700; letter-spacing: 0.05em; text-transform: uppercase;">
        {capture.itemCount} {capture.itemCount === 1 ? 'Objekt' : 'Objekte'}
      </span>
    </div>
    <button
      onclick={closeCapture}
      style="
        width: 40px; height: 40px; display: flex; align-items: center; justify-content: center;
        background: rgba(0,0,0,0.8); border-radius: 50%; border: none; color: white;
      "
      aria-label="Schließen"
    >
      <span class="material-symbols-outlined">close</span>
    </button>
  </div>

  <!-- ── Draw mode ──────────────────────────────────────────────────────── -->
  {#if pageState === 'draw_mode'}
    <div style="position: absolute; inset: 0; z-index: 10; pointer-events: none; background: rgba(0,0,0,0.3); -webkit-transform: translateZ(0);">
      <div style="
        position: absolute; inset: 32px;
        background-image: radial-gradient(circle, rgba(255,255,255,0.35) 1px, transparent 1px);
        background-size: 24px 24px;
      "></div>
      <p style="position: absolute; bottom: 144px; left: 0; right: 0; color: rgba(255,255,255,0.8); font-size: 14px; font-weight: 500; text-align: center; padding: 0 32px;">
        Ziehe ein Rechteck um das Objekt
      </p>
    </div>
    <div style="position: absolute; bottom: 0; left: 0; right: 0; display: flex; justify-content: center; z-index: 20; pointer-events: auto; padding-bottom: max(24px, env(safe-area-inset-bottom)); -webkit-transform: translateZ(0);">
      <button onclick={cancelDrawMode} style="padding: 12px 24px; background: rgba(255,255,255,0.2); border-radius: 12px; border: none; color: white; font-weight: 700; font-size: 14px;">
        Abbrechen
      </button>
    </div>
  {/if}

  <!-- ── Arc sweep overlay ──────────────────────────────────────────────── -->
  {#if pageState === 'arc_sweep'}
    <div style="position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; z-index: 10; pointer-events: none; -webkit-transform: translateZ(0);">
      <svg width="300" height="300">
        <circle cx="150" cy="150" r={ARC_R} fill="none" stroke="rgba(255,255,255,0.15)" stroke-width="4" />
        {#if arcPath}
          <path d={arcPath} fill="none" stroke="white" stroke-width="5" stroke-linecap="round" />
        {/if}
        <text x="150" y="155" text-anchor="middle" fill="white" font-size="28" font-weight="bold" font-family="system-ui">{Math.round(arcDegrees)}°</text>
        <text x="150" y="178" text-anchor="middle" fill="rgba(255,255,255,0.6)" font-size="13" font-family="system-ui">von {ARC_MAX}°</text>
      </svg>
      <div style="margin-top: 16px; padding: 10px 20px; background: rgba(0,0,0,0.7); border-radius: 999px;">
        <span style="color: white; font-size: 14px; font-weight: 500;">
          {#if arcDirection === 'left'}← langsam nach links bewegen
          {:else if arcDirection === 'right'}→ langsam nach rechts bewegen
          {:else if arcDirection === 'up'}↑ langsam nach oben bewegen
          {:else}↓ langsam nach unten bewegen{/if}
        </span>
      </div>
    </div>
    <div style="position: absolute; bottom: 0; left: 0; right: 0; display: flex; justify-content: center; z-index: 20; padding-bottom: max(24px, env(safe-area-inset-bottom)); -webkit-transform: translateZ(0);">
      <button onclick={cancelArcSweep} style="padding: 12px 24px; background: rgba(255,255,255,0.2); border-radius: 12px; border: none; color: white; font-weight: 700; font-size: 14px;">
        Abbrechen
      </button>
    </div>
  {/if}

  <!-- ── Item saved flash ────────────────────────────────────────────────── -->
  {#if pageState === 'item_saved'}
    <div style="position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; z-index: 30; background: rgba(0,0,0,0.6); -webkit-transform: translateZ(0);">
      <div style="width: 80px; height: 80px; border-radius: 50%; background: #22c55e; display: flex; align-items: center; justify-content: center; margin-bottom: 16px;">
        <span class="material-symbols-outlined" style="color: white; font-size: 40px; font-variation-settings: 'FILL' 1;">check</span>
      </div>
      <p style="color: white; font-size: 20px; font-weight: 700;">{savedLabel}</p>
      <p style="color: rgba(255,255,255,0.7); font-size: 14px; margin-top: 4px;">gespeichert</p>
    </div>
  {/if}

  <!-- ── Item selected bottom sheet ─────────────────────────────────────── -->
  {#if pageState === 'item_selected' && selectedDetection}
    <button style="position: absolute; inset: 0; z-index: 20; background: transparent; border: none;" onclick={cancelItemSelection} aria-label="Schließen"></button>
    <div style="
      position: absolute; bottom: 0; left: 0; right: 0; z-index: 30;
      background: #eceef0; border-radius: 24px 24px 0 0; padding: 24px;
      padding-bottom: max(24px, env(safe-area-inset-bottom));
      -webkit-transform: translateZ(0);
    ">
      <div style="width: 40px; height: 4px; border-radius: 2px; background: rgba(116,119,127,0.3); margin: 0 auto 20px;"></div>
      <p style="font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.1em; color: #74777f; margin-bottom: 4px;">Erkanntes Objekt</p>
      <p style="font-size: 20px; font-weight: 700; color: #191c1e; margin-bottom: 4px;">
        {selectedDetection.germanLabel || selectedDetection.label}
      </p>
      <p style="font-size: 14px; color: #74777f; margin-bottom: 24px;">
        {Math.round(selectedDetection.confidence * 100)}% Konfidenz
      </p>
      <div style="display: flex; gap: 12px;">
        <button onclick={cancelItemSelection} style="flex: 1; padding: 14px; border-radius: 12px; background: #e6e8ea; border: none; color: #43474e; font-weight: 700; font-size: 14px;">
          Abbrechen
        </button>
        <button onclick={confirmItem} style="flex: 1; padding: 14px; border-radius: 12px; background: #022448; border: none; color: white; font-weight: 700; font-size: 14px;">
          Erfassen →
        </button>
      </div>
    </div>
  {/if}

  <!-- ── Manual label input ─────────────────────────────────────────────── -->
  {#if pageState === 'label_input'}
    <button style="position: absolute; inset: 0; z-index: 20; background: rgba(0,0,0,0.4); border: none;" onclick={cancelItemSelection} aria-label="Schließen"></button>
    <div style="
      position: absolute; bottom: 0; left: 0; right: 0; z-index: 30;
      background: #eceef0; border-radius: 24px 24px 0 0; padding: 24px;
      padding-bottom: max(24px, env(safe-area-inset-bottom));
      -webkit-transform: translateZ(0);
    ">
      <div style="width: 40px; height: 4px; border-radius: 2px; background: rgba(116,119,127,0.3); margin: 0 auto 20px;"></div>
      <p style="font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.1em; color: #74777f; margin-bottom: 12px;">Objekt benennen</p>
      <!-- svelte-ignore a11y_autofocus -->
      <input
        bind:value={labelInput}
        placeholder="z.B. Schrank, Sofa, Bett..."
        style="width: 100%; height: 48px; padding: 0 16px; background: #e6e8ea; border-radius: 12px; border: none; color: #191c1e; font-size: 16px; outline: none; margin-bottom: 12px; box-sizing: border-box;"
        autofocus
      />
      {#if catalogueSuggestions.length > 0}
        <div style="display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 16px;">
          {#each catalogueSuggestions as sug}
            <button onclick={() => { labelInput = sug; }} style="padding: 6px 12px; border-radius: 8px; background: #e6e8ea; border: none; color: #191c1e; font-size: 14px; font-weight: 500;">
              {sug}
            </button>
          {/each}
        </div>
      {/if}
      <div style="display: flex; gap: 12px;">
        <button onclick={cancelItemSelection} style="flex: 1; padding: 14px; border-radius: 12px; background: #e6e8ea; border: none; color: #43474e; font-weight: 700; font-size: 14px;">
          Abbrechen
        </button>
        <button onclick={confirmManualLabel} disabled={!labelInput.trim()} style="flex: 1; padding: 14px; border-radius: 12px; background: {labelInput.trim() ? '#022448' : 'rgba(2,36,72,0.4)'}; border: none; color: white; font-weight: 700; font-size: 14px;">
          Erfassen →
        </button>
      </div>
    </div>
  {/if}

  <!-- ── Bottom action bar (detection_idle only) ────────────────────────── -->
  {#if pageState === 'detection_idle'}
    <div style="
      position: absolute; bottom: 0; left: 0; right: 0; z-index: 20; padding: 0 20px;
      padding-bottom: max(24px, env(safe-area-inset-bottom));
      -webkit-transform: translateZ(0);
    ">
      {#if detections.length > 0}
        <div style="display: flex; justify-content: center; margin-bottom: 16px;">
          <p style="color: rgba(255,255,255,0.7); font-size: 12px; background: rgba(0,0,0,0.7); padding: 6px 12px; border-radius: 999px;">
            Tippe auf ein erkanntes Objekt
          </p>
        </div>
      {:else if sessionStarted}
        <div style="display: flex; justify-content: center; margin-bottom: 16px;">
          <p style="color: rgba(255,255,255,0.5); font-size: 12px; background: rgba(0,0,0,0.7); padding: 6px 12px; border-radius: 999px;">
            Richte die Kamera auf Möbel...
          </p>
        </div>
      {/if}
      <div style="display: flex; align-items: center; justify-content: space-between;">
        <button
          onclick={enterDrawMode}
          style="
            width: 48px; height: 48px; display: flex; align-items: center; justify-content: center;
            background: rgba(0,0,0,0.8); border-radius: 12px; border: none; color: white;
          "
          aria-label="Objekt manuell markieren"
        >
          <span class="material-symbols-outlined">add</span>
        </button>
        <button
          onclick={finish}
          disabled={capture.itemCount === 0}
          style="
            padding: 14px 28px; border-radius: 12px; font-weight: 700; font-size: 14px; border: none;
            background: {capture.itemCount > 0 ? '#022448' : 'rgba(255,255,255,0.1)'};
            color: {capture.itemCount > 0 ? 'white' : 'rgba(255,255,255,0.4)'};
            opacity: {capture.itemCount === 0 ? '0.4' : '1'};
          "
        >
          Fertig{capture.itemCount > 0 ? ` (${capture.itemCount})` : ''}
        </button>
      </div>
    </div>
  {/if}

</div>
