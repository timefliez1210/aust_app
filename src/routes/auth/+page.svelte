<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { auth } from '$lib/stores/auth.svelte';

  let email = $state('');
  let code = $state('');
  let step: 'email' | 'code' = $state('email');
  let codeInputs: HTMLInputElement[] = $state([]);

  const redirect = $derived($page.url.searchParams.get('redirect') || '/');

  async function requestCode(e: SubmitEvent) {
    e.preventDefault();
    await auth.requestOtp(email);
    step = 'code';
  }

  async function verifyCode() {
    await auth.verifyOtp(email, code);
    goto(redirect);
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

<div class="flex min-h-screen flex-col items-center justify-center px-6">
  <div class="w-full max-w-sm">
    <h1 class="mb-2 text-2xl font-bold text-primary">Anmelden</h1>

    {#if step === 'email'}
      <p class="mb-6 text-text-muted">Geben Sie Ihre E-Mail-Adresse ein, um einen Zugangscode zu erhalten.</p>
      <form onsubmit={requestCode}>
        <label class="mb-1 block text-sm font-medium text-text-muted" for="email">E-Mail</label>
        <input
          id="email"
          type="email"
          bind:value={email}
          required
          class="mb-4 w-full rounded-lg border border-border bg-surface px-4 py-3 text-text outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
          placeholder="ihre@email.de"
        />
        <button
          type="submit"
          disabled={auth.loading || !email}
          class="w-full rounded-xl bg-accent px-6 py-3 font-semibold text-white shadow-md transition hover:bg-accent-hover disabled:opacity-50"
        >
          {auth.loading ? 'Wird gesendet...' : 'Code anfordern'}
        </button>
      </form>

    {:else}
      <p class="mb-6 text-text-muted">Wir haben einen 6-stelligen Code an <strong>{email}</strong> gesendet.</p>
      <div class="mb-6 flex justify-center gap-2">
        {#each Array(6) as _, i}
          <input
            bind:this={codeInputs[i]}
            type="text"
            inputmode="numeric"
            maxlength="1"
            class="h-14 w-12 rounded-lg border border-border bg-surface text-center text-2xl font-bold text-text outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
            oninput={(e) => handleCodeInput(i, e)}
            onkeydown={(e) => handleCodeKeydown(i, e)}
          />
        {/each}
      </div>
      <button
        onclick={() => { step = 'email'; code = ''; }}
        class="text-sm text-accent hover:underline"
      >
        Andere E-Mail verwenden
      </button>
    {/if}

    {#if auth.error}
      <div class="mt-4 rounded-lg bg-red-50 p-3 text-sm text-error">{auth.error}</div>
    {/if}
  </div>
</div>
