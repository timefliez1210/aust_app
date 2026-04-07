<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { DepthCapture } from '$lib/plugins/depth-capture';

  let completeHandle: any;
  let cancelHandle: any;
  let savedHandle: any;

  // Set to true when there are persisted items and we offer a resume choice.
  let showResume = $state(false);

  async function startNewSession() {
    showResume = false;
    capture.clear();

    completeHandle = await DepthCapture.addListener('sessionComplete', async () => {
      const { items } = await DepthCapture.getAllItems();
      capture.clear();
      // Compress + persist all items in parallel before navigating.
      await Promise.all(items.map(item => capture.addItem(item)));

      try {
        await capture.setIntrinsics(await DepthCapture.getIntrinsics());
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
      // Native overlay handles all feedback; nothing to do in JS.
    });

    await DepthCapture.startSession();
  }

  onMount(async () => {
    // Wait for IndexedDB restore to finish before checking for pending items.
    await capture.waitReady();

    if (capture.items.length > 0) {
      // Offer the user a choice instead of wiping their draft.
      showResume = true;
    } else {
      await startNewSession();
    }
  });

  onDestroy(() => {
    completeHandle?.remove();
    cancelHandle?.remove();
    savedHandle?.remove();
  });
</script>

{#if showResume}
  <!-- Resume UI — shown when a previous capture session was interrupted. -->
  <div class="fixed inset-0 bg-background flex flex-col" style="padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px);">
    <header class="glass-header bento-shadow">
      <div class="h-16 flex items-center px-6">
        <h1 class="text-white text-sm font-bold tracking-tight uppercase">Scan fortsetzen?</h1>
      </div>
    </header>

    <main class="flex-1 flex flex-col justify-center px-5 max-w-lg mx-auto w-full gap-5 pb-10">
      <!-- Pending items summary -->
      <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
        <div class="flex items-center gap-3 mb-4">
          <span class="material-symbols-outlined text-secondary" style="font-size: 28px; font-variation-settings: 'FILL' 1;">inventory_2</span>
          <div>
            <p class="font-bold text-on-surface text-sm">Nicht gesendeter Scan</p>
            <p class="text-on-surface-variant text-xs">{capture.itemCount} {capture.itemCount === 1 ? 'Gegenstand' : 'Gegenstände'} · {capture.totalFrames} Aufnahmen</p>
          </div>
        </div>
        <div class="space-y-1.5">
          {#each capture.items as item}
            <div class="flex items-center gap-2 px-3 py-2 bg-surface-container rounded-xl">
              <span class="material-symbols-outlined text-primary" style="font-size: 16px;">check_circle</span>
              <span class="text-on-surface text-xs font-medium">{item.label}</span>
              <span class="ml-auto text-outline text-[10px]">{item.frames.length} Frames</span>
            </div>
          {/each}
        </div>
      </div>

      <!-- Actions -->
      <button
        onclick={() => goto('/scan/form')}
        class="w-full bg-gradient-to-br from-primary to-primary-container text-white py-4 rounded-2xl font-bold text-sm tracking-wide uppercase bento-shadow active:scale-95 transition-all flex items-center justify-center gap-2"
      >
        <span class="material-symbols-outlined" style="font-size: 18px;">arrow_forward</span>
        Zum Formular fortfahren
      </button>

      <button
        onclick={startNewSession}
        class="w-full bg-surface-container text-on-surface-variant py-3.5 rounded-2xl font-bold text-sm tracking-wide uppercase active:scale-95 transition-all flex items-center justify-center gap-2"
      >
        <span class="material-symbols-outlined" style="font-size: 18px;">refresh</span>
        Neuen Scan starten (Daten verwerfen)
      </button>
    </main>
  </div>
{/if}

<!-- Native UI covers the entire screen when a session is active; WebView is hidden by the plugin. -->
