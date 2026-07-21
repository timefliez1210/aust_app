<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { apiGet, ApiError } from '$lib/api/client';
  import { tapHaptic, successHaptic } from '$lib/haptics';
  import {
    CloudUpload, Calculator, FileText, Check, CheckCircle2,
    CircleAlert, Hourglass, ArrowRight, RotateCw,
  } from 'lucide-svelte';

  const STORAGE_KEY = 'aust_pending_inquiry';
  const MAX_POLLS = 72; // ~6 min at 5s intervals — then tell user to check email

  interface InquiryStatus {
    id: string;
    status: string;
    estimated_volume_m3: number | null;
  }

  type UiState = 'processing' | 'ready' | 'error' | 'timeout';

  let inquiryId: string | null = $state(null);
  let status: InquiryStatus | null = $state(null);
  let pollCount = $state(0);
  let uiState: UiState = $state('processing');
  let pollTimer: ReturnType<typeof setInterval>;

  const TERMINAL = ['offer_ready', 'offer_sent', 'accepted'];
  const FAILED   = ['cancelled', 'rejected', 'expired'];

  const steps = [
    { key: 'pending',     label: 'Bilder hochgeladen', icon: CloudUpload },
    { key: 'estimated',   label: 'Volumen berechnet',  icon: Calculator },
    { key: 'offer_ready', label: 'Angebot erstellt',   icon: FileText },
  ];

  const statusOrder = ['pending','info_requested','estimating','estimated','offer_ready','offer_sent','accepted'];

  function stepDone(key: string): boolean {
    if (!status) return false;
    return statusOrder.indexOf(status.status) >= statusOrder.indexOf(key);
  }

  async function poll() {
    if (!inquiryId) return;
    pollCount++;
    try {
      const data = await apiGet<InquiryStatus>(`/api/v1/customer/inquiries/${inquiryId}`);
      status = data;

      if (TERMINAL.includes(data.status)) {
        clearInterval(pollTimer);
        localStorage.removeItem(STORAGE_KEY);
        successHaptic();
        uiState = 'ready';
        return;
      }
      if (FAILED.includes(data.status)) {
        clearInterval(pollTimer);
        uiState = 'error';
        return;
      }
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) {
        clearInterval(pollTimer);
        goto('/auth?redirect=/offers');
        return;
      }
      // network error — keep polling
    }

    if (pollCount >= MAX_POLLS) {
      clearInterval(pollTimer);
      uiState = 'timeout';
    }
  }

  $effect(() => {
    inquiryId = $page.url.searchParams.get('inquiry_id') || localStorage.getItem(STORAGE_KEY);
    if (!inquiryId) { goto('/offers'); return; }

    // Ensure it's persisted so the user can return after backgrounding
    localStorage.setItem(STORAGE_KEY, inquiryId);

    poll();
    pollTimer = setInterval(poll, 5000);
    return () => clearInterval(pollTimer);
  });
</script>

<div class="min-h-screen bg-bg flex flex-col items-center justify-center px-6 text-center rise-in"
  style="padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px);">

  {#if uiState === 'processing'}
    <div class="mb-10">
      <div class="w-20 h-20 rounded-full bg-tint-soft flex items-center justify-center mx-auto mb-6">
        <div class="ios-spinner" style="width: 30px; height: 30px; border-top-color: var(--ios-tint);"></div>
      </div>
      <h1 class="text-[26px] font-bold text-label tracking-tight">Wird verarbeitet …</h1>
      <p class="text-label-2 text-[15px] mt-1.5">Das dauert in der Regel 1–3 Minuten.</p>
    </div>

    <div class="w-full max-w-xs ios-card">
      {#each steps as step}
        <div class="ios-row flex items-center gap-3.5 px-4 py-3.5">
          <div class="w-8 h-8 rounded-full flex items-center justify-center shrink-0 transition-colors
            {stepDone(step.key) ? 'bg-green' : 'bg-fill'}">
            {#if stepDone(step.key)}
              <Check size={16} color="#fff" strokeWidth={3} />
            {:else}
              <step.icon size={15} class="text-label-2" />
            {/if}
          </div>
          <span class="text-[15px] text-left {stepDone(step.key) ? 'text-label font-medium' : 'text-label-2'}">
            {step.label}
          </span>
        </div>
      {/each}
    </div>

  {:else if uiState === 'ready'}
    <div class="mb-10">
      <div class="w-20 h-20 rounded-full bg-green flex items-center justify-center mx-auto mb-6">
        <CheckCircle2 size={40} color="#fff" strokeWidth={2} />
      </div>
      <h1 class="text-[26px] font-bold text-label tracking-tight">Ihr Angebot ist bereit</h1>
      <p class="text-label-2 text-[15px] mt-2 max-w-xs mx-auto leading-relaxed">
        Wir haben Ihren Umzug analysiert und ein persönliches Angebot erstellt.
      </p>
    </div>
    <button
      onclick={() => { tapHaptic(); goto(`/offers/${inquiryId}`); }}
      class="btn-filled w-full max-w-xs"
    >
      Angebot ansehen
      <ArrowRight size={18} />
    </button>

  {:else if uiState === 'error'}
    <div class="mb-10">
      <div class="w-20 h-20 rounded-full bg-red-soft flex items-center justify-center mx-auto mb-6 text-red">
        <CircleAlert size={40} />
      </div>
      <h1 class="text-[26px] font-bold text-label tracking-tight">Verarbeitung fehlgeschlagen</h1>
      <p class="text-label-2 text-[15px] mt-2 max-w-xs mx-auto leading-relaxed">
        Bei der Analyse ist ein Fehler aufgetreten. Bitte starten Sie einen neuen Scan oder kontaktieren Sie uns.
      </p>
    </div>
    <button onclick={() => { tapHaptic(); goto('/scan'); }} class="btn-filled w-full max-w-xs">
      <RotateCw size={18} />
      Neuer Scan
    </button>

  {:else}
    <div class="mb-10">
      <div class="w-20 h-20 rounded-full bg-fill flex items-center justify-center mx-auto mb-6 text-label-2">
        <Hourglass size={36} />
      </div>
      <h1 class="text-[26px] font-bold text-label tracking-tight">Noch in Bearbeitung</h1>
      <p class="text-label-2 text-[15px] mt-2 max-w-xs mx-auto leading-relaxed">
        Die Analyse läuft im Hintergrund weiter. Sie erhalten eine E-Mail, sobald das Angebot fertig ist.
      </p>
    </div>
    <button onclick={() => { tapHaptic(); goto('/offers'); }} class="btn-filled w-full max-w-xs mb-3">
      Meine Angebote
      <ArrowRight size={18} />
    </button>
    <button
      onclick={() => { tapHaptic(); uiState = 'processing'; pollCount = 0; pollTimer = setInterval(poll, 5000); }}
      class="text-tint text-[15px] font-medium py-2"
    >
      Weiter warten
    </button>
  {/if}

</div>
