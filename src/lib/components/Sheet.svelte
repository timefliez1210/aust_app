<script lang="ts">
  import { X } from 'lucide-svelte';
  import type { Snippet } from 'svelte';

  let {
    title,
    onclose,
    children,
  }: {
    title: string;
    onclose: () => void;
    children: Snippet;
  } = $props();
</script>

<div class="fixed inset-0 z-[60] flex items-end justify-center">
  <button class="absolute inset-0 bg-black/40" aria-label="Schließen" onclick={onclose}></button>
  <div
    class="relative w-full max-w-lg max-h-[90vh] overflow-y-auto no-scrollbar rounded-t-[20px] bg-bg px-4 pt-2 sheet-in"
    style="padding-bottom: calc(env(safe-area-inset-bottom, 0px) + 16px);"
    role="dialog"
    aria-modal="true"
    aria-label={title}
  >
    <div class="w-9 h-[5px] rounded-full bg-fill-strong mx-auto mb-3"></div>
    <div class="flex items-center justify-between mb-4">
      <h2 class="text-[20px] font-bold text-label tracking-tight">{title}</h2>
      <button onclick={onclose} aria-label="Schließen"
        class="w-8 h-8 rounded-full bg-fill text-label-2 flex items-center justify-center">
        <X size={16} strokeWidth={2.5} />
      </button>
    </div>
    {@render children()}
  </div>
</div>
