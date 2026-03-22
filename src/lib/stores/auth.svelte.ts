import { apiPost, apiGet, setToken } from '$lib/api/client';

interface Customer {
  id: string;
  email: string;
  name: string | null;
  phone: string | null;
}

class AuthStore {
  token: string | null = $state(null);
  customer: Customer | null = $state(null);
  loading = $state(false);
  error: string | null = $state(null);

  get isAuthenticated() {
    return !!this.token;
  }

  constructor() {
    // Restore from localStorage
    if (typeof window !== 'undefined') {
      this.token = localStorage.getItem('aust_customer_token');
      const stored = localStorage.getItem('aust_customer');
      if (stored) {
        try { this.customer = JSON.parse(stored); } catch { /* ignore */ }
      }
    }
  }

  async requestOtp(email: string) {
    this.loading = true;
    this.error = null;
    try {
      await apiPost('/api/v1/customer/auth/request', { email });
    } catch (e: any) {
      this.error = e.message || 'Fehler beim Senden des Codes';
      throw e;
    } finally {
      this.loading = false;
    }
  }

  async verifyOtp(email: string, code: string) {
    this.loading = true;
    this.error = null;
    try {
      const result = await apiPost<{ token: string; customer: Customer }>(
        '/api/v1/customer/auth/verify',
        { email, code }
      );
      this.token = result.token;
      this.customer = result.customer;
      setToken(result.token);
      localStorage.setItem('aust_customer', JSON.stringify(result.customer));
    } catch (e: any) {
      this.error = e.message || 'Ungültiger Code';
      throw e;
    } finally {
      this.loading = false;
    }
  }

  async fetchProfile() {
    try {
      this.customer = await apiGet<Customer>('/api/v1/customer/me');
      localStorage.setItem('aust_customer', JSON.stringify(this.customer));
    } catch {
      // Token might be expired
      this.logout();
    }
  }

  logout() {
    this.token = null;
    this.customer = null;
    setToken(null);
    localStorage.removeItem('aust_customer');
  }
}

export const auth = new AuthStore();
