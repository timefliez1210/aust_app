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
    { key: 'pending', label: 'Bilder hochgeladen' },
    { key: 'volume_estimated', label: 'Volumen berechnet' },
    { key: 'offer_generated', label: 'Angebot erstellt' },
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
</script>

<div class="flex min-h-screen flex-col items-center justify-center px-6 text-center">
  <div class="mb-8">
    <div class="mx-auto mb-4 h-16 w-16 animate-spin rounded-full border-4 border-accent border-t-transparent"></div>
    <h1 class="text-2xl font-bold text-primary">Wird verarbeitet...</h1>
  </div>

  <div class="w-full max-w-sm space-y-4">
    {#each steps as step}
      <div class="flex items-center gap-3">
        <div class="flex h-8 w-8 items-center justify-center rounded-full {stepDone(step.key) ? 'bg-success text-white' : 'bg-border text-text-muted'}">
          {#if stepDone(step.key)}
            <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" /></svg>
          {:else}
            <div class="h-2 w-2 animate-pulse rounded-full bg-text-muted"></div>
          {/if}
        </div>
        <span class="text-sm {stepDone(step.key) ? 'text-text font-medium' : 'text-text-muted'}">{step.label}</span>
      </div>
    {/each}
  </div>

  {#if status && ['offer_generated', 'offer_sent'].includes(status.status)}
    <div class="mt-8">
      <p class="mb-4 text-lg font-semibold text-success">Ihr Angebot ist fertig!</p>
      <button
        onclick={() => goto(`/offers/${quoteId}`)}
        class="rounded-xl bg-accent px-8 py-3 font-semibold text-white shadow-md transition hover:bg-accent-hover"
      >
        Angebot ansehen
      </button>
    </div>
  {/if}
</div>
