import { createHash } from 'node:crypto';

export const BACKENDS = ['opencode', 'codex', 'claude'];
export const hash = value => createHash('sha256').update(String(value)).digest('hex');
export function clean(value, limit = 4000) {
  return String(value ?? '')
    .replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/g, '[redacted]')
    .replace(/\b(?:sk-[\w-]{12,}|gh[pousr]_[\w]{15,}|Bearer\s+[\w.\/-]{10,})/gi, '[redacted]')
    .replace(/((?:api[_-]?key|token|password|secret|cookie|authorization)\s*[=:]\s*)[^\s,;"']+/gi, '$1[redacted]')
    .slice(0, limit);
}
export function authorized(project, roots) {
  // Enabled backends now cover all locally available sessions, including ones
  // without a recorded project. An explicit legacy scope still remains exact.
  return roots === undefined || (typeof project === 'string' && roots.includes(project));
}
export function textOf(message) {
  if (!message) return '';
  if (typeof message === 'string') return message;
  if (Array.isArray(message)) return message.map(textOf).filter(Boolean).join('\n');
  if (message.type === 'reasoning' || message.type === 'thinking') return '';
  if (typeof message.text === 'string') return message.text;
  if (message.type === 'tool_use' || message.type === 'toolCall') return `[tool: ${message.name ?? 'activity'}]`;
  if (message.type === 'tool_result') return message.is_error ? '[tool failed]' : '[tool completed]';
  return textOf(message.content ?? message.message ?? message.parts ?? message.items ?? []);
}
export function validConfig(input = {}) {
  return {
    enabled: input.enabled === true, paused: input.paused === true,
    intervalMinutes: Math.max(0, Math.min(1440, Number(input.intervalMinutes) || 0)),
    cooldownSeconds: Math.max(0, Math.min(3600, Number(input.cooldownSeconds ?? 180))),
    hourlyRequests: Math.max(1, Math.min(120, Number(input.hourlyRequests) || 12)),
    model: typeof input.model === 'string' ? input.model.slice(0, 200) : '',
    sources: Object.fromEntries(BACKENDS.map(backend => [backend, {
      enabled: input.sources?.[backend]?.enabled === true,
    }])),
    characters: (input.characters ?? []).filter(c => /^[\da-f-]{36}$/i.test(c.id)).map(c => ({
      id: c.id, name: clean(c.name, 100), enabled: c.enabled === true, visible: c.visible === true,
      gaze: c.gaze !== false,
    })),
  };
}
export function parseUtterance(text) {
  const trimmed = text.trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
  if (/^(?:skip|\[skip\])\s*[.!。]?$/i.test(trimmed)) return { skip: true };
  try {
    const value = JSON.parse(trimmed);
    if (value.skip === true) return { skip: true };
    if (typeof value.text !== 'string') throw new Error('Missing text');
    return { text: clean(value.text, 300), emotion: ['neutral', 'happy', 'curious', 'concerned'].includes(value.emotion) ? value.emotion : 'neutral' };
  } catch {
    // Never turn arbitrary model JSON into commands or leak reasoning/tool dumps into bubbles.
    if (!trimmed || trimmed.startsWith('{') || trimmed.startsWith('[')) return { skip: true };
    return { text: clean(trimmed, 300), emotion: 'neutral' };
  }
}
