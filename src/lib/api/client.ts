const API_BASE = import.meta.env.VITE_API_BASE || 'http://localhost:8080';

class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function apiFetch<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    ...((options.headers as Record<string, string>) || {}),
  };

  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  // Don't set Content-Type for FormData (browser sets it with boundary)
  if (options.body && !(options.body instanceof FormData)) {
    headers['Content-Type'] = 'application/json';
  }

  const response = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers,
  });

  if (!response.ok) {
    const body = await response.json().catch(() => ({ message: response.statusText }));
    throw new ApiError(response.status, body.message || body.error || response.statusText);
  }

  // Handle 204 No Content
  if (response.status === 204) return undefined as T;

  return response.json();
}

function getToken(): string | null {
  // Check localStorage first (web), Capacitor Preferences would be used on device
  return localStorage.getItem('aust_customer_token');
}

export function setToken(token: string | null) {
  if (token) {
    localStorage.setItem('aust_customer_token', token);
  } else {
    localStorage.removeItem('aust_customer_token');
  }
}

export function apiGet<T>(path: string): Promise<T> {
  return apiFetch<T>(path);
}

export function apiPost<T>(path: string, body?: unknown): Promise<T> {
  return apiFetch<T>(path, {
    method: 'POST',
    body: body ? JSON.stringify(body) : undefined,
  });
}

export function apiPostForm<T>(path: string, formData: FormData): Promise<T> {
  return apiFetch<T>(path, {
    method: 'POST',
    body: formData,
  });
}

export { ApiError };
