<script lang="ts">
  import { goto } from '$app/navigation';
  import { apiGet } from '$lib/api/client';
  import BottomNav from '$lib/components/BottomNav.svelte';
  import { tapHaptic } from '$lib/haptics';
  import { Plus, FileText, Camera, ChevronRight, Ruler } from 'lucide-svelte';

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
      return 'background: var(--ios-tint-soft); color: var(--ios-tint);';
    if (['offer_ready', 'offer_sent'].includes(status))
      return 'background: var(--ios-accent-soft); color: var(--ios-accent);';
    if (status === 'accepted')
      return 'background: rgba(52,199,89,0.15); color: var(--ios-green);';
    if (['rejected', 'expired', 'cancelled'].includes(status))
      return 'background: var(--ios-red-soft); color: var(--ios-red);';
    return 'background: var(--ios-fill); color: var(--ios-label-2);';
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

<main
  class="px-4 max-w-lg mx-auto rise-in"
  style="padding-top: calc(env(safe-area-inset-top, 0px) + 1.25rem); padding-bottom: calc(5.5rem + env(safe-area-inset-bottom, 0px));"
>
  <div class="flex items-end justify-between px-1 mb-5">
    <h1 class="text-[34px] leading-none font-bold tracking-tight text-label">Angebote</h1>
    <button
      onclick={() => { tapHaptic(); goto('/scan'); }}
      class="w-9 h-9 rounded-full bg-tint-soft text-tint flex items-center justify-center"
      aria-label="Neuer Scan"
    >
      <Plus size={20} strokeWidth={2.2} />
    </button>
  </div>

  {#if loading}
    <div class="flex justify-center py-24">
      <div class="ios-spinner"></div>
    </div>

  {:else if quotes.length === 0}
    <div class="flex flex-col items-center py-20 text-center">
      <div class="w-20 h-20 rounded-full bg-fill flex items-center justify-center mb-6 text-label-3">
        <FileText size={36} strokeWidth={1.5} />
      </div>
      <h2 class="text-[20px] font-bold text-label mb-1.5">Noch keine Anfragen</h2>
      <p class="text-label-2 text-[15px] mb-8 max-w-xs leading-relaxed">
        Starten Sie Ihren ersten Raumscan, um ein kostenloses Angebot zu erhalten.
      </p>
      <button onclick={() => { tapHaptic(); goto('/scan'); }} class="btn-filled px-8">
        <Camera size={18} />
        Jetzt scannen
      </button>
    </div>

  {:else}
    <div class="ios-card">
      {#each quotes as quote}
        <button
          onclick={() => { tapHaptic(); goto(`/offers/${quote.id}`); }}
          class="ios-row w-full flex items-center gap-3 px-4 py-3.5 tappable text-left"
        >
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 mb-0.5">
              <p class="text-[17px] text-label truncate">
                {quote.origin_city || '–'} → {quote.destination_city || '–'}
              </p>
            </div>
            <div class="flex items-center gap-3 text-[13px] text-label-2">
              <span>{formatDate(quote.preferred_date || quote.created_at)}</span>
              {#if quote.estimated_volume_m3}
                <span class="inline-flex items-center gap-1">
                  <Ruler size={11} />
                  {quote.estimated_volume_m3.toFixed(1)} m³
                </span>
              {/if}
              {#if quote.price_cents}
                <span class="font-semibold text-label">{formatPrice(quote.price_cents)}</span>
              {/if}
            </div>
          </div>
          <span class="shrink-0 rounded-full px-2.5 py-1 text-[11px] font-semibold" style={statusStyle(quote.status)}>
            {statusLabels[quote.status] || quote.status}
          </span>
          <ChevronRight size={16} class="text-label-3 shrink-0" />
        </button>
      {/each}
    </div>
  {/if}
</main>

<BottomNav />
