<script lang="ts">
  import { page } from '$app/stores';
  import { apiGet, apiPost } from '$lib/api/client';

  const quoteId = $derived($page.params.id);

  interface QuoteDetail {
    id: string;
    status: string;
    estimated_volume_m3: number | null;
    distance_km: number | null;
    preferred_date: string | null;
    origin_address: { street: string; city: string; postal_code: string; floor: string | null } | null;
    destination_address: { street: string; city: string; postal_code: string; floor: string | null } | null;
    estimation: {
      total_volume_m3: number;
      confidence_score: number;
      items: { name: string; volume_m3: number; quantity: number }[];
    } | null;
    offers: {
      id: string;
      price_cents: number;
      status: string;
      valid_until: string | null;
      persons: number | null;
      hours_estimated: number | null;
    }[];
  }

  let detail: QuoteDetail | null = $state(null);
  let loading = $state(true);
  let actionLoading = $state(false);
  let showConfirm: 'accept' | 'reject' | null = $state(null);

  function formatPrice(cents: number): string {
    return (cents / 100).toLocaleString('de-DE', { style: 'currency', currency: 'EUR' });
  }

  function formatDate(d: string | null): string {
    if (!d) return '—';
    return new Date(d).toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric' });
  }

  async function load() {
    loading = true;
    try {
      detail = await apiGet<QuoteDetail>(`/api/v1/customer/quotes/${quoteId}`);
    } catch { /* ignore */ }
    loading = false;
  }

  async function acceptOffer(offerId: string) {
    actionLoading = true;
    try {
      await apiPost(`/api/v1/customer/offers/${offerId}/accept`);
      showConfirm = null;
      await load();
    } finally {
      actionLoading = false;
    }
  }

  async function rejectOffer(offerId: string) {
    actionLoading = true;
    try {
      await apiPost(`/api/v1/customer/offers/${offerId}/reject`);
      showConfirm = null;
      await load();
    } finally {
      actionLoading = false;
    }
  }

  function downloadPdf(offerId: string) {
    const token = localStorage.getItem('aust_customer_token');
    const base = import.meta.env.VITE_API_BASE || 'http://localhost:8080';
    window.open(`${base}/api/v1/customer/offers/${offerId}/pdf?token=${token}`, '_blank');
  }

  $effect(() => { load(); });
</script>

<div class="min-h-screen bg-bg px-4 py-6">
  {#if loading}
    <div class="flex justify-center py-12">
      <div class="h-8 w-8 animate-spin rounded-full border-4 border-accent border-t-transparent"></div>
    </div>
  {:else if detail}
    <h1 class="mb-4 text-2xl font-bold text-primary">Angebotsdetails</h1>

    <!-- Addresses -->
    <section class="mb-4 rounded-xl bg-surface p-4 shadow-sm">
      <div class="mb-3">
        <p class="text-xs font-medium text-text-muted">VON</p>
        <p class="text-text">{detail.origin_address?.street}, {detail.origin_address?.postal_code} {detail.origin_address?.city}</p>
        {#if detail.origin_address?.floor}<p class="text-sm text-text-muted">{detail.origin_address.floor}</p>{/if}
      </div>
      <div>
        <p class="text-xs font-medium text-text-muted">NACH</p>
        <p class="text-text">{detail.destination_address?.street}, {detail.destination_address?.postal_code} {detail.destination_address?.city}</p>
        {#if detail.destination_address?.floor}<p class="text-sm text-text-muted">{detail.destination_address.floor}</p>{/if}
      </div>
    </section>

    <!-- Volume + Date -->
    <section class="mb-4 flex gap-3">
      {#if detail.estimated_volume_m3}
        <div class="flex-1 rounded-xl bg-surface p-4 text-center shadow-sm">
          <p class="text-2xl font-bold text-accent">{detail.estimated_volume_m3.toFixed(1)}</p>
          <p class="text-xs text-text-muted">m³ Volumen</p>
        </div>
      {/if}
      {#if detail.distance_km}
        <div class="flex-1 rounded-xl bg-surface p-4 text-center shadow-sm">
          <p class="text-2xl font-bold text-accent">{detail.distance_km.toFixed(0)}</p>
          <p class="text-xs text-text-muted">km Entfernung</p>
        </div>
      {/if}
      {#if detail.preferred_date}
        <div class="flex-1 rounded-xl bg-surface p-4 text-center shadow-sm">
          <p class="text-lg font-bold text-accent">{formatDate(detail.preferred_date)}</p>
          <p class="text-xs text-text-muted">Wunschtermin</p>
        </div>
      {/if}
    </section>

    <!-- Detected Items -->
    {#if detail.estimation?.items?.length}
      <section class="mb-4 rounded-xl bg-surface p-4 shadow-sm">
        <h2 class="mb-3 text-lg font-semibold text-primary">Erfasste Gegenstände</h2>
        <div class="space-y-1">
          {#each detail.estimation.items as item}
            <div class="flex justify-between text-sm">
              <span class="text-text">{item.quantity > 1 ? `${item.quantity}x ` : ''}{item.name}</span>
              <span class="text-text-muted">{item.volume_m3.toFixed(2)} m³</span>
            </div>
          {/each}
        </div>
      </section>
    {/if}

    <!-- Offers -->
    {#each detail.offers as offer}
      <section class="mb-4 rounded-xl bg-surface p-4 shadow-sm">
        <div class="mb-3 text-center">
          <p class="text-3xl font-bold text-primary">{formatPrice(offer.price_cents)}</p>
          <p class="text-sm text-text-muted">inkl. MwSt.</p>
        </div>
        <div class="mb-4 flex justify-center gap-6 text-sm text-text-muted">
          {#if offer.persons}<span>{offer.persons} Helfer</span>{/if}
          {#if offer.hours_estimated}<span>{offer.hours_estimated} Stunden</span>{/if}
          {#if offer.valid_until}<span>Gültig bis {formatDate(offer.valid_until)}</span>{/if}
        </div>

        <button onclick={() => downloadPdf(offer.id)} class="mb-3 w-full rounded-lg border border-border py-2.5 text-sm font-medium text-accent transition hover:bg-accent/5">
          PDF herunterladen
        </button>

        {#if ['draft', 'sent'].includes(offer.status)}
          <div class="flex gap-3">
            <button
              onclick={() => showConfirm = 'accept'}
              class="flex-1 rounded-lg bg-success py-3 font-semibold text-white transition hover:opacity-90"
            >
              Annehmen
            </button>
            <button
              onclick={() => showConfirm = 'reject'}
              class="flex-1 rounded-lg bg-error py-3 font-semibold text-white transition hover:opacity-90"
            >
              Ablehnen
            </button>
          </div>

          <!-- Confirmation Dialog -->
          {#if showConfirm}
            <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-6">
              <div class="w-full max-w-sm rounded-2xl bg-surface p-6 shadow-xl">
                <p class="mb-4 text-center text-lg font-semibold text-primary">
                  {showConfirm === 'accept' ? 'Angebot annehmen?' : 'Angebot ablehnen?'}
                </p>
                <p class="mb-6 text-center text-sm text-text-muted">
                  {showConfirm === 'accept' ? 'Damit bestätigen Sie den Umzugsauftrag.' : 'Sind Sie sicher? Diese Aktion kann nicht rückgängig gemacht werden.'}
                </p>
                <div class="flex gap-3">
                  <button onclick={() => showConfirm = null} class="flex-1 rounded-lg border border-border py-2.5 font-medium text-text-muted">
                    Abbrechen
                  </button>
                  <button
                    onclick={() => showConfirm === 'accept' ? acceptOffer(offer.id) : rejectOffer(offer.id)}
                    disabled={actionLoading}
                    class="flex-1 rounded-lg py-2.5 font-semibold text-white {showConfirm === 'accept' ? 'bg-success' : 'bg-error'} disabled:opacity-50"
                  >
                    {actionLoading ? '...' : showConfirm === 'accept' ? 'Bestätigen' : 'Ablehnen'}
                  </button>
                </div>
              </div>
            </div>
          {/if}
        {:else if offer.status === 'accepted'}
          <div class="rounded-lg bg-green-50 py-3 text-center font-semibold text-success">Angenommen</div>
        {:else if offer.status === 'rejected'}
          <div class="rounded-lg bg-red-50 py-3 text-center font-semibold text-error">Abgelehnt</div>
        {/if}
      </section>
    {/each}
  {/if}
</div>
