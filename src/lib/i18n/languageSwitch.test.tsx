// @vitest-environment jsdom
// Switching to Spanish re-renders the buyer path and the door in Spanish and
// sets <html lang="es"> (screen readers pick the voice from it); the choice
// sticks for the next visit. Without a provider, components stay English.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';

// The switch also saves the choice on a signed-in account; nobody is signed in here.
vi.mock('../supabase', () => ({
  supabase: { auth: { getSession: async () => ({ data: { session: null } }), updateUser: vi.fn() } },
}));

import { LanguageProvider, useT } from '../../context/LanguageContext';
import LanguageSwitcher from '../../components/LanguageSwitcher';
import GuestCheckoutModal from '../../components/GuestCheckoutModal';
import { documentLang } from './dict';

function DoorLine() {
  const t = useT();
  return <p>{t('door.entryAllowed')} · {t('door.refuse.wrong-event')}</p>;
}

function App() {
  return (
    <LanguageProvider>
      <LanguageSwitcher />
      <DoorLine />
      <GuestCheckoutModal open onClose={() => {}} onContinue={() => {}} onSignIn={() => {}} />
    </LanguageProvider>
  );
}

beforeEach(() => {
  localStorage.clear();
  document.documentElement.lang = '';
});
afterEach(cleanup);

describe('language switch', () => {
  it('renders English, then Spanish after tapping ES', () => {
    Object.defineProperty(navigator, 'language', { value: 'en-US', configurable: true });
    render(<App />);
    expect(screen.getByText(/Entry Allowed/)).toBeTruthy();
    expect(screen.getByRole('dialog', { name: /where should we send your tickets/i })).toBeTruthy();
    expect(document.documentElement.lang).toBe('en');

    fireEvent.click(screen.getByRole('button', { name: 'es' }));
    expect(screen.getByText(/Puede pasar · Esta entrada es de otro evento\./)).toBeTruthy();
    expect(screen.getByRole('dialog', { name: /a dónde te enviamos tus entradas/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /continuar al pago/i })).toBeTruthy();
    expect(screen.getByLabelText('Correo')).toBeTruthy();
    expect(document.documentElement.lang).toBe('es');
    expect(documentLang()).toBe('es');
    expect(localStorage.getItem('exos.lang')).toBe('es');
  });

  it('follows a Spanish device on first load', () => {
    Object.defineProperty(navigator, 'language', { value: 'es-MX', configurable: true });
    render(<App />);
    expect(screen.getByText(/Puede pasar/)).toBeTruthy();
    expect(document.documentElement.lang).toBe('es');
    Object.defineProperty(navigator, 'language', { value: 'en-US', configurable: true });
  });

  it('stays English outside a provider', () => {
    render(<DoorLine />);
    expect(screen.getByText(/Entry Allowed/)).toBeTruthy();
  });
});
