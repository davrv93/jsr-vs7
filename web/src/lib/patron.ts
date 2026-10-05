// Fondo del chat de prueba: garabatos de soporte técnico (correo, impresora, wifi, llave, laptop, teléfono, candado,
// llave inglesa, auriculares y escudo) en trazo fino, en una tesela de 288 × 288. Se usa como máscara sobre un color,
// así un solo dibujo sirve para claro y oscuro (referencias/baruka/DISENO_WHATSAPP.md §3).

const I = {
  correo: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 7-10 6L2 7"/>',
  impresora: '<polyline points="6 9 6 2 18 2 18 9"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><rect x="6" y="14" width="12" height="8"/>',
  wifi: '<path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M1.42 9a16 16 0 0 1 21.16 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/>',
  llave: '<path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>',
  laptop: '<rect x="3" y="4" width="18" height="12" rx="2"/><line x1="2" y1="20" x2="22" y2="20"/>',
  telefono: '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/>',
  candado: '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  llaveinglesa: '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>',
  auriculares: '<path d="M3 18v-6a9 9 0 0 1 18 0v6"/><path d="M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3zM3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z"/>',
  escudo: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
};

const COLOCACION: [keyof typeof I, number, number, number][] = [
  ["correo", 24, 20, -8],
  ["wifi", 120, 40, 6],
  ["llave", 214, 18, 12],
  ["laptop", 60, 110, 4],
  ["impresora", 168, 104, -10],
  ["candado", 244, 120, 8],
  ["telefono", 18, 200, -14],
  ["auriculares", 112, 188, 4],
  ["escudo", 196, 206, -6],
  ["llaveinglesa", 252, 252, 10],
  ["correo", 76, 258, 14],
];

const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" width="288" height="288" viewBox="0 0 288 288"><g fill="none" stroke="#000" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">` +
  COLOCACION.map(([n, x, y, r]) => `<g transform="translate(${x} ${y}) rotate(${r} 14 14) scale(1.15)">${I[n]}</g>`).join("") +
  `</g></svg>`;

export const PATRON_CSS = `url("data:image/svg+xml;utf8,${encodeURIComponent(svg)}")`;
