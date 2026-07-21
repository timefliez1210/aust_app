<script lang="ts">
  import { goto } from '$app/navigation';
  import { auth } from '$lib/stores/auth.svelte';
  import { capture } from '$lib/stores/capture.svelte';
  import { apiGet } from '$lib/api/client';
  import BottomNav from '$lib/components/BottomNav.svelte';
  import { tapHaptic } from '$lib/haptics';
  import {
    Camera, FileText, ChevronRight, Lightbulb, DoorOpen, Footprints,
    CircleUserRound, LogOut, Clock, CheckCircle2, PartyPopper, ScanLine,
  } from 'lucide-svelte';

  interface LatestInquiry {
    id: string;
    status: string;
    origin_city: string | null;
    destination_city: string | null;
    price_cents: number | null;
  }

  let latestInquiry: LatestInquiry | null = $state(null);

  const IN_PROGRESS = ['pending', 'info_requested', 'estimating', 'estimated'];
  const OFFER_READY = ['offer_ready', 'offer_sent'];

  function inquiryStatusLabel(s: string): string {
    if (IN_PROGRESS.includes(s)) return 'Analyse läuft …';
    if (OFFER_READY.includes(s)) return 'Angebot bereit — jetzt ansehen';
    if (s === 'accepted') return 'Umzug bestätigt';
    return '';
  }

  function inquiryTarget(inquiry: LatestInquiry): string {
    if (IN_PROGRESS.includes(inquiry.status)) {
      const pending = localStorage.getItem('aust_pending_inquiry');
      if (pending === inquiry.id) return `/scan/processing?inquiry_id=${inquiry.id}`;
    }
    return `/offers/${inquiry.id}`;
  }

  async function loadLatestInquiry() {
    if (!auth.isAuthenticated) return;
    try {
      const list = await apiGet<LatestInquiry[]>('/api/v1/customer/inquiries');
      const active = list.find(i => [...IN_PROGRESS, ...OFFER_READY, 'accepted'].includes(i.status));
      latestInquiry = active ?? list[0] ?? null;
    } catch { /* ignore */ }
  }

  $effect(() => {
    if (auth.isAuthenticated) loadLatestInquiry();
    else latestInquiry = null;
  });

  async function startScan() {
    tapHaptic();
    await capture.waitReady();
    if (capture.items.length > 0) {
      goto('/scan/resume');
      return;
    }
    if (auth.isAuthenticated) {
      const seen = localStorage.getItem('tutorialSeen');
      goto(seen ? '/scan' : '/tutorial');
    } else {
      goto('/auth?redirect=/tutorial');
    }
  }

  function viewOffers() {
    tapHaptic();
    if (auth.isAuthenticated) goto('/offers');
    else goto('/auth?redirect=/offers');
  }

  const tips = [
    { icon: Lightbulb, title: 'Gutes Licht', desc: 'Alle Lampen einschalten' },
    { icon: DoorOpen, title: 'Türen öffnen', desc: 'Schränke und Lager zeigen' },
    { icon: Footprints, title: 'Freie Wege', desc: 'Möbel gut zugänglich halten' },
  ];
</script>

<main
  class="px-4 max-w-lg mx-auto rise-in"
  style="padding-top: calc(env(safe-area-inset-top, 0px) + 1.25rem); padding-bottom: calc(5.5rem + env(safe-area-inset-bottom, 0px));"
>
  <!-- Large title row -->
  <div class="flex items-end justify-between px-1 mb-5">
    <div>
      <p class="text-[13px] text-label-2 font-medium mb-0.5">
        {auth.isAuthenticated && auth.customer ? 'Willkommen zurück' : 'Willkommen'}
      </p>
      <h1 class="text-[34px] leading-none font-bold tracking-tight text-label">AUST Umzüge</h1>
    </div>
    {#if auth.isAuthenticated}
      <button onclick={() => { tapHaptic(); auth.logout(); }} class="p-2 -mr-1 text-label-2" aria-label="Abmelden">
        <LogOut size={22} strokeWidth={1.8} />
      </button>
    {:else}
      <button onclick={() => { tapHaptic(); goto('/auth'); }} class="p-2 -mr-1 text-tint" aria-label="Anmelden">
        <CircleUserRound size={24} strokeWidth={1.8} />
      </button>
    {/if}
  </div>

  <!-- Hero card -->
  <button
    onclick={startScan}
    class="w-full text-left relative overflow-hidden rounded-[20px] mb-4 tappable"
    style="background: linear-gradient(160deg, #0a3057 0%, #022448 55%, #011830 100%);"
  >
    <div class="p-6 pb-7">
      <div class="w-12 h-12 rounded-2xl flex items-center justify-center mb-4" style="background: rgba(255,255,255,0.12);">
        <ScanLine size={26} color="#fff" strokeWidth={1.8} />
      </div>
      <h2 class="text-white text-[22px] font-bold tracking-tight mb-1">Wohnung scannen</h2>
      <p class="text-[15px] leading-snug mb-5 max-w-[17rem]" style="color: rgba(213,227,255,0.75);">
        Möbel mit der Kamera erfassen — Ihr persönliches Angebot kommt in Minuten.
      </p>
      <span
        class="inline-flex items-center gap-2 h-11 px-5 rounded-full text-[15px] font-semibold text-white"
        style="background: var(--aust-orange);"
      >
        <Camera size={18} strokeWidth={2} />
        Scan starten
      </span>
    </div>
  </button>

  <!-- Status (authenticated) -->
  {#if auth.isAuthenticated}
    <p class="ios-section-header mt-2">Ihr Umzug</p>
    <div class="ios-card mb-4">
      {#if latestInquiry && inquiryStatusLabel(latestInquiry.status)}
        <button
          onclick={() => { tapHaptic(); goto(inquiryTarget(latestInquiry!)); }}
          class="ios-row w-full flex items-center gap-3 px-4 py-3.5 tappable text-left rounded-[14px]"
        >
          <div class="w-9 h-9 rounded-full flex items-center justify-center shrink-0
            {IN_PROGRESS.includes(latestInquiry.status) ? 'bg-tint-soft text-tint' : 'bg-accent-soft text-accent'}">
            {#if IN_PROGRESS.includes(latestInquiry.status)}
              <Clock size={18} strokeWidth={2} />
            {:else if latestInquiry.status === 'accepted'}
              <PartyPopper size={18} strokeWidth={2} />
            {:else}
              <CheckCircle2 size={18} strokeWidth={2} />
            {/if}
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-[17px] text-label truncate">
              {latestInquiry.origin_city || '–'} → {latestInquiry.destination_city || '–'}
            </p>
            <p class="text-[13px] text-label-2">{inquiryStatusLabel(latestInquiry.status)}</p>
          </div>
          <ChevronRight size={18} class="text-label-3 shrink-0" />
        </button>
      {:else}
        <div class="flex items-center gap-3 px-4 py-3.5">
          <div class="w-9 h-9 rounded-full bg-fill flex items-center justify-center shrink-0 text-label-2">
            <Camera size={18} strokeWidth={2} />
          </div>
          <div class="flex-1">
            <p class="text-[17px] text-label">Noch kein Scan</p>
            <p class="text-[13px] text-label-2">Starten Sie oben Ihren ersten Raumscan</p>
          </div>
        </div>
      {/if}
    </div>
  {/if}

  <!-- Offers shortcut -->
  <div class="ios-card mb-4">
    <button onclick={viewOffers} class="w-full flex items-center gap-3 px-4 py-3.5 tappable text-left rounded-[14px]">
      <div class="w-9 h-9 rounded-full bg-tint-soft flex items-center justify-center shrink-0 text-tint">
        <FileText size={18} strokeWidth={2} />
      </div>
      <div class="flex-1">
        <p class="text-[17px] text-label">Meine Angebote</p>
        <p class="text-[13px] text-label-2">Alle Umzugsangebote auf einen Blick</p>
      </div>
      <ChevronRight size={18} class="text-label-3 shrink-0" />
    </button>
  </div>

  <!-- Prep tips -->
  <p class="ios-section-header mt-2">So gelingt der Scan</p>
  <div class="ios-card">
    {#each tips as tip}
      <div class="ios-row flex items-center gap-3 px-4 py-3">
        <div class="w-8 h-8 rounded-lg bg-accent-soft flex items-center justify-center shrink-0 text-accent">
          <tip.icon size={16} strokeWidth={2} />
        </div>
        <div class="flex-1">
          <p class="text-[15px] text-label font-medium">{tip.title}</p>
          <p class="text-[13px] text-label-2">{tip.desc}</p>
        </div>
      </div>
    {/each}
    <div class="ios-row flex items-center gap-2 px-4 py-3">
      <Clock size={14} class="text-label-2" />
      <span class="text-[13px] text-label-2">Dauer: ca. 10–15 Minuten</span>
    </div>
  </div>
</main>

<BottomNav />
