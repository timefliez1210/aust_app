<script lang="ts">
  import { page } from '$app/stores';
  import { capture } from '$lib/stores/capture.svelte';
</script>

<nav class="fixed bottom-0 left-0 w-full bg-white/90 backdrop-blur-xl px-4 rounded-t-3xl z-50"
  style="padding-bottom: env(safe-area-inset-bottom, 0px); box-shadow: 0 -10px 40px rgba(2, 36, 72, 0.05);">
  <div class="h-20 flex justify-around items-center">
  <a
    href="/"
    class="flex flex-col items-center justify-center px-5 py-2 rounded-xl transition-all duration-200
      {$page.url.pathname === '/'
        ? 'bg-primary-container text-white scale-110'
        : 'text-on-surface-variant hover:text-secondary-container'}"
  >
    <span class="material-symbols-outlined" style="font-size: 22px;">home</span>
    <span class="mt-1 text-[10px] font-bold tracking-widest uppercase">Start</span>
  </a>

  <a
    href={capture.itemCount > 0 ? '/scan/resume' : '/scan'}
    class="relative flex flex-col items-center justify-center px-5 py-2 rounded-xl transition-all duration-200
      {$page.url.pathname.startsWith('/scan')
        ? 'bg-primary-container text-white scale-110'
        : 'text-on-surface-variant hover:text-secondary-container'}"
  >
    <span class="material-symbols-outlined" style="font-size: 22px;">photo_camera</span>
    {#if capture.itemCount > 0}
      <span class="absolute top-1 right-3 w-2 h-2 rounded-full bg-secondary"></span>
    {/if}
    <span class="mt-1 text-[10px] font-bold tracking-widest uppercase">Scan</span>
  </a>

  <a
    href="/offers"
    class="flex flex-col items-center justify-center px-5 py-2 rounded-xl transition-all duration-200
      {$page.url.pathname.startsWith('/offers')
        ? 'bg-primary-container text-white scale-110'
        : 'text-on-surface-variant hover:text-secondary-container'}"
  >
    <span class="material-symbols-outlined" style="font-size: 22px;">description</span>
    <span class="mt-1 text-[10px] font-bold tracking-widest uppercase">Angebote</span>
  </a>
  </div>
</nav>
