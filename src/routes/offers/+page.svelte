<script lang="ts">
  import { goto } from '$app/navigation';
  import { apiGet } from '$lib/api/client';
  import BottomNav from '$lib/components/BottomNav.svelte';

  interface QuoteSummary {
    id: string;
    status: string;
    preferred_date: string | null;
    created_at: string;
    origin_city: string | null;
    destination_city: string | null;
    estimated_volume_m3: number | null;
    price_cents: number | null;
  }

  let quotes: QuoteSummary[] = $state([]);
  let loading = $state(true);

  const statusLabels: Record<string, string> = {
    pending: 'In Bearbeitung',
    info_requested: 'Info angefordert',
    estimating: 'Wird berechnet',
    estimated: 'Volumen berechnet',
    offer_ready: 'Angebot erstellt',
    offer_sent: 'Angebot gesendet',
    accepted: 'Angenommen',
    rejected: 'Abgelehnt',
    expired: 'Abgelaufen',
    cancelled: 'Storniert',
    scheduled: 'Geplant',
    completed: 'Abgeschlossen',
    invoiced: 'Berechnet',
    paid: 'Bezahlt',
  };

  function statusStyle(status: string): string {
    if (['pending', 'info_requested', 'estimating', 'estimated'].includes(status))
      return 'bg-primary-fixed text-primary';
    if (['offer_ready', 'offer_sent'].includes(status))
      return 'bg-secondary-fixed text-secondary';
    if (status === 'accepted')
      return 'bg-surface-container-high text-on-surface';
    if (['rejected', 'expired', 'cancelled'].includes(status))
      return 'bg-error-container text-error';
    return 'bg-surface-container text-on-surface-variant';
  }

  function formatDate(d: string | null): string {
    if (!d) return '—';
    return new Date(d).toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric' });
  }

  function formatPrice(cents: number | null): string {
    if (!cents) return '—';
    return (cents / 100).toLocaleString('de-DE', { style: 'currency', currency: 'EUR' });
  }

  async function load() {
    loading = true;
    try {
      quotes = await apiGet<QuoteSummary[]>('/api/v1/customer/inquiries');
    } catch { /* empty */ }
    loading = false;
  }

  $effect(() => { load(); });
</script>

<!-- Glass header -->
<header class="fixed top-0 w-full z-50 glass-header flex justify-between items-center px-6 h-16 bento-shadow">
  <h1 class="text-white text-base font-black tracking-tight uppercase">Meine Angebote</h1>
  <button
    onclick={() => goto('/scan')}
    class="flex items-center gap-1.5 bg-secondary-container text-on-secondary-container px-3 py-1.5 rounded-full text-xs font-bold uppercase tracking-wide active:scale-95 transition-all"
  >
    <span class="material-symbols-outlined" style="font-size: 16px;">add</span>
    Neu
  </button>
</header>

<main class="pt-24 pb-28 px-5 max-w-lg mx-auto">
  {#if loading}
    <div class="flex justify-center py-20">
      <div class="w-12 h-12 rounded-2xl bg-primary flex items-center justify-center bento-shadow">
        <div class="w-5 h-5 border-2 border-primary-fixed/40 border-t-primary-fixed rounded-full animate-spin"></div>
      </div>
    </div>

  {:else if quotes.length === 0}
    <div class="flex flex-col items-center py-20 text-center">
      <div class="w-24 h-24 rounded-3xl bg-surface-container-high flex items-center justify-center mb-6">
        <span class="material-symbols-outlined text-on-surface-variant" style="font-size: 44px;">description</span>
      </div>
      <h2 class="text-lg font-bold text-on-surface mb-2">Noch keine Anfragen</h2>
      <p class="text-on-surface-variant text-sm mb-8 max-w-xs leading-relaxed">
        Starten Sie Ihren ersten Raumscan, um ein kostenloses Angebot zu erhalten.
      </p>
      <button
        onclick={() => goto('/scan')}
        class="h-14 px-8 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all flex items-center gap-2"
      >
        <span class="material-symbols-outlined" style="font-size: 18px;">photo_camera</span>
        Jetzt scannen
      </button>
    </div>

  {:else}
    <div class="space-y-3">
      {#each quotes as quote}
        <button
          onclick={() => goto(`/offers/${quote.id}`)}
          class="block w-full bg-surface-container-lowest rounded-2xl p-5 text-left bento-shadow active:scale-[0.99] transition-all"
        >
          <div class="flex items-start justify-between mb-3">
            <div>
              <p class="text-xs text-on-surface-variant font-medium">
                {formatDate(quote.preferred_date || quote.created_at)}
              </p>
              <p class="font-bold text-on-surface mt-0.5">
                {quote.origin_city || '?'} → {quote.destination_city || '?'}
              </p>
            </div>
            <span class="rounded-full px-3 py-1 text-[10px] font-black uppercase tracking-wide {statusStyle(quote.status)}">
              {statusLabels[quote.status] || quote.status}
            </span>
          </div>

          <div class="flex items-center gap-4 pt-3" style="border-top: 1px solid rgba(196,198,207,0.15);">
            {#if quote.estimated_volume_m3}
              <div class="flex items-center gap-1.5 text-on-surface-variant">
                <span class="material-symbols-outlined" style="font-size: 14px;">straighten</span>
                <span class="text-sm font-medium">{quote.estimated_volume_m3.toFixed(1)} m³</span>
              </div>
            {/if}
            {#if quote.price_cents}
              <div class="flex items-center gap-1.5">
                <span class="material-symbols-outlined text-secondary" style="font-size: 14px;">euro</span>
                <span class="text-sm font-bold text-on-surface">{formatPrice(quote.price_cents)}</span>
              </div>
            {/if}
            <span class="ml-auto material-symbols-outlined text-outline-variant" style="font-size: 18px;">chevron_right</span>
          </div>
        </button>
      {/each}
    </div>
  {/if}
</main>

<BottomNav />
