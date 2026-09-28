// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { useState } from 'react';
import Dialog from './Dialog';

afterEach(cleanup);

function Harness({ dismissible = true, onClose }: { dismissible?: boolean; onClose?: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button onClick={() => setOpen(true)}>Open</button>
      <Dialog
        open={open}
        onClose={() => { onClose?.(); setOpen(false); }}
        labelledBy="t"
        dismissible={dismissible}
      >
        <h2 id="t">Title</h2>
        <button>First</button>
        <button>Last</button>
      </Dialog>
    </>
  );
}

function openIt() {
  const opener = screen.getByRole('button', { name: 'Open' });
  opener.focus();
  fireEvent.click(opener);
  return opener;
}

describe('Dialog', () => {
  it('is a labelled modal dialog and moves focus inside', () => {
    render(<Harness />);
    openIt();
    const dialog = screen.getByRole('dialog', { name: 'Title' });
    expect(dialog.getAttribute('aria-modal')).toBe('true');
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'First' }));
  });

  it('closes on Escape and gives focus back to the opener', () => {
    const onClose = vi.fn();
    render(<Harness onClose={onClose} />);
    const opener = openIt();
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(document.activeElement).toBe(opener);
  });

  it('keeps Tab inside the dialog', () => {
    render(<Harness />);
    openIt();
    const first = screen.getByRole('button', { name: 'First' });
    const last = screen.getByRole('button', { name: 'Last' });
    last.focus();
    fireEvent.keyDown(document, { key: 'Tab' });
    expect(document.activeElement).toBe(first);
    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(last);
  });

  it('closes on a backdrop press but not a press inside the panel', () => {
    const onClose = vi.fn();
    render(<Harness onClose={onClose} />);
    openIt();
    fireEvent.mouseDown(screen.getByRole('button', { name: 'First' }));
    expect(onClose).not.toHaveBeenCalled();
    fireEvent.mouseDown(screen.getByRole('dialog').parentElement!);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('ignores Escape and the backdrop while not dismissible', () => {
    const onClose = vi.fn();
    render(<Harness dismissible={false} onClose={onClose} />);
    openIt();
    fireEvent.keyDown(document, { key: 'Escape' });
    fireEvent.mouseDown(screen.getByRole('dialog').parentElement!);
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog')).toBeTruthy();
  });
});
