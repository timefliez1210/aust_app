<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { apiGet } from '$lib/api/client';

  const quoteId = $derived($page.url.searchParams.get('quote_id'));

  interface QuoteStatus {
    id: string;
    status: string;
    estimated_volume_m3: number | null;
  }

  let status: QuoteStatus | null = $state(null);
  let pollTimer: ReturnType<typeof setInterval>;

  const steps = [
    { key: 'pending', label: 'Bilder hochgeladen', icon: 'cloud_upload' },
    { key: 'volume_estimated', label: 'Volumen berechnet', icon: 'calculate' },
    { key: 'offer_generated', label: 'Angebot erstellt', icon: 'description' },
  ];

  function stepDone(stepKey: string): boolean {
    if (!status) return false;
    const order = ['pending', 'volume_estimated', 'offer_generated', 'offer_sent', 'accepted'];
    return order.indexOf(status.status) >= order.indexOf(stepKey);
  }

  async function pollStatus() {
    if (!quoteId) return;
    try {
      status = await apiGet<QuoteStatus>(`/api/v1/customer/quotes/${quoteId}`);
      if (status && ['offer_generated', 'offer_sent', 'accepted'].includes(status.status)) {
        clearInterval(pollTimer);
      }
    } catch { /* keep polling */ }
  }

  $effect(() => {
    pollStatus();
    pollTimer = setInterval(pollStatus, 5000);
    return () => clearInterval(pollTimer);
  });

  const isReady = $derived(
    status !== null && ['offer_generated', 'offer_sent'].includes((status as QuoteStatus).status)
  );
</script>

<div class="min-h-screen bg-surface flex flex-col items-center justify-center px-6 text-center">
  <!-- Status indicator -->
  <div class="mb-10">
    {#if isReady}
      <div class="w-24 h-24 rounded-3xl bg-secondary-container flex items-center justify-center mx-auto mb-5 bento-shadow">
        <span class="material-symbols-outlined text-on-secondary-container" style="font-size: 44px; font-variation-settings: 'FILL' 1;">check_circle</span>
      </div>
      <p class="text-secondary font-bold text-xs tracking-widest uppercase mb-2">Abgeschlossen</p>
      <h1 class="text-2xl font-extrabold text-on-surface tracking-tight">Ihr Angebot ist bereit</h1>
    {:else}
      <div class="w-24 h-24 rounded-3xl bg-primary flex items-center justify-center mx-auto mb-5 bento-shadow relative overflow-hidden">
        <div class="absolute inset-0 bg-gradient-to-br from-primary to-primary-container"></div>
        <div class="relative w-10 h-10 border-4 border-primary-fixed/30 border-t-primary-fixed rounded-full animate-spin"></div>
      </div>
      <p class="text-secondary font-bold text-xs tracking-widest uppercase mb-2">KI-Analyse</p>
      <h1 class="text-2xl font-extrabold text-on-surface tracking-tight">Wird verarbeitet...</h1>
    {/if}
  </div>

  <!-- Steps -->
  <div class="w-full max-w-xs space-y-3 mb-10">
    {#each steps as step}
      <div class="flex items-center gap-4 p-4 rounded-2xl transition-all duration-300 {stepDone(step.key) ? 'bg-surface-container-lowest bento-shadow' : 'bg-surface-container/50'}">
        <div class="w-9 h-9 rounded-xl flex items-center justify-center shrink-0 transition-all {stepDone(step.key) ? 'bg-secondary-container' : 'bg-surface-container'}">
          {#if stepDone(step.key)}
            <span class="material-symbols-outlined text-on-secondary-container" style="font-size: 18px; font-variation-settings: 'FILL' 1;">check</span>
          {:else}
            <span class="material-symbols-outlined text-on-surface-variant" style="font-size: 18px;">{step.icon}</span>
          {/if}
        </div>
        <span class="text-sm text-left transition-all {stepDone(step.key) ? 'text-on-surface font-bold' : 'text-on-surface-variant font-medium'}">
          {step.label}
        </span>
      </div>
    {/each}
  </div>

  {#if isReady}
    <button
      onclick={() => goto(`/offers/${quoteId}`)}
      class="w-full max-w-xs h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all flex items-center justify-center gap-2"
    >
      Angebot ansehen
      <span class="material-symbols-outlined" style="font-size: 18px;">arrow_forward</span>
    </button>
  {/if}
</div>
