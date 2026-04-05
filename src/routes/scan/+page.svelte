<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { DepthCapture } from '$lib/plugins/depth-capture';

  let completeHandle: any;
  let cancelHandle: any;
  let savedHandle: any;

  onMount(async () => {
    capture.clear();

    completeHandle = await DepthCapture.addListener('sessionComplete', async () => {
      const { items } = await DepthCapture.getAllItems();
      capture.clear();
      for (const item of items) capture.addItem(item);

      try {
        capture.intrinsics = await DepthCapture.getIntrinsics();
      } catch { /* non-LiDAR or intrinsics unavailable */ }

      await DepthCapture.stopSession();
      goto('/scan/form');
    });

    cancelHandle = await DepthCapture.addListener('sessionCancelled', async () => {
      await DepthCapture.stopSession();
      capture.clear();
      goto('/');
    });

    savedHandle = await DepthCapture.addListener('itemSaved', () => {
      // Native overlay handles all feedback; nothing to do in JS.
    });

    await DepthCapture.startSession();
  });

  onDestroy(() => {
    completeHandle?.remove();
    cancelHandle?.remove();
    savedHandle?.remove();
  });
</script>

<!-- Native UI covers the entire screen; WebView is hidden by the plugin. -->
