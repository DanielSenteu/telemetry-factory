// The provider registry. Adding a future integration is one entry here plus its
// adapter — the Sales gallery, mapping inbox, demand view and cron loop are all
// provider-blind and need no changes. This is where "configurable module" lives.

export type ProviderAuth = "oauth" | "apikey" | "native";

export type Provider = {
  key: string;
  label: string;
  blurb: string;
  auth: ProviderAuth;
  status: "live" | "coming_soon" | "talk_to_us";
  // OAuth providers: where "Connect" sends the browser (our own API route).
  connectPath?: string;
};

export const PROVIDERS: Provider[] = [
  {
    key: "zoho_books",
    label: "Zoho Books",
    blurb: "Mirror your sales invoices, read-only. We never write back.",
    auth: "oauth",
    status: "live",
    connectPath: "/api/zoho/connect",
  },
  {
    key: "our_pos",
    label: "Industrial-Sync POS",
    blurb: "Sell from a till linked straight to your stock — coming soon.",
    auth: "native",
    status: "coming_soon",
  },
  {
    key: "oracle",
    label: "Oracle / other systems",
    blurb: "On another system? Tell us — we add providers as factories need them.",
    auth: "apikey",
    status: "talk_to_us",
  },
];

export const getProvider = (key: string) => PROVIDERS.find((p) => p.key === key);
