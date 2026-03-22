<script lang="ts">
  import { goto } from '$app/navigation';
  import { apiGet } from '$lib/api/client';

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
    pending: 'Wird bearbeitet',
    volume_estimated: 'Volumen berechnet',
    offer_generated: 'Angebot erstellt',
    offer_sent: 'Angebot gesendet',
    accepted: 'Akzeptiert',
    rejected: 'Abgelehnt',
    done: 'Erledigt',
    paid: 'Bezahlt',
  };

  const statusColors: Record<string, string> = {
    pending: 'bg-amber-100 text-amber-700',
    volume_estimated: 'bg-purple-100 text-purple-700',
    offer_generated: 'bg-blue-100 text-blue-700',
    offer_sent: 'bg-indigo-100 text-indigo-700',
    accepted: 'bg-green-100 text-green-700',
    rejected: 'bg-red-100 text-red-700',
    done: 'bg-green-100 text-green-700',
    paid: 'bg-green-200 text-green-800',
  };

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
      quotes = await apiGet<QuoteSummary[]>('/api/v1/customer/quotes');
    } catch { /* empty */ }
    loading = false;
  }

  $effect(() => { load(); });
</script>

<div class="min-h-screen bg-bg px-4 py-6">
  <h1 class="mb-6 text-2xl font-bold text-primary">Meine Anfragen</h1>

  {#if loading}
    <div class="flex justify-center py-12">
      <div class="h-8 w-8 animate-spin rounded-full border-4 border-accent border-t-transparent"></div>
    </div>
  {:else if quotes.length === 0}
    <div class="flex flex-col items-center py-16 text-center">
      <p class="mb-4 text-text-muted">Noch keine Anfragen</p>
      <button onclick={() => goto('/scan')} class="rounded-xl bg-accent px-6 py-3 font-semibold text-white shadow-md">
        Jetzt scannen
      </button>
    </div>
  {:else}
    <div class="space-y-3">
      {#each quotes as quote}
        <button
          onclick={() => goto(`/offers/${quote.id}`)}
          class="block w-full rounded-xl bg-surface p-4 text-left shadow-sm transition hover:shadow-md"
        >
          <div class="mb-2 flex items-center justify-between">
            <span class="text-sm text-text-muted">{formatDate(quote.preferred_date || quote.created_at)}</span>
            <span class="rounded-full px-3 py-0.5 text-xs font-medium {statusColors[quote.status] || 'bg-gray-100 text-gray-600'}">
              {statusLabels[quote.status] || quote.status}
            </span>
          </div>
          <p class="font-medium text-text">
            {quote.origin_city || '?'} → {quote.destination_city || '?'}
          </p>
          <div class="mt-1 flex gap-4 text-sm text-text-muted">
            {#if quote.estimated_volume_m3}
              <span>{quote.estimated_volume_m3.toFixed(1)} m³</span>
            {/if}
            {#if quote.price_cents}
              <span class="font-medium text-text">{formatPrice(quote.price_cents)}</span>
            {/if}
          </div>
        </button>
      {/each}
    </div>
  {/if}
</div>
