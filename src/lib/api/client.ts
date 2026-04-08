const API_BASE = (import.meta.env.VITE_API_BASE || 'http://localhost:8080').replace(/\/$/, '');

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

  let response: Response;
  try {
    response = await fetch(`${API_BASE}${path}`, {
      ...options,
      headers,
    });
  } catch (networkErr: any) {
    // fetch() itself threw — network failure, CORS, DNS, server unreachable, etc.
    console.error('[API] Network error:', { url: `${API_BASE}${path}`, method: options.method || 'GET', error: networkErr });
    throw new ApiError(
      0,
      `Netzwerkfehler: Server nicht erreichbar (${API_BASE}). Bitte prüfen Sie Ihre Internetverbindung und versuchen Sie es erneut.`,
    );
  }

  if (!response.ok) {
    let serverMessage: string | undefined;
    let rawBody: string | undefined;
    try {
      rawBody = await response.text();
      try {
        const parsed = JSON.parse(rawBody);
        serverMessage = parsed.message || parsed.error || parsed.msg;
      } catch {
        // Body wasn't JSON — we already have rawBody as text
        serverMessage = rawBody.slice(0, 200) || undefined;
      }
    } catch {
      // Couldn't read body at all
    }
    const detail = serverMessage || response.statusText;
    console.error('[API] HTTP error:', {
      url: `${API_BASE}${path}`,
      status: response.status,
      statusText: response.statusText,
      body: rawBody?.slice(0, 500),
    });
    throw new ApiError(response.status, detail);
  }

  // Handle 204 No Content
  if (response.status === 204) return undefined as T;

  try {
    return await response.json();
  } catch (parseErr) {
    console.error('[API] JSON parse error:', { url: `${API_BASE}${path}`, status: response.status, error: parseErr });
    throw new ApiError(response.status, 'Serverantwort konnte nicht gelesen werden (kein gültiges JSON).');
  }
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

export async function apiGetBlob(path: string): Promise<Blob> {
  const token = getToken();
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  let response: Response;
  try {
    response = await fetch(`${API_BASE}${path}`, { headers });
  } catch (networkErr: any) {
    console.error('[API] Network error (blob):', { url: `${API_BASE}${path}`, error: networkErr });
    throw new ApiError(
      0,
      `Netzwerkfehler: Server nicht erreichbar (${API_BASE}). Bitte prüfen Sie Ihre Internetverbindung.`,
    );
  }
  if (!response.ok) {
    let rawBody: string | undefined;
    try {
      rawBody = await response.text();
    } catch { /* ignore */ }
    const detail = (() => {
      try { return rawBody ? JSON.parse(rawBody).message : undefined; } catch { return rawBody?.slice(0, 200); }
    })();
    console.error('[API] HTTP error (blob):', {
      url: `${API_BASE}${path}`,
      status: response.status,
      statusText: response.statusText,
      body: rawBody?.slice(0, 500),
    });
    throw new ApiError(response.status, detail || response.statusText);
  }
  return response.blob();
}

export { ApiError };
