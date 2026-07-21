<script lang="ts">
  import { page } from '$app/stores';
  import { capture } from '$lib/stores/capture.svelte';
  import { House, Camera, FileText } from 'lucide-svelte';
  import { tapHaptic } from '$lib/haptics';

  const tabs = $derived([
    { href: '/', icon: House, label: 'Start', active: $page.url.pathname === '/', badge: false },
    {
      href: capture.itemCount > 0 ? '/scan/resume' : '/scan',
      icon: Camera,
      label: 'Scan',
      active: $page.url.pathname.startsWith('/scan'),
      badge: capture.itemCount > 0,
    },
    { href: '/offers', icon: FileText, label: 'Angebote', active: $page.url.pathname.startsWith('/offers'), badge: false },
  ]);
</script>

<nav class="fixed bottom-0 left-0 w-full tab-bar z-50" style="padding-bottom: env(safe-area-inset-bottom, 0px);">
  <div class="h-[49px] flex items-stretch max-w-lg mx-auto">
    {#each tabs as tab}
      <a
        href={tab.href}
        onclick={() => tapHaptic()}
        class="relative flex-1 flex flex-col items-center justify-center gap-0.5 {tab.active ? 'text-tint' : 'text-label-3'}"
      >
        <tab.icon size={24} strokeWidth={tab.active ? 2.2 : 1.8} />
        {#if tab.badge}
          <span class="absolute top-1 right-[calc(50%-18px)] w-2 h-2 rounded-full bg-accent"></span>
        {/if}
        <span class="text-[10px] {tab.active ? 'font-semibold' : 'font-medium'}">{tab.label}</span>
      </a>
    {/each}
  </div>
</nav>
