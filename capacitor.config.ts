import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.aust.umzuege',
  appName: 'Aust Umzüge',
  webDir: 'build',
  server: {
    androidScheme: 'https'
  }
};

export default config;
