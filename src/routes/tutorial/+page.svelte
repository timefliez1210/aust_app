<script lang="ts">
  import { goto } from '$app/navigation';
  import { tapHaptic } from '$lib/haptics';
  import { House, Lightbulb, Camera, Sparkles } from 'lucide-svelte';

  let currentSlide = $state(0);

  const slides = [
    {
      icon: House,
      title: 'Jeden Raum zeigen',
      desc: 'Öffnen Sie Schränke und zeigen Sie alle Möbel, die umgezogen werden sollen.',
    },
    {
      icon: Lightbulb,
      title: 'Gute Beleuchtung',
      desc: 'Schalten Sie alle Lampen ein. Helle Räume liefern präzisere Messungen.',
    },
    {
      icon: Camera,
      title: 'Objekt für Objekt',
      desc: 'Tippen Sie ein erkanntes Möbelstück an und bewegen Sie die Kamera langsam darum herum.',
    },
    {
      icon: Sparkles,
      title: 'Angebot in Minuten',
      desc: 'Wir berechnen das Volumen und erstellen Ihr maßgeschneidertes Umzugsangebot.',
    },
  ];

  function next() {
    tapHaptic();
    if (currentSlide < slides.length - 1) currentSlide++;
    else finish();
  }

  function finish() {
    localStorage.setItem('tutorialSeen', 'true');
    goto('/scan');
  }

  const CurrentIcon = $derived(slides[currentSlide].icon);
</script>

<div class="min-h-screen bg-bg flex flex-col max-w-lg mx-auto"
  style="padding-top: env(safe-area-inset-top, 0px); padding-bottom: calc(env(safe-area-inset-bottom, 0px) + 1rem);">

  <!-- Header -->
  <div class="flex justify-between items-center px-6 pt-4">
    <span class="text-label font-bold text-[17px] tracking-tight">AUST Umzüge</span>
    <button onclick={() => { tapHaptic(); finish(); }} class="text-tint text-[15px] font-medium py-2">
      Überspringen
    </button>
  </div>

  <!-- Slide content -->
  <div class="flex-1 flex flex-col items-center justify-center px-10 text-center">
    {#key currentSlide}
      <div class="rise-in flex flex-col items-center">
        <div class="w-24 h-24 rounded-[28px] bg-tint flex items-center justify-center mb-8">
          <CurrentIcon size={44} color="#fff" strokeWidth={1.6} />
        </div>
        <h2 class="text-[24px] font-bold text-label tracking-tight mb-2.5">{slides[currentSlide].title}</h2>
        <p class="text-label-2 text-[16px] leading-relaxed max-w-xs">{slides[currentSlide].desc}</p>
      </div>
    {/key}
  </div>

  <!-- Progress + CTA -->
  <div class="px-8 pb-6 flex flex-col items-center gap-7">
    <div class="flex gap-2">
      {#each slides as _, i}
        <div class="h-2 rounded-full transition-all duration-300 {i === currentSlide ? 'w-6' : 'w-2'}"
          style="background: {i === currentSlide ? 'var(--ios-tint)' : 'var(--ios-fill-strong)'};"></div>
      {/each}
    </div>

    <button onclick={next} class="btn-filled w-full max-w-xs">
      {currentSlide < slides.length - 1 ? 'Weiter' : "Los geht's"}
    </button>
  </div>
</div>
