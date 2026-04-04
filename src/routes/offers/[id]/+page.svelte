<script lang="ts">
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { apiGet, apiPost, apiGetBlob } from '$lib/api/client';

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
      detail = await apiGet<QuoteDetail>(`/api/v1/customer/inquiries/${quoteId}`);
    } catch { /* ignore */ }
    loading = false;
  }

  async function acceptOffer() {
    actionLoading = true;
    try {
      await apiPost(`/api/v1/customer/inquiries/${quoteId}/accept`);
      showConfirm = null;
      await load();
    } finally {
      actionLoading = false;
    }
  }

  async function rejectOffer() {
    actionLoading = true;
    try {
      await apiPost(`/api/v1/customer/inquiries/${quoteId}/reject`);
      showConfirm = null;
      await load();
    } finally {
      actionLoading = false;
    }
  }

  async function downloadPdf() {
    try {
      const blob = await apiGetBlob(`/api/v1/customer/inquiries/${quoteId}/pdf`);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `Angebot_${quoteId}.pdf`;
      a.click();
      URL.revokeObjectURL(url);
    } catch { /* ignore */ }
  }

  $effect(() => { load(); });

  function calcVolumePercent(d: QuoteDetail | null): number {
    if (!d?.estimated_volume_m3) return 0;
    return Math.min(100, Math.round((d.estimated_volume_m3 / 20) * 100));
  }
  const volumePercent = $derived(calcVolumePercent(detail));
</script>

<!-- Glass header -->
<header class="fixed top-0 w-full z-50 glass-header bento-shadow" style="padding-top: env(safe-area-inset-top, 0px);">
  <div class="h-16 flex items-center gap-4 px-6">
  <button onclick={() => goto('/offers')} class="text-white/80 active:scale-95 transition-all">
    <span class="material-symbols-outlined">arrow_back</span>
  </button>
  <h1 class="text-white text-sm font-bold tracking-tight uppercase flex-1">Angebotsdetails</h1>
  </div>
</header>

<main class="px-5 max-w-lg mx-auto" style="padding-top: calc(4rem + env(safe-area-inset-top, 0px) + 2rem); padding-bottom: calc(2.5rem + env(safe-area-inset-bottom, 0px));">
  {#if loading}
    <div class="flex justify-center py-20">
      <div class="w-12 h-12 rounded-2xl bg-primary flex items-center justify-center bento-shadow">
        <div class="w-5 h-5 border-2 border-primary-fixed/40 border-t-primary-fixed rounded-full animate-spin"></div>
      </div>
    </div>

  {:else if detail}
    <!-- Hero: volume progress -->
    <section class="mb-6">
      <div class="flex justify-between items-end mb-3">
        <div>
          <span class="text-secondary font-bold text-xs tracking-widest uppercase">Abschluss</span>
          <h2 class="text-2xl font-extrabold text-on-surface tracking-tight mt-0.5">Fast fertig.</h2>
        </div>
        {#if detail.estimated_volume_m3}
          <div class="text-right">
            <span class="block text-on-surface-variant text-xs font-medium">Gesamtvolumen</span>
            <span class="text-xl font-bold text-primary tracking-tight">{detail.estimated_volume_m3.toFixed(1)} m³</span>
          </div>
        {/if}
      </div>
      {#if detail.estimated_volume_m3}
        <div class="h-2.5 w-full bg-primary-fixed rounded-full overflow-hidden">
          <div class="h-full bg-secondary rounded-full transition-all duration-700" style="width: {volumePercent}%;"></div>
        </div>
        <p class="text-on-surface-variant text-xs mt-1.5">
          Ihr Inventar belegt ca. {volumePercent}% eines Standard-Umzugswagens.
        </p>
      {/if}
    </section>

    <!-- Route card -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow mb-4">
      <div class="flex justify-between items-center mb-4">
        <h3 class="font-bold text-xs tracking-widest uppercase text-primary">Umzugsroute</h3>
        {#if detail.distance_km}
          <span class="flex items-center gap-1 text-xs text-on-surface-variant font-medium">
            <span class="material-symbols-outlined" style="font-size: 14px;">route</span>
            {detail.distance_km.toFixed(0)} km
          </span>
        {/if}
      </div>
      <div class="flex gap-4">
        <div class="flex flex-col items-center pt-0.5">
          <span class="material-symbols-outlined text-primary" style="font-size: 20px; font-variation-settings: 'FILL' 1;">location_on</span>
          <div class="w-px flex-1 my-1 bg-outline-variant/30 min-h-8"></div>
          <span class="material-symbols-outlined text-secondary" style="font-size: 20px; font-variation-settings: 'FILL' 1;">flag</span>
        </div>
        <div class="flex-1 space-y-5">
          <div>
            <p class="text-[10px] font-bold text-on-surface-variant uppercase tracking-widest mb-0.5">Von</p>
            <p class="font-semibold text-on-surface text-sm">
              {detail.origin_address?.street}, {detail.origin_address?.postal_code} {detail.origin_address?.city}
            </p>
            {#if detail.origin_address?.floor}
              <p class="text-xs text-on-surface-variant mt-0.5">{detail.origin_address.floor}</p>
            {/if}
          </div>
          <div>
            <p class="text-[10px] font-bold text-on-surface-variant uppercase tracking-widest mb-0.5">Nach</p>
            <p class="font-semibold text-on-surface text-sm">
              {detail.destination_address?.street}, {detail.destination_address?.postal_code} {detail.destination_address?.city}
            </p>
            {#if detail.destination_address?.floor}
              <p class="text-xs text-on-surface-variant mt-0.5">{detail.destination_address.floor}</p>
            {/if}
          </div>
        </div>
      </div>
      {#if detail.preferred_date}
        <div class="mt-4 pt-4 flex items-center gap-3" style="border-top: 1px solid rgba(196,198,207,0.15);">
          <span class="material-symbols-outlined text-primary" style="font-size: 18px;">calendar_today</span>
          <div>
            <p class="text-[10px] font-bold text-on-surface-variant uppercase tracking-widest">Wunschtermin</p>
            <p class="font-semibold text-on-surface text-sm">{formatDate(detail.preferred_date)}</p>
          </div>
        </div>
      {/if}
    </div>

    <!-- Detected items -->
    {#if detail.estimation?.items?.length}
      <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow mb-4">
        <h3 class="font-bold text-xs tracking-widest uppercase text-primary mb-4">Erfasste Gegenstände</h3>
        <div class="space-y-2.5">
          {#each detail.estimation.items as item}
            <div class="flex justify-between items-center">
              <span class="text-sm text-on-surface">
                {item.quantity > 1 ? `${item.quantity}× ` : ''}{item.name}
              </span>
              <span class="text-xs font-medium text-on-surface-variant bg-surface-container px-2.5 py-0.5 rounded-full">
                {item.volume_m3.toFixed(2)} m³
              </span>
            </div>
          {/each}
        </div>
      </div>
    {/if}

    <!-- Offer cards -->
    {#each detail.offers as offer}
      <!-- Price summary (dark) -->
      <div class="bg-primary rounded-2xl p-6 bento-shadow mb-4">
        <h3 class="text-on-primary-container font-bold text-xs tracking-widest uppercase mb-4">Angebot</h3>
        <div class="text-center mb-5">
          <p class="text-white font-black text-4xl tracking-tight">{formatPrice(offer.price_cents)}</p>
          <p class="text-on-primary-container text-xs mt-1">inkl. 19% MwSt.</p>
        </div>
        <div class="flex justify-center gap-5 text-xs text-on-primary-container mb-5">
          {#if offer.persons}
            <span class="flex items-center gap-1">
              <span class="material-symbols-outlined" style="font-size: 14px;">group</span>
              {offer.persons} Helfer
            </span>
          {/if}
          {#if offer.hours_estimated}
            <span class="flex items-center gap-1">
              <span class="material-symbols-outlined" style="font-size: 14px;">schedule</span>
              {offer.hours_estimated} Std.
            </span>
          {/if}
          {#if offer.valid_until}
            <span class="flex items-center gap-1">
              <span class="material-symbols-outlined" style="font-size: 14px;">event</span>
              bis {formatDate(offer.valid_until)}
            </span>
          {/if}
        </div>
        <button
          onclick={() => downloadPdf()}
          class="w-full py-3 rounded-xl text-white text-xs font-bold uppercase tracking-widest transition-colors flex items-center justify-center gap-2"
          style="background: rgba(255,255,255,0.1);"
        >
          <span class="material-symbols-outlined" style="font-size: 16px;">download</span>
          PDF herunterladen
        </button>
      </div>

      <!-- Accept / Reject -->
      {#if ['draft', 'sent'].includes(offer.status)}
        <div class="grid grid-cols-2 gap-3 mb-6">
          <button
            onclick={() => showConfirm = 'reject'}
            class="py-4 rounded-xl font-bold text-sm text-on-surface-variant bg-surface-container-lowest bento-shadow active:scale-95 transition-all"
            style="border: 1px solid rgba(196,198,207,0.2);"
          >
            Ablehnen
          </button>
          <button
            onclick={() => showConfirm = 'accept'}
            class="py-4 rounded-xl font-bold text-sm text-white bg-gradient-to-br from-primary to-primary-container bento-shadow active:scale-95 transition-all"
          >
            Annehmen
          </button>
        </div>

        <!-- Confirm dialog -->
        {#if showConfirm}
          <div class="fixed inset-0 z-50 flex items-center justify-center px-6" style="background: rgba(0,0,0,0.5);">
            <div class="w-full max-w-sm bg-surface-container-lowest rounded-3xl p-6 bento-shadow">
              <div class="text-center mb-6">
                <div class="w-16 h-16 mx-auto rounded-2xl flex items-center justify-center mb-4 {showConfirm === 'accept' ? 'bg-primary' : 'bg-error-container'}">
                  <span class="material-symbols-outlined text-3xl {showConfirm === 'accept' ? 'text-white' : 'text-error'}">
                    {showConfirm === 'accept' ? 'check_circle' : 'cancel'}
                  </span>
                </div>
                <h3 class="text-lg font-bold text-on-surface mb-1">
                  {showConfirm === 'accept' ? 'Angebot annehmen?' : 'Angebot ablehnen?'}
                </h3>
                <p class="text-sm text-on-surface-variant leading-relaxed">
                  {showConfirm === 'accept'
                    ? 'Damit bestätigen Sie den Umzugsauftrag verbindlich.'
                    : 'Diese Aktion kann nicht rückgängig gemacht werden.'}
                </p>
              </div>
              <div class="flex gap-3">
                <button
                  onclick={() => showConfirm = null}
                  class="flex-1 py-3.5 rounded-xl font-medium text-sm text-on-surface-variant bg-surface-container"
                >
                  Abbrechen
                </button>
                <button
                  onclick={() => showConfirm === 'accept' ? acceptOffer() : rejectOffer()}
                  disabled={actionLoading}
                  class="flex-1 py-3.5 rounded-xl font-bold text-sm text-white disabled:opacity-50 {showConfirm === 'accept' ? 'bg-gradient-to-br from-primary to-primary-container' : 'bg-error'}"
                >
                  {actionLoading ? '...' : showConfirm === 'accept' ? 'Bestätigen' : 'Ablehnen'}
                </button>
              </div>
            </div>
          </div>
        {/if}

      {:else if offer.status === 'accepted'}
        <div class="rounded-2xl bg-surface-container p-5 text-center mb-4">
          <span class="material-symbols-outlined text-secondary block mb-1" style="font-size: 28px; font-variation-settings: 'FILL' 1;">check_circle</span>
          <p class="font-bold text-on-surface text-sm">Angebot angenommen</p>
        </div>
      {:else if offer.status === 'rejected'}
        <div class="rounded-2xl bg-error-container p-5 text-center mb-4">
          <span class="material-symbols-outlined text-error block mb-1" style="font-size: 28px;">cancel</span>
          <p class="font-bold text-error text-sm">Angebot abgelehnt</p>
        </div>
      {/if}
    {/each}
  {/if}
</main>
