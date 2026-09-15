import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import {
  brandingApi,
  DEFAULT_PANEL_BRANDING,
  type PanelBranding,
} from '@/lib/api';

interface BrandingContextValue {
  branding: PanelBranding;
  apply: (branding: PanelBranding) => void;
  refresh: () => Promise<void>;
}

export const BrandingContext = createContext<BrandingContextValue>({
  branding: DEFAULT_PANEL_BRANDING,
  apply: () => {},
  refresh: async () => {},
});

export function useBrandingProvider(): BrandingContextValue {
  const [branding, setBranding] = useState<PanelBranding>(DEFAULT_PANEL_BRANDING);

  const refresh = useCallback(async () => {
    try {
      setBranding(await brandingApi.get());
    } catch (error) {
      // The public endpoint may be unavailable during a rolling update. Keep
      // the built-in labels so a failed decoration never blocks login.
      console.warn('Failed to load panel branding:', error);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    document.title = branding.panel_name || DEFAULT_PANEL_BRANDING.panel_name;
  }, [branding.panel_name]);

  useEffect(() => {
    const existing = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    const icon = existing || document.createElement('link');
    const original = icon.getAttribute('href');
    const originalType = icon.getAttribute('type');
    if (branding.has_icon) {
      icon.rel = 'icon';
      icon.removeAttribute('type');
      icon.href = brandingApi.iconURL(branding.icon_revision);
      if (!existing) document.head.appendChild(icon);
    }
    return () => {
      if (!existing) icon.remove();
      else {
        if (original !== null) icon.setAttribute('href', original);
        else icon.removeAttribute('href');
        if (originalType !== null) icon.setAttribute('type', originalType);
      }
    };
  }, [branding.has_icon, branding.icon_revision]);

  return { branding, apply: setBranding, refresh };
}

export function useBranding() {
  return useContext(BrandingContext);
}
