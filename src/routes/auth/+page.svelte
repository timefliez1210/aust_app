<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { auth } from '$lib/stores/auth.svelte';
  import { tapHaptic, successHaptic, errorHaptic } from '$lib/haptics';
  import { Mail, ShieldCheck } from 'lucide-svelte';

  let email = $state('');
  let code = $state('');
  let step: 'email' | 'code' = $state('email');
  let codeInputs: HTMLInputElement[] = $state([]);

  const redirect = $derived($page.url.searchParams.get('redirect') || '/');

  async function requestCode(e: SubmitEvent) {
    e.preventDefault();
    tapHaptic();
    try {
      await auth.requestOtp(email);
      step = 'code';
      requestAnimationFrame(() => codeInputs[0]?.focus());
    } catch {
      errorHaptic();
    }
  }

  async function verifyCode() {
    try {
      await auth.verifyOtp(email, code);
      successHaptic();
      goto(redirect);
    } catch {
      errorHaptic();
      code = '';
      codeInputs.forEach(i => { if (i) i.value = ''; });
      codeInputs[0]?.focus();
    }
  }

  function handleCodeInput(index: number, event: Event) {
    const input = event.target as HTMLInputElement;
    const value = input.value;
    if (value.length === 1 && index < 5) {
      codeInputs[index + 1]?.focus();
    }
    code = codeInputs.map(i => i?.value || '').join('');
    if (code.length === 6) verifyCode();
  }

  function handleCodeKeydown(index: number, event: KeyboardEvent) {
    if (event.key === 'Backspace' && !codeInputs[index]?.value && index > 0) {
      codeInputs[index - 1]?.focus();
    }
  }
</script>

<main
  class="min-h-screen bg-bg flex flex-col px-6 max-w-lg mx-auto rise-in"
  style="padding-top: calc(env(safe-area-inset-top, 0px) + 3.5rem); padding-bottom: calc(env(safe-area-inset-bottom, 0px) + 2rem);"
>
  {#if step === 'email'}
    <div class="mb-10">
      <div class="w-16 h-16 rounded-[18px] bg-tint flex items-center justify-center mb-6">
        <Mail size={28} color="#fff" strokeWidth={1.8} />
      </div>
      <h1 class="text-[28px] font-bold text-label tracking-tight mb-1.5">Anmelden</h1>
      <p class="text-label-2 text-[16px] leading-relaxed">
        Wir senden Ihnen einen 6-stelligen Code an Ihre E-Mail-Adresse — ganz ohne Passwort.
      </p>
    </div>

    <form onsubmit={requestCode}>
      <div class="ios-card mb-5">
        <div class="flex items-center px-4">
          <span class="w-16 text-[15px] text-label-2 shrink-0">E-Mail</span>
          <input
            id="email"
            type="email"
            bind:value={email}
            required
            placeholder="ihre@email.de"
            class="ios-input"
            autocomplete="email"
            style="min-height: 50px;"
          />
        </div>
      </div>

      <button type="submit" disabled={auth.loading || !email} class="btn-filled w-full">
        {auth.loading ? 'Wird gesendet …' : 'Code anfordern'}
      </button>
    </form>

  {:else}
    <div class="mb-10 text-center">
      <div class="w-16 h-16 rounded-[18px] bg-accent-soft text-accent flex items-center justify-center mb-6 mx-auto">
        <ShieldCheck size={30} strokeWidth={1.8} />
      </div>
      <h1 class="text-[28px] font-bold text-label tracking-tight mb-1.5">Code eingeben</h1>
      <p class="text-label-2 text-[15px] leading-relaxed">
        Wir haben einen 6-stelligen Code an<br />
        <strong class="text-label font-semibold">{email}</strong> gesendet.
      </p>
    </div>

    <div class="flex justify-between gap-2 mb-8">
      {#each Array(6) as _, i}
        <input
          bind:this={codeInputs[i]}
          type="text"
          inputmode="numeric"
          maxlength="1"
          aria-label={`Ziffer ${i + 1}`}
          class="w-12 h-14 text-center ios-card text-[22px] font-semibold text-label outline-none focus:ring-2"
          style="--tw-ring-color: var(--ios-tint);"
          oninput={(e) => handleCodeInput(i, e)}
          onkeydown={(e) => handleCodeKeydown(i, e)}
        />
      {/each}
    </div>

    <button
      onclick={() => { tapHaptic(); verifyCode(); }}
      disabled={auth.loading || code.length < 6}
      class="btn-filled w-full mb-3"
    >
      Bestätigen
    </button>
    <button
      onclick={() => { tapHaptic(); step = 'email'; code = ''; }}
      class="text-tint text-[15px] font-medium py-2.5 mx-auto"
    >
      Andere E-Mail verwenden
    </button>
  {/if}

  {#if auth.error}
    <div class="mt-5 rounded-[14px] p-4 text-[15px] text-red" style="background: var(--ios-red-soft);">
      {auth.error}
    </div>
  {/if}

  <p class="mt-auto pt-10 text-center text-[12px] text-label-3">
    © 2026 AUST Umzüge · Datenschutz · AGB
  </p>
</main>
