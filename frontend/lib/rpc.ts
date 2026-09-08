const RPC_STORAGE_KEY = "uzrRpcUrl";

/** Reads the user-configured RPC URL, if any. Returns undefined when unset,
 *  so callers fall back to viem/wagmi's built-in default for the chain. */
export function getStoredRpcUrl(): string | undefined {
  if (typeof window === "undefined") return undefined;
  return localStorage.getItem(RPC_STORAGE_KEY) || undefined;
}

export function setStoredRpcUrl(url: string) {
  if (url) {
    localStorage.setItem(RPC_STORAGE_KEY, url);
  } else {
    localStorage.removeItem(RPC_STORAGE_KEY);
  }
}

export { RPC_STORAGE_KEY };
