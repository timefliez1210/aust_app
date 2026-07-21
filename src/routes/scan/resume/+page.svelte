<script lang="ts">
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { tapHaptic } from '$lib/haptics';
  import { Box, CheckCircle2, ArrowRight, RotateCw, Ruler } from 'lucide-svelte';
</script>

<div class="fixed inset-0 bg-bg flex flex-col max-w-lg mx-auto"
  style="padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px);">

  <main class="flex-1 flex flex-col justify-center px-4 w-full gap-5 pb-10 rise-in">
    <div class="text-center mb-1">
      <div class="w-16 h-16 rounded-full bg-accent-soft text-accent flex items-center justify-center mx-auto mb-4">
        <Box size={28} strokeWidth={1.8} />
      </div>
      <h1 class="text-[24px] font-bold text-label tracking-tight mb-1">Scan fortsetzen?</h1>
      <p class="text-label-2 text-[15px]">
        {capture.itemCount} {capture.itemCount === 1 ? 'Gegenstand' : 'Gegenstände'}
        · {capture.totalFrames} Aufnahmen — noch nicht gesendet
      </p>
    </div>

    <div class="ios-card max-h-64 overflow-y-auto no-scrollbar">
      {#each capture.items as item}
        <div class="ios-row flex items-center gap-3 px-4 py-2.5">
          <CheckCircle2 size={17} class="text-green shrink-0" />
          <span class="text-[15px] text-label flex-1">{item.label}</span>
          {#if item.volumeM3 != null}
            <span class="inline-flex items-center gap-1 text-[13px] text-label-2">
              <Ruler size={11} />
              ≈ {item.volumeM3.toFixed(1)} m³
            </span>
          {:else}
            <span class="text-[13px] text-label-3">{item.frames.length} Fotos</span>
          {/if}
        </div>
      {/each}
    </div>

    <div class="flex flex-col gap-2.5">
      <button onclick={() => { tapHaptic(); goto('/scan/form'); }} class="btn-filled w-full">
        Zum Formular fortfahren
        <ArrowRight size={18} />
      </button>
      <button onclick={() => { tapHaptic(); capture.clear(); goto('/scan'); }} class="btn-gray w-full">
        <RotateCw size={17} />
        Neuen Scan starten
      </button>
    </div>
  </main>
</div>
