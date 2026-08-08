<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { Capacitor } from '@capacitor/core';
  import { capture } from '$lib/stores/capture.svelte';
  import { DepthCapture } from '$lib/plugins/depth-capture';
  import { tapHaptic, successHaptic } from '$lib/haptics';
  import { X, Camera, Check, Plus, CircleAlert } from 'lucide-svelte';

  // ── Mode ──────────────────────────────────────────────────────────────────
  // iOS: fully native ARKit session (WebView hidden by the plugin).
  // Android/web: guided in-page photo capture — same data shape, no depth/poses;
  // the backend estimates volume server-side (VLM).
  let mode: 'native' | 'web' | 'detecting' = $state('detecting');
  let cameraError: string | null = $state(null);

  // ── Native session ────────────────────────────────────────────────────────
  let completeHandle: any;
  let cancelHandle: any;
  let savedHandle: any;

  async function startNative() {
    completeHandle = await DepthCapture.addListener('sessionComplete', async () => {
      const { items } = await DepthCapture.getAllItems();
      capture.clear();
      for (const item of items) capture.addItem(item);
      try {
        capture.intrinsics = await DepthCapture.getIntrinsics();
        capture.persistIntrinsics();
      } catch { /* non-LiDAR or intrinsics unavailable */ }
      await DepthCapture.stopSession();
      goto('/scan/form');
    });

    cancelHandle = await DepthCapture.addListener('sessionCancelled', async () => {
      await DepthCapture.stopSession();
      capture.clear();
      goto('/');
    });

    savedHandle = await DepthCapture.addListener('itemSaved', () => {
      // Native overlay handles all feedback.
    });

    await DepthCapture.startSession();
  }

  // ── Web/Android capture flow ─────────────────────────────────────────────
  // Photos first, name afterwards and only if the customer wants to: the volume
  // (here: server-side from the photos) is what matters, the label is filled in
  // by the backend when it's missing.
  type WebState = 'idle' | 'capturing' | 'review';
  let webState: WebState = $state('idle');
  let stream: MediaStream | null = null;
  let videoEl: HTMLVideoElement | undefined = $state();
  let labelInput = $state('');
  let currentFrames: string[] = $state([]);
  let flash = $state(false);
  let savedFlash: string | null = $state(null);

  const suggestions = ['Sofa', 'Schrank', 'Bett', 'Tisch', 'Regal', 'Waschmaschine', 'Kommode', 'Kartons'];

  async function startWeb() {
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
      });
      mode = 'web';
      // videoEl binds after render
      requestAnimationFrame(() => {
        if (videoEl && stream) {
          videoEl.srcObject = stream;
          videoEl.play().catch(() => {});
        }
      });
    } catch {
      mode = 'web';
      cameraError = 'Kamera nicht verfügbar. Bitte erlauben Sie den Kamerazugriff in den Einstellungen.';
    }
  }

  function snap() {
    if (!videoEl || videoEl.videoWidth === 0) return;
    tapHaptic();
    const maxW = 1280;
    const scale = Math.min(1, maxW / videoEl.videoWidth);
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(videoEl.videoWidth * scale);
    canvas.height = Math.round(videoEl.videoHeight * scale);
    canvas.getContext('2d')!.drawImage(videoEl, 0, 0, canvas.width, canvas.height);
    currentFrames = [...currentFrames, canvas.toDataURL('image/jpeg', 0.85).split(',')[1]];
    flash = true;
    setTimeout(() => (flash = false), 120);
  }

  function startItem() {
    tapHaptic();
    currentFrames = [];
    labelInput = '';
    webState = 'capturing';
  }

  function reviewItem() {
    if (currentFrames.length === 0) return;
    tapHaptic();
    webState = 'review';
  }

  /** Save the item. An empty label is fine — the backend names it from the photos. */
  function saveItem() {
    if (currentFrames.length === 0) return;
    successHaptic();
    const label = labelInput.trim();
    capture.addItem({
      label,
      frames: currentFrames.map(f => ({ imageBase64: f, depthMapBase64: null, pose: null })),
      arcDegrees: 0,
      hasDepth: false,
    });
    savedFlash = label || 'Objekt erfasst';
    setTimeout(() => (savedFlash = null), 1400);
    currentFrames = [];
    labelInput = '';
    webState = 'idle';
  }

  function cancelItem() {
    tapHaptic();
    currentFrames = [];
    labelInput = '';
    webState = 'idle';
  }

  function stopWeb() {
    stream?.getTracks().forEach(t => t.stop());
    stream = null;
  }

  function finishWeb() {
    if (capture.itemCount === 0) return;
    successHaptic();
    stopWeb();
    goto('/scan/form');
  }

  function closeScan() {
    tapHaptic();
    stopWeb();
    capture.clear();
    goto('/');
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  onMount(async () => {
    capture.clear();
    let useNative = false;
    if (Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios') {
      try {
        const support = await DepthCapture.checkSupport();
        useNative = support.supported;
      } catch { /* plugin unavailable */ }
    }
    if (useNative) {
      mode = 'native';
      await startNative();
    } else {
      await startWeb();
    }
  });

  onDestroy(() => {
    completeHandle?.remove();
    cancelHandle?.remove();
    savedHandle?.remove();
    stopWeb();
  });
</script>

{#if mode === 'web'}
  <div class="fixed inset-0 bg-black flex flex-col z-40">
    {#if cameraError}
      <!-- Permission / availability error -->
      <div class="flex-1 flex flex-col items-center justify-center px-8 text-center"
        style="padding-top: env(safe-area-inset-top, 0px);">
        <div class="w-16 h-16 rounded-full bg-red-soft flex items-center justify-center mb-5 text-red">
          <CircleAlert size={30} />
        </div>
        <h2 class="text-white text-[20px] font-bold mb-2">Kein Kamerazugriff</h2>
        <p class="text-[15px] mb-8" style="color: rgba(255,255,255,0.6);">{cameraError}</p>
        <button onclick={closeScan} class="btn-gray px-8" style="background: rgba(255,255,255,0.15); color: #fff;">
          Zurück
        </button>
      </div>
    {:else}
      <!-- Camera preview -->
      <!-- svelte-ignore a11y_media_has_caption -->
      <video bind:this={videoEl} autoplay playsinline muted class="absolute inset-0 w-full h-full object-cover"></video>
      {#if flash}
        <div class="absolute inset-0 bg-white/70 z-10"></div>
      {/if}

      <!-- Top bar -->
      <div class="relative z-20 flex items-center justify-between px-4"
        style="padding-top: calc(env(safe-area-inset-top, 0px) + 8px);">
        <div class="flex items-center gap-2 h-8 px-3 rounded-full" style="background: rgba(0,0,0,0.55); backdrop-filter: blur(10px);">
          <span class="w-2 h-2 rounded-full {capture.itemCount > 0 ? 'bg-green' : 'bg-white/30'}"></span>
          <span class="text-white text-[13px] font-semibold">
            {capture.itemCount} {capture.itemCount === 1 ? 'Objekt' : 'Objekte'}
          </span>
        </div>
        <button onclick={closeScan} aria-label="Schließen"
          class="w-9 h-9 rounded-full flex items-center justify-center text-white"
          style="background: rgba(0,0,0,0.55); backdrop-filter: blur(10px);">
          <X size={18} />
        </button>
      </div>

      <!-- Saved flash -->
      {#if savedFlash}
        <div class="absolute inset-0 z-30 flex flex-col items-center justify-center" style="background: rgba(0,0,0,0.55);">
          <div class="w-16 h-16 rounded-full bg-green flex items-center justify-center mb-4">
            <Check size={32} color="#fff" strokeWidth={3} />
          </div>
          <p class="text-white text-[20px] font-bold">{savedFlash}</p>
          <p class="text-[14px]" style="color: rgba(255,255,255,0.7);">gespeichert</p>
        </div>
      {/if}

      <!-- Bottom controls -->
      <div class="relative z-20 mt-auto" style="padding-bottom: calc(env(safe-area-inset-bottom, 0px) + 16px);">
        {#if webState === 'idle'}
          <p class="text-center text-[13px] font-medium mb-4" style="color: rgba(255,255,255,0.75);">
            {capture.itemCount === 0 ? 'Erfassen Sie Ihre Möbel Stück für Stück' : 'Weiteres Objekt hinzufügen oder abschließen'}
          </p>
          <div class="flex items-center justify-center gap-3 px-5">
            <button onclick={startItem}
              class="flex-1 h-[50px] rounded-full flex items-center justify-center gap-2 text-white text-[16px] font-semibold"
              style="background: var(--aust-orange);">
              <Plus size={20} strokeWidth={2.5} />
              Objekt erfassen
            </button>
            {#if capture.itemCount > 0}
              <button onclick={finishWeb}
                class="h-[50px] px-6 rounded-full text-white text-[16px] font-semibold"
                style="background: rgba(255,255,255,0.2); backdrop-filter: blur(10px);">
                Fertig ({capture.itemCount})
              </button>
            {/if}
          </div>

        {:else if webState === 'capturing'}
          <!-- Capturing: straight to the camera, no naming up front -->
          <div class="px-5">
            <div class="flex items-center justify-center mb-3">
              <span class="text-[13px] font-medium px-3 h-8 rounded-full inline-flex items-center text-white"
                style="background: rgba(0,0,0,0.55); backdrop-filter: blur(10px);">
                {currentFrames.length} / 4 Fotos
              </span>
            </div>
            <p class="text-center text-[13px] mb-4" style="color: rgba(255,255,255,0.75);">
              Fotografieren Sie das Objekt aus 3–4 verschiedenen Winkeln
            </p>
            <div class="flex items-center justify-between">
              <button onclick={cancelItem} class="w-[72px] text-left text-white/80 text-[15px] font-medium">
                Abbruch
              </button>
              <!-- Shutter -->
              <button onclick={snap} aria-label="Foto aufnehmen"
                class="w-[74px] h-[74px] rounded-full border-4 border-white flex items-center justify-center active:scale-95 transition-transform">
                <span class="w-[60px] h-[60px] rounded-full bg-white"></span>
              </button>
              <button onclick={reviewItem} disabled={currentFrames.length === 0}
                class="w-[72px] text-right text-[15px] font-semibold {currentFrames.length > 0 ? 'text-white' : 'text-white/30'}">
                Weiter
              </button>
            </div>
          </div>

        {:else}
          <!-- Review: naming is optional, saving is one tap away -->
          <div class="mx-3 rounded-[20px] p-5" style="background: var(--ios-card);">
            <p class="text-[13px] font-semibold text-label-2 mb-1">
              {currentFrames.length} {currentFrames.length === 1 ? 'Foto' : 'Fotos'} erfasst
            </p>
            <p class="text-[17px] font-semibold text-label mb-3">Bezeichnung (optional)</p>
            <input
              bind:value={labelInput}
              placeholder="z. B. Sofa, Schrank, Bett …"
              class="ios-input bg-fill rounded-xl px-4 mb-3"
              onkeydown={(e) => e.key === 'Enter' && saveItem()}
            />
            <div class="flex flex-wrap gap-2 mb-3">
              {#each suggestions as s}
                <button onclick={() => { tapHaptic(); labelInput = s; }}
                  class="h-8 px-3.5 rounded-full bg-fill text-label text-[13px] font-medium tappable">
                  {s}
                </button>
              {/each}
            </div>
            <p class="text-[12px] text-label-3 mb-4">
              Ohne Bezeichnung erkennen wir das Objekt automatisch.
            </p>
            <div class="flex gap-3">
              <button onclick={() => { tapHaptic(); webState = 'capturing'; }} class="btn-gray flex-1">
                Weitere Fotos
              </button>
              <button onclick={saveItem} class="btn-filled flex-1">Sichern</button>
            </div>
          </div>
        {/if}
      </div>
    {/if}
  </div>
{:else if mode === 'detecting'}
  <div class="fixed inset-0 bg-black flex items-center justify-center">
    <div class="ios-spinner" style="border-top-color: #fff;"></div>
  </div>
{/if}

<!-- mode === 'native': the native ARKit UI covers the screen; WebView is hidden. -->
