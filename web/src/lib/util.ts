/** Espera `ms` milisegundos. */
export const pausa = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** `n` aleatorios en hexadecimal, para el id de la sesión del chat web (web-<16 hex>). */
export const hexAleatorio = (n: number): string => {
  const a = new Uint8Array(Math.ceil(n / 2));
  try {
    crypto.getRandomValues(a);
  } catch {
    for (let i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256);
  }
  return Array.from(a, (b) => b.toString(16).padStart(2, "0")).join("").slice(0, n);
};
