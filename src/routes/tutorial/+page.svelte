<script lang="ts">
  import { goto } from '$app/navigation';

  let currentSlide = $state(0);

  const slides = [
    {
      icon: 'home',
      color: 'bg-primary',
      title: 'Jeden Raum zeigen',
      desc: 'Öffnen Sie Schränke und zeigen Sie alle Möbel, die umgezogen werden sollen.',
    },
    {
      icon: 'lightbulb',
      color: 'bg-secondary',
      title: 'Gute Beleuchtung',
      desc: 'Schalten Sie alle Lampen ein. Helle Räume liefern der KI präzisere Daten.',
    },
    {
      icon: 'photo_camera',
      color: 'bg-primary-container',
      title: 'Kamera ruhig halten',
      desc: 'Bewegen Sie die Kamera langsam und fotografieren Sie aus verschiedenen Winkeln.',
    },
    {
      icon: 'auto_awesome',
      color: 'bg-secondary-container',
      title: 'KI erstellt Ihr Angebot',
      desc: 'Unsere KI analysiert Ihre Fotos und erstellt ein maßgeschneidertes Umzugsangebot.',
    },
  ];

  function next() {
    if (currentSlide < slides.length - 1) currentSlide++;
    else finish();
  }

  function finish() {
    localStorage.setItem('tutorialSeen', 'true');
    goto('/scan');
  }
</script>

<div class="min-h-screen bg-surface flex flex-col">
  <!-- Header -->
  <div class="flex justify-between items-center px-6 pt-12 pb-4">
    <span class="text-primary font-black tracking-tighter text-lg uppercase">AUST Umzüge</span>
    <button onclick={finish} class="text-on-surface-variant text-xs font-bold uppercase tracking-widest hover:text-secondary transition-colors">
      Überspringen
    </button>
  </div>

  <!-- Slide content -->
  <div class="flex-1 flex flex-col items-center justify-center px-8 text-center">
    <div class="w-28 h-28 rounded-3xl {slides[currentSlide].color} flex items-center justify-center mb-8 bento-shadow transition-all duration-300">
      <span class="material-symbols-outlined text-white" style="font-size: 52px; font-variation-settings: 'FILL' 1;">{slides[currentSlide].icon}</span>
    </div>
    <h2 class="text-2xl font-extrabold text-on-surface tracking-tight mb-3">{slides[currentSlide].title}</h2>
    <p class="text-on-surface-variant leading-relaxed max-w-xs">{slides[currentSlide].desc}</p>
  </div>

  <!-- Progress + CTA -->
  <div class="px-8 pb-14 flex flex-col items-center gap-6">
    <!-- Dots -->
    <div class="flex gap-2">
      {#each slides as _, i}
        <div class="h-2 rounded-full transition-all duration-300 {i === currentSlide ? 'bg-primary w-6' : 'bg-outline-variant w-2'}"></div>
      {/each}
    </div>

    <button
      onclick={next}
      class="w-full max-w-xs h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all duration-200 flex items-center justify-center gap-2"
    >
      <span>{currentSlide < slides.length - 1 ? 'Weiter' : "Los geht's"}</span>
      <span class="material-symbols-outlined" style="font-size: 18px;">
        {currentSlide < slides.length - 1 ? 'arrow_forward' : 'videocam'}
      </span>
    </button>
  </div>
</div>
