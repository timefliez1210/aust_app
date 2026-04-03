import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.aust.umzuege',
  appName: 'Aust Umzüge',
  webDir: 'build',
  server: {
    androidScheme: 'https'
  },
  ios: {
    infoPlist: {
      NSCameraUsageDescription: 'Diese App benötigt Zugriff auf die Kamera, um Fotos Ihrer Möbel für die Umzugsplanung aufzunehmen.',
      NSPhotoLibraryUsageDescription: 'Diese App benötigt Zugriff auf Ihre Fotos, um Bilder für die Umzugsplanung hochzuladen.',
      NSPhotoLibraryAddUsageDescription: 'Diese App speichert aufgenommene Fotos in Ihrer Fotobibliothek.',
      NSMicrophoneUsageDescription: 'Diese App benötigt Zugriff auf das Mikrofon für die Videoaufnahme.',
    }
  }
};

export default config;
