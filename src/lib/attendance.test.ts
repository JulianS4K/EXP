import { describe, expect, it } from 'vitest';
import { attendanceModeUrl, parseAttendanceFormat, schemaLocation } from '../../supabase/functions/_shared/attendance.ts';

describe('attendance (shared)', () => {
  const place = { '@type': 'Place', name: 'Brooklyn Steel' };
  it('maps the format to schema.org', () => {
    expect(attendanceModeUrl('in_person')).toMatch(/Offline/);
    expect(attendanceModeUrl('online')).toMatch(/Online/);
    expect(attendanceModeUrl('hybrid')).toMatch(/Mixed/);
    expect(parseAttendanceFormat('weird')).toBe('in_person');
  });
  it('builds the location from the public page, never a join link', () => {
    expect(schemaLocation('in_person', place, 'https://x/e/1')).toBe(place);
    expect(schemaLocation('online', place, 'https://x/e/1')).toEqual({ '@type': 'VirtualLocation', url: 'https://x/e/1' });
    expect(schemaLocation('hybrid', place, 'https://x/e/1')).toEqual([place, { '@type': 'VirtualLocation', url: 'https://x/e/1' }]);
    expect(schemaLocation('hybrid', null, 'https://x/e/1')).toEqual({ '@type': 'VirtualLocation', url: 'https://x/e/1' });
  });
});
