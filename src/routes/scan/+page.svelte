<script lang="ts">
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { WebDepthCapture } from '$lib/plugins/depth-capture';

  let depthCapture = new WebDepthCapture();
  let videoEl: HTMLVideoElement;
  let sessionActive = $state(false);
  let capturing = $state(false);

  async function startCamera() {
    const support = await depthCapture.checkSupport();
    if (!support.supported) {
      alert('Kamera nicht verfügbar');
      return;
    }
    await depthCapture.startSession();
    sessionActive = true;
    // Attach stream to video element for preview
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
  <video bind:this={videoEl} class="h-full w-full object-cover" playsinline muted></video>

  <!-- Overlay -->
  <div class="absolute inset-0 flex flex-col justify-between p-4">
    <!-- Top bar -->
    <div class="flex items-center justify-between">
      <button onclick={() => { depthCapture.stopSession(); goto('/'); }} class="rounded-full bg-black/50 px-4 py-2 text-sm text-white">
        Abbrechen
      </button>
      <span class="rounded-full bg-black/50 px-4 py-2 text-sm font-medium text-white">
        {capture.frameCount} / 10 Fotos
      </span>
    </div>

    <!-- Guidance text -->
    <div class="text-center">
      <p class="mb-4 text-sm text-white/80">Richten Sie die Kamera auf Ihre Möbel</p>
    </div>

    <!-- Bottom controls -->
    <div class="flex items-end justify-between">
      <!-- Thumbnails -->
      <div class="flex gap-1 overflow-x-auto">
        {#each capture.frames.slice(-4) as frame}
          <img src="data:image/jpeg;base64,{frame.imageBase64}" alt="" class="h-12 w-12 rounded-md object-cover" />
        {/each}
      </div>

      <!-- Capture button -->
      <button
        onclick={takePhoto}
        disabled={capturing}
        class="flex h-20 w-20 items-center justify-center rounded-full border-4 border-white bg-white/20 transition active:scale-90"
      >
        <div class="h-16 w-16 rounded-full bg-white"></div>
      </button>

      <!-- Done button -->
      <button
        onclick={finish}
        disabled={capture.frameCount === 0}
        class="rounded-full bg-accent px-5 py-2.5 text-sm font-semibold text-white shadow-md disabled:opacity-40"
      >
        Fertig
      </button>
    </div>
  </div>
</div>
