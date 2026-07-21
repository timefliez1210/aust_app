<script lang="ts">
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { apiGet, apiPost, apiGetBlob } from '$lib/api/client';
  import NavBar from '$lib/components/NavBar.svelte';
  import { tapHaptic, successHaptic, errorHaptic } from '$lib/haptics';
  import {
    MapPin, Flag, CalendarDays, Route, Users, Clock, Download,
    CheckCircle2, XCircle, Ruler,
  } from 'lucide-svelte';

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
      successHaptic();
      showConfirm = null;
      await load();
    } catch {
      errorHaptic();
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
    } catch {
      errorHaptic();
    } finally {
      actionLoading = false;
    }
  }

  async function downloadPdf() {
    tapHaptic();
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

<NavBar title="Angebot" back="/offers" />

<main
  class="px-4 max-w-lg mx-auto rise-in"
  style="padding-top: calc(3rem + env(safe-area-inset-top, 0px) + 1rem); padding-bottom: calc(2.5rem + env(safe-area-inset-bottom, 0px));"
>
  {#if loading}
    <div class="flex justify-center py-24">
      <div class="ios-spinner"></div>
    </div>

  {:else if detail}
    <!-- Offer price hero -->
    {#each detail.offers as offer}
      <div class="relative overflow-hidden rounded-[20px] mb-4 p-6 text-center"
        style="background: linear-gradient(160deg, #0a3057 0%, #022448 55%, #011830 100%);">
        <p class="text-[13px] font-medium mb-2" style="color: rgba(213,227,255,0.7);">Ihr Umzugsangebot</p>
        <p class="text-white font-bold text-[40px] leading-none tracking-tight mb-1">{formatPrice(offer.price_cents)}</p>
        <p class="text-[13px] mb-5" style="color: rgba(213,227,255,0.6);">inkl. 19 % MwSt.</p>
        <div class="flex justify-center gap-5 text-[13px] mb-5" style="color: rgba(213,227,255,0.85);">
          {#if offer.persons}
            <span class="flex items-center gap-1.5"><Users size={14} />{offer.persons} Helfer</span>
          {/if}
          {#if offer.hours_estimated}
            <span class="flex items-center gap-1.5"><Clock size={14} />{offer.hours_estimated} Std.</span>
          {/if}
          {#if offer.valid_until}
            <span class="flex items-center gap-1.5"><CalendarDays size={14} />bis {formatDate(offer.valid_until)}</span>
          {/if}
        </div>
        <button
          onclick={downloadPdf}
          class="w-full h-11 rounded-xl text-white text-[15px] font-semibold flex items-center justify-center gap-2"
          style="background: rgba(255,255,255,0.12);"
        >
          <Download size={16} />
          PDF herunterladen
        </button>
      </div>

      {#if ['draft', 'sent'].includes(offer.status)}
        <div class="grid grid-cols-2 gap-3 mb-6">
          <button onclick={() => { tapHaptic(); showConfirm = 'reject'; }} class="btn-gray">Ablehnen</button>
          <button onclick={() => { tapHaptic(); showConfirm = 'accept'; }} class="btn-filled">Annehmen</button>
        </div>
      {:else if offer.status === 'accepted'}
        <div class="ios-card p-5 text-center mb-4">
          <CheckCircle2 size={28} class="text-green mx-auto mb-1.5" />
          <p class="font-semibold text-label text-[15px]">Angebot angenommen</p>
        </div>
      {:else if offer.status === 'rejected'}
        <div class="ios-card p-5 text-center mb-4">
          <XCircle size={28} class="text-red mx-auto mb-1.5" />
          <p class="font-semibold text-label text-[15px]">Angebot abgelehnt</p>
        </div>
      {/if}
    {/each}

    <!-- Volume -->
    {#if detail.estimated_volume_m3}
      <p class="ios-section-header">Umzugsvolumen</p>
      <div class="ios-card mb-6 p-4">
        <div class="flex items-end justify-between mb-3">
          <span class="text-[15px] text-label-2">Gesamtvolumen</span>
          <span class="text-[22px] font-bold text-tint tracking-tight">{detail.estimated_volume_m3.toFixed(1)} m³</span>
        </div>
        <div class="h-2 w-full bg-fill rounded-full overflow-hidden">
          <div class="h-full rounded-full transition-all duration-700" style="width: {volumePercent}%; background: var(--ios-accent);"></div>
        </div>
        <p class="text-label-2 text-[13px] mt-2">
          Ihr Inventar belegt ca. {volumePercent} % eines Standard-Umzugswagens.
        </p>
      </div>
    {/if}

    <!-- Route -->
    <p class="ios-section-header">Umzugsroute</p>
    <div class="ios-card mb-6">
      <div class="ios-row flex items-start gap-3 px-4 py-3">
        <MapPin size={18} class="text-tint mt-0.5 shrink-0" />
        <div class="flex-1">
          <p class="text-[13px] text-label-2 mb-0.5">Von</p>
          <p class="text-[15px] text-label">
            {detail.origin_address?.street}, {detail.origin_address?.postal_code} {detail.origin_address?.city}
          </p>
          {#if detail.origin_address?.floor}
            <p class="text-[13px] text-label-2 mt-0.5">{detail.origin_address.floor}</p>
          {/if}
        </div>
      </div>
      <div class="ios-row flex items-start gap-3 px-4 py-3">
        <Flag size={18} class="text-accent mt-0.5 shrink-0" />
        <div class="flex-1">
          <p class="text-[13px] text-label-2 mb-0.5">Nach</p>
          <p class="text-[15px] text-label">
            {detail.destination_address?.street}, {detail.destination_address?.postal_code} {detail.destination_address?.city}
          </p>
          {#if detail.destination_address?.floor}
            <p class="text-[13px] text-label-2 mt-0.5">{detail.destination_address.floor}</p>
          {/if}
        </div>
      </div>
      {#if detail.distance_km}
        <div class="ios-row flex items-center gap-3 px-4 py-3">
          <Route size={18} class="text-label-2 shrink-0" />
          <span class="text-[15px] text-label">{detail.distance_km.toFixed(0)} km Entfernung</span>
        </div>
      {/if}
      {#if detail.preferred_date}
        <div class="ios-row flex items-center gap-3 px-4 py-3">
          <CalendarDays size={18} class="text-label-2 shrink-0" />
          <span class="text-[15px] text-label">Wunschtermin: {formatDate(detail.preferred_date)}</span>
        </div>
      {/if}
    </div>

    <!-- Detected items -->
    {#if detail.estimation?.items?.length}
      <p class="ios-section-header">Erfasste Gegenstände</p>
      <div class="ios-card mb-6">
        {#each detail.estimation.items as item}
          <div class="ios-row flex items-center justify-between px-4 py-2.5">
            <span class="text-[15px] text-label">
              {item.quantity > 1 ? `${item.quantity}× ` : ''}{item.name}
            </span>
            <span class="inline-flex items-center gap-1 text-[13px] text-label-2">
              <Ruler size={11} />
              {item.volume_m3.toFixed(2)} m³
            </span>
          </div>
        {/each}
      </div>
    {/if}

    <!-- Confirm sheet -->
    {#if showConfirm}
      <div class="fixed inset-0 z-[60] flex items-end justify-center" style="background: rgba(0,0,0,0.4);">
        <div class="w-full max-w-lg rounded-t-[20px] p-5 pb-8 rise-in"
          style="background: var(--ios-card); padding-bottom: calc(2rem + env(safe-area-inset-bottom, 0px));">
          <div class="w-9 h-1 rounded-full bg-fill-strong mx-auto mb-5"></div>
          <div class="text-center mb-6">
            {#if showConfirm === 'accept'}
              <CheckCircle2 size={44} class="text-green mx-auto mb-3" strokeWidth={1.5} />
            {:else}
              <XCircle size={44} class="text-red mx-auto mb-3" strokeWidth={1.5} />
            {/if}
            <h3 class="text-[20px] font-bold text-label mb-1">
              {showConfirm === 'accept' ? 'Angebot annehmen?' : 'Angebot ablehnen?'}
            </h3>
            <p class="text-[15px] text-label-2 leading-relaxed">
              {showConfirm === 'accept'
                ? 'Damit bestätigen Sie den Umzugsauftrag verbindlich.'
                : 'Diese Aktion kann nicht rückgängig gemacht werden.'}
            </p>
          </div>
          <div class="flex flex-col gap-2.5">
            <button
              onclick={() => showConfirm === 'accept' ? acceptOffer() : rejectOffer()}
              disabled={actionLoading}
              class="btn-filled"
              style={showConfirm === 'reject' ? 'background: var(--ios-red);' : ''}
            >
              {actionLoading ? '…' : showConfirm === 'accept' ? 'Verbindlich annehmen' : 'Ablehnen'}
            </button>
            <button onclick={() => { tapHaptic(); showConfirm = null; }} class="btn-gray">Abbrechen</button>
          </div>
        </div>
      </div>
    {/if}
  {/if}
</main>
