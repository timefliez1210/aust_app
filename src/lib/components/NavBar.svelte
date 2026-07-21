<script lang="ts">
  import { goto } from '$app/navigation';
  import { ChevronLeft } from 'lucide-svelte';
  import { tapHaptic } from '$lib/haptics';
  import type { Snippet } from 'svelte';

  let {
    title,
    back = null,
    trailing = null,
  }: {
    title: string;
    /** Route to navigate to on back-tap; omit for no back button. */
    back?: string | null;
    trailing?: Snippet | null;
  } = $props();
</script>

<header class="fixed top-0 w-full z-50 nav-bar" style="padding-top: env(safe-area-inset-top, 0px);">
  <div class="h-12 flex items-center px-2 max-w-lg mx-auto relative">
    {#if back}
      <button
        onclick={() => { tapHaptic(); goto(back!); }}
        class="flex items-center text-tint -ml-1 pr-2 py-2 shrink-0"
        aria-label="Zurück"
      >
        <ChevronLeft size={28} strokeWidth={2.2} />
        <span class="text-[17px] -ml-1">Zurück</span>
      </button>
    {/if}
    <span class="absolute left-1/2 -translate-x-1/2 text-[17px] font-semibold text-label truncate max-w-[55%] text-center">
      {title}
    </span>
    {#if trailing}
      <div class="ml-auto shrink-0">{@render trailing()}</div>
    {/if}
  </div>
</header>
