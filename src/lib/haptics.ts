import { Haptics, ImpactStyle, NotificationType } from '@capacitor/haptics';

/** Light tap for button presses. Silently no-ops on web. */
export function tapHaptic() {
  Haptics.impact({ style: ImpactStyle.Light }).catch(() => {});
}

/** Success feedback (offer accepted, scan finished, …). */
export function successHaptic() {
  Haptics.notification({ type: NotificationType.Success }).catch(() => {});
}

/** Error feedback (failed request, invalid code, …). */
export function errorHaptic() {
  Haptics.notification({ type: NotificationType.Error }).catch(() => {});
}
