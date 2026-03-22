<script lang="ts">
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { WebDepthCapture } from '$lib/plugins/depth-capture';

  let depthCapture = new WebDepthCapture();
  let videoEl: HTMLVideoElement;
  let sessionActive = $state(false);
  let capturing = $state(false);
  let mode: 'photo' | 'video' = $state('photo');

  async function startCamera() {
    const support = await depthCapture.checkSupport();
    if (!support.supported) {
      alert('Kamera nicht verfügbar');
      return;
    }
    await depthCapture.startSession();
    sessionActive = true;
    if (videoEl && depthCapture.stream) {
      videoEl.srcObject = depthCapture.stream;
      await videoEl.play();
    }
  }

  async function takePhoto() {
    if (capturing) return;
    capturing = true;
    try {
      const frame = await depthCapture.captureFrame();
      capture.addFrame({
        ...frame,
        depthMapBase64: frame.depthMapBase64 || null,
        intrinsics: frame.intrinsics.fx ? frame.intrinsics : null,
      });
    } finally {
      capturing = false;
    }
  }

  async function finish() {
    await depthCapture.stopSession();
    sessionActive = false;
    goto('/scan/form');
  }

  $effect(() => {
    startCamera();
    return () => { depthCapture.stopSession(); };
  });
</script>

<div class="relative flex h-screen flex-col bg-black">
  <!-- Camera preview -->
  <video bind:this={videoEl} class="absolute inset-0 h-full w-full object-cover" playsinline muted></video>

  <!-- Overlay -->
  <div class="absolute inset-0 flex flex-col justify-between p-5">
    <!-- Top bar -->
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2 bg-black/40 px-3 py-1.5 rounded-full backdrop-blur-sm">
        {#if capturing}
          <div class="w-2.5 h-2.5 bg-error rounded-full animate-pulse"></div>
          <span class="text-white text-xs font-bold tracking-widest uppercase">Erfassung</span>
        {:else}
          <span class="text-white text-xs font-bold tracking-widest uppercase">
            {capture.frameCount} / 10 Fotos
          </span>
        {/if}
      </div>
      <button
        onclick={() => { depthCapture.stopSession(); goto('/'); }}
        class="w-10 h-10 flex items-center justify-center bg-black/40 rounded-full backdrop-blur-sm text-white active:scale-90 transition-transform"
      >
        <span class="material-symbols-outlined">close</span>
      </button>
    </div>

    <!-- Center guide -->
    <div class="flex items-center justify-center">
      <div class="relative w-60 h-60">
        <div class="absolute inset-0 rounded-2xl border border-white/20"></div>
        <!-- Corner brackets -->
        <div class="absolute top-0 left-0 w-6 h-6 border-t-2 border-l-2 border-white rounded-tl-lg"></div>
        <div class="absolute top-0 right-0 w-6 h-6 border-t-2 border-r-2 border-white rounded-tr-lg"></div>
        <div class="absolute bottom-0 left-0 w-6 h-6 border-b-2 border-l-2 border-white rounded-bl-lg"></div>
        <div class="absolute bottom-0 right-0 w-6 h-6 border-b-2 border-r-2 border-white rounded-br-lg"></div>
        <p class="absolute -bottom-9 left-0 right-0 text-center text-white/70 text-xs tracking-wide">
          Richten Sie die Kamera auf Ihre Möbel
        </p>
      </div>
    </div>

    <!-- Bottom controls -->
    <div class="flex flex-col items-center gap-5">
      <!-- Mode switcher -->
      <div class="flex gap-8 bg-black/40 px-7 py-2 rounded-full backdrop-blur-sm">
        <button
          onclick={() => mode = 'photo'}
          class="text-xs font-bold uppercase tracking-widest transition-colors {mode === 'photo' ? 'text-white' : 'text-white/40'}"
        >
          Foto
        </button>
        <button
          onclick={() => mode = 'video'}
          class="text-xs font-bold uppercase tracking-widest transition-colors {mode === 'video' ? 'text-secondary-container' : 'text-white/40'}"
        >
          Video
        </button>
      </div>

      <!-- Controls row -->
      <div class="w-full flex justify-between items-center px-2">
        <!-- Thumbnail of last capture -->
        <div class="w-12 h-12 rounded-xl bg-white/10 backdrop-blur-sm overflow-hidden border border-white/20">
          {#if capture.frames.length > 0}
            <img
              src="data:image/jpeg;base64,{capture.frames[capture.frames.length - 1].imageBase64}"
              alt=""
              class="w-full h-full object-cover"
            />
          {:else}
            <div class="w-full h-full flex items-center justify-center">
              <span class="material-symbols-outlined text-white/40" style="font-size: 20px;">photo_library</span>
            </div>
          {/if}
        </div>

        <!-- Shutter button -->
        <button
          onclick={takePhoto}
          disabled={capturing || capture.frameCount >= 10}
          class="relative w-20 h-20 rounded-full border-4 border-white flex items-center justify-center active:scale-90 transition-transform duration-150 disabled:opacity-50"
        >
          <div class="w-16 h-16 rounded-full bg-secondary flex items-center justify-center">
            <span class="material-symbols-outlined text-white" style="font-size: 28px; font-variation-settings: 'FILL' 1;">photo_camera</span>
          </div>
        </button>

        <!-- Done button -->
        <button
          onclick={finish}
          disabled={capture.frameCount === 0}
          class="px-5 py-2.5 rounded-xl font-bold text-sm transition-all disabled:opacity-40 {capture.frameCount > 0 ? 'bg-secondary-container text-on-secondary-container active:scale-95' : 'bg-white/10 text-white/40'}"
        >
          Fertig
        </button>
      </div>
    </div>
  </div>
</div>
